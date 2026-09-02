# SALVAGE — Smart Contract Architecture Specification

**Purpose of this document:** a build-ready specification of every contract, its storage, its functions, and how they call each other. Written so an engineer who has not read the whitepaper can still implement from this document alone.

**Solidity version target:** `^0.8.24` (matches current Uniswap v4 core).
**Dependencies:** `@uniswap/v4-core`, `@uniswap/v4-periphery`, Chainlink `AggregatorV3Interface`.

---

## 1. A design decision made explicit before anything else

Uniswap v4 allows **exactly one hook contract per pool**. Every callback (`beforeSwap`, `afterSwap`, `afterAddLiquidity`, etc.) is called on that single address. This has one important consequence for how we structure the system:

> **`Manifest` and `LossMeter` are internal libraries operating on storage owned by `SalvageHook` itself — not separate deployed contracts.**

Why: these two run on *every single swap*. If they were separate contracts, every swap would pay for two extra `CALL` opcodes plus cross-contract storage access, purely for accounting that only `SalvageHook` ever needs. Solidity's `library ... using X for Y` pattern lets us keep the logic in separate files (clean, auditable, testable in isolation) while the actual storage and execution stay inside the hook's own contract (cheap).

Everything else — `SalvageAuction`, `ConvoyBatch`, `GeneralAverageFund`, `LettersOfMarque`, `ConvoyPositionAuction` — **is** a separate deployed contract. These hold independent state (bonds, escrowed funds, bid history) that legitimately needs its own security boundary, and are called less frequently than every swap.

---

## 2. Contract map

```
                         ┌─────────────────────────┐
   Uniswap v4            │      SalvageHook.sol      │◄── the ONLY contract
   PoolManager  ────────►│  (owns Manifest + Loss   │    v4 ever calls directly
   calls beforeSwap/      │   Meter storage, via      │
   afterSwap/etc.         │   internal libraries)     │
                         └───────────┬──────────────┘
                                     │ external calls
                 ┌───────────────────┼───────────────────┬──────────────────┐
                 ▼                   ▼                   ▼                  ▼
        SalvageAuction.sol   ConvoyBatch.sol   GeneralAverageFund.sol  LettersOfMarque.sol
                 │                   │                   ▲                  │
                 └───────────────────┴───────────────────┘                  │
                          (both deposit into the fund)                       │
                                                                              │
        ConvoyPositionAuction.sol ──── reads payout order ──► GeneralAverageFund.sol
        FleetSettlement.sol (upcoming) ──── splits bids across multiple pools' funds
```

Two library files, imported and `using`-attached inside `SalvageHook`:

```
libraries/ManifestLib.sol     — LP exposure tracking (no external calls, pure storage ops)
libraries/LossMeterLib.sol    — LVR measurement + accumulator (one external call: the oracle)
```

---

## 3. `SalvageHook.sol` — the entry point

### Storage

```solidity
contract SalvageHook is BaseHook {
    using ManifestLib for ManifestLib.Storage;
    using LossMeterLib for LossMeterLib.Storage;

    ManifestLib.Storage internal manifest;
    LossMeterLib.Storage internal lossMeter;

    ISalvageAuction public immutable salvageAuction;
    IConvoyBatch public immutable convoyBatch;
    IGeneralAverageFund public immutable fund;
    IPriceOracle public immutable oracle;

    error NotThisBlocksWinner();
    error BidNotCollected();
    error UnauthorizedBatchCaller();
}
```

### Constructor

```solidity
constructor(
    IPoolManager _poolManager,
    ISalvageAuction _salvageAuction,
    IConvoyBatch _convoyBatch,
    IGeneralAverageFund _fund,
    IPriceOracle _oracle
) BaseHook(_poolManager) {
    salvageAuction = _salvageAuction;
    convoyBatch = _convoyBatch;
    fund = _fund;
    oracle = _oracle;
}
```

### Hook permissions

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: false,
        afterAddLiquidity: true,      // manifest must hear about new positions
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: true,   // manifest must hear about closed positions
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

### `_afterAddLiquidity` / `_afterRemoveLiquidity`

```solidity
function _afterAddLiquidity(
    address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
    BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata
) internal override returns (bytes4, BalanceDelta) {
    manifest.recordPosition(sender, params.tickLower, params.tickUpper, params.liquidityDelta);
    return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
}

function _afterRemoveLiquidity(
    address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
    BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata
) internal override returns (bytes4, BalanceDelta) {
    // force settlement of any pending claim BEFORE the position size changes,
    // or a later claim calculation could use a liquidity figure that no
    // longer matches what was actually exposed during the loss event
    fund.claim(sender);
    manifest.recordPosition(sender, params.tickLower, params.tickUpper, params.liquidityDelta);
    return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
}
```

### `_beforeSwap` — routes between the two lanes described earlier

```solidity
function _beforeSwap(
    address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData
) internal override returns (bytes4, BeforeSwapDelta, uint24) {

    if (sender == address(convoyBatch)) {
        // this call IS the solver's batch settlement — the ConvoyBatch
        // contract has already computed the uniform clearing price and
        // is now executing it; nothing further to gate here.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // otherwise: treat as a salvage-auction-lane trade. Only this
    // block's winning bidder is allowed through this path.
    (address winner, uint256 bidAmount) = salvageAuction.currentBid(key.toId());
    if (sender != winner) revert NotThisBlocksWinner();
    if (bidAmount == 0) revert BidNotCollected();

    // "no cure, no pay" lives in this call ordering: the bid is
    // collected NOW, before the swap runs. If the swap that follows
    // reverts for any reason, this entire beforeSwap call reverts
    // with it, and the collection above is undone — the bot pays
    // nothing for a rescue that didn't happen.
    salvageAuction.collectBid(key.toId(), winner);
    fund.depositAuctionProceeds(key.toId(), bidAmount);

    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```

### `_afterSwap` — measurement and settlement

```solidity
function _afterSwap(
    address sender, PoolKey calldata key, SwapParams calldata params,
    BalanceDelta delta, bytes calldata
) internal override returns (bytes4, int128) {

    (uint160 sqrtPriceBefore, uint160 sqrtPriceAfter) = lossMeter.getPriceSnapshot(key.toId());
    uint256 realizedLoss = lossMeter.measureLoss(sqrtPriceBefore, sqrtPriceAfter, oracle);

    if (realizedLoss > 0) {
        ManifestLib.Exposure[] memory hit = manifest.getExposedRanges(
            TickMath.getTickAtSqrtPrice(sqrtPriceBefore),
            TickMath.getTickAtSqrtPrice(sqrtPriceAfter)
        );
        lossMeter.accrue(hit, realizedLoss);
    }

    return (BaseHook.afterSwap.selector, 0);
}
```

---

## 4. `libraries/ManifestLib.sol` — internal library

### Storage struct

```solidity
library ManifestLib {
    struct Position {
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Storage {
        mapping(bytes32 => Position) positions;       // key: keccak(lp, tickLower, tickUpper)
        mapping(int24 => uint128) activeLiquidityAtTick;
    }

    struct Exposure {
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }
}
```

### Functions

```solidity
function recordPosition(
    Storage storage self, address lp, int24 tickLower, int24 tickUpper, int256 liquidityDelta
) internal {
    bytes32 key = keccak256(abi.encode(lp, tickLower, tickUpper));
    Position storage p = self.positions[key];
    p.lp = lp;
    p.tickLower = tickLower;
    p.tickUpper = tickUpper;
    // apply signed delta to stored liquidity (mint = positive, burn = negative)
    p.liquidity = liquidityDelta >= 0
        ? p.liquidity + uint128(uint256(liquidityDelta))
        : p.liquidity - uint128(uint256(-liquidityDelta));
}

function getExposedRanges(
    Storage storage self, int24 tickBefore, int24 tickAfter
) internal view returns (Exposure[] memory) {
    // walks tickBefore -> tickAfter using the same next-initialized-tick
    // pattern v4's own swap logic uses (see TickBitmap.sol), collecting
    // every position whose [tickLower, tickUpper] overlaps any part of
    // the crossed range. Returned array feeds directly into LossMeterLib.accrue().
}
```

**Implementation note for the engineer building this:** `getExposedRanges` is the function worth the most test-writing time in the entire manifest — it is the direct implementation of the "who was on this stretch of the price move" logic from the earlier overlapping-ranges example (LP1/LP2/LP3). Write the three-overlapping-range scenario as a named test fixture and keep it as a permanent regression test.

---

## 5. `libraries/LossMeterLib.sol` — internal library

### Storage struct

```solidity
library LossMeterLib {
    struct Storage {
        uint256 lossGrowthGlobalX128;
        mapping(int24 => uint256) lossGrowthOutsideX128;   // per-tick snapshot, mirrors feeGrowthOutside
        mapping(address => uint256) lossGrowthInsideLastX128;  // per-LP checkpoint
    }
}
```

### Functions

```solidity
function measureLoss(
    Storage storage self, uint160 sqrtPriceBefore, uint160 sqrtPriceAfter, IPriceOracle oracle
) internal returns (uint256 realizedLoss) {
    (, int256 truePrice, , uint256 updatedAt, ) = oracle.latestRoundData();
    // stale-price guard — reject measurement (treat loss as 0 for this
    // swap, do NOT revert the trade) if the oracle hasn't updated recently
    require(block.timestamp - updatedAt < MAX_ORACLE_STALENESS, "stale oracle");

    // integrate the gap between the pool's execution path
    // (sqrtPriceBefore -> sqrtPriceAfter) and truePrice, tick by tick,
    // using TickMath conversions. This is the shaded-triangle
    // calculation from the worked example, done on-chain.
}

function accrue(
    Storage storage self, ManifestLib.Exposure[] memory hit, uint256 totalLoss
) internal {
    uint256 totalLiquidity;
    for (uint i = 0; i < hit.length; i++) totalLiquidity += hit[i].liquidity;
    require(totalLiquidity > 0, "no exposed liquidity");

    // global accumulator, mirroring feeGrowthGlobal's update pattern
    self.lossGrowthGlobalX128 += FullMath.mulDiv(totalLoss, FixedPoint128.Q128, totalLiquidity);

    // NOTE: a single flat lossGrowthGlobal bump is only correct when
    // every exposed LP covers the SAME sub-range. For genuinely
    // partial overlaps (LP1/LP2/LP3 example), this function must
    // instead loop the sub-intervals ManifestLib identifies and bump
    // per-tick lossGrowthOutside snapshots individually — this is the
    // hardest correctness requirement in the whole protocol; do not
    // ship the flat version believing it handles partial overlaps.
}

function getClaimable(
    Storage storage self, address lp, uint128 liquidity, uint256 lossGrowthInsideCurrent
) internal view returns (uint256) {
    uint256 last = self.lossGrowthInsideLastX128[lp];
    return FullMath.mulDiv(liquidity, lossGrowthInsideCurrent - last, FixedPoint128.Q128);
}

function checkpoint(Storage storage self, address lp, uint256 lossGrowthInsideCurrent) internal {
    self.lossGrowthInsideLastX128[lp] = lossGrowthInsideCurrent;
}
```

---

## 6. `SalvageAuction.sol`

### Storage

```solidity
contract SalvageAuction is ISalvageAuction {
    struct Bid { address bidder; uint256 amount; bool collected; }
    mapping(PoolId => Bid) public winningBid;
    mapping(PoolId => uint256) public windowStart;

    IVolatilityFeed public immutable volatilityFeed;
    address public immutable hook;   // only SalvageHook may call collectBid

    error NotHook();
    error AuctionStillOpen();
    error AlreadyCollected();
}
```

### Functions

```solidity
function submitBid(PoolId poolId, uint256 amount) external {
    require(block.number < windowStart[poolId] + windowLength(poolId), "window closed");
    if (amount > winningBid[poolId].amount) {
        winningBid[poolId] = Bid(msg.sender, amount, false);
    }
}

function windowLength(PoolId poolId) public view returns (uint256 blocks) {
    uint256 vol = volatilityFeed.recentVolatility(poolId);
    // storm-scaled sizing — e.g. piecewise: 1 block below a low-vol
    // threshold, scaling up to a governance-capped maximum (e.g. 6
    // blocks) above a high-vol threshold. Keep this a pure function
    // for easy testing and governance review.
}

function currentBid(PoolId poolId) external view returns (address winner, uint256 amount) {
    Bid memory b = winningBid[poolId];
    return (b.bidder, b.collected ? 0 : b.amount);
}

function collectBid(PoolId poolId, address winner) external {
    if (msg.sender != hook) revert NotHook();
    Bid storage b = winningBid[poolId];
    if (b.collected) revert AlreadyCollected();
    b.collected = true;
    IERC20(quoteToken).transferFrom(winner, address(this), b.amount);
    IERC20(quoteToken).approve(address(fund), b.amount);
}
```

---

## 7. `ConvoyBatch.sol`

```solidity
contract ConvoyBatch is IConvoyBatch {
    struct Order { address trader; bool zeroForOne; uint256 amountIn; uint256 minOut; }

    mapping(bytes32 => Order[]) public pendingBatch;   // key: poolId + epoch
    address public immutable authorizedSolver;
    uint256 public constant PRICE_IMPACT_THRESHOLD_BPS = 100; // 1%, see classifyBySize

    error UnauthorizedSolver();
    error NotRetailSized();
}
```

```solidity
function submitToBatch(PoolId poolId, Order calldata order) external {
    // called by the protected RPC relay on the user's behalf, or
    // directly by a user willing to accept batch-window latency
    require(classifyBySize(poolId, order), NotRetailSized());
    pendingBatch[_batchKey(poolId)].push(order);
}

function classifyBySize(PoolId poolId, Order calldata order) public view returns (bool) {
    uint256 impactBps = _estimatePriceImpactBps(poolId, order.amountIn);
    return impactBps <= PRICE_IMPACT_THRESHOLD_BPS;
}

function settleBatch(PoolId poolId, uint256 clearingPriceX96, bytes calldata solverProof) external {
    if (msg.sender != authorizedSolver) revert UnauthorizedSolver();
    // verify solverProof against the pending batch (e.g. a Merkle
    // commitment the solver published earlier, or a direct on-chain
    // recompute if gas allows), then call PoolManager.swap() once per
    // order in the batch at the single clearingPriceX96, through
    // SalvageHook (sender == address(this), see _beforeSwap above).
}
```

---

## 8. `GeneralAverageFund.sol`

```solidity
contract GeneralAverageFund is IGeneralAverageFund {
    mapping(PoolId => uint256) public auctionStreamBalance;
    mapping(PoolId => uint256) public feeStreamBalance;
    address public immutable hook;
    address public immutable salvageAuction;

    error Unauthorized();
}
```

```solidity
function depositAuctionProceeds(PoolId poolId, uint256 amount) external {
    require(msg.sender == hook || msg.sender == salvageAuction, Unauthorized());
    auctionStreamBalance[poolId] += amount;
}

function depositFeeSlice(PoolId poolId, uint256 amount) external {
    feeStreamBalance[poolId] += amount;   // called from the pool's swap-fee routing
}

function claim(address lp) external returns (uint256 paid) {
    uint128 liquidity = /* read LP's current liquidity from ManifestLib via hook */;
    uint256 owed = /* SalvageHook.lossMeter.getClaimable(lp, liquidity, ...) */;

    uint256 available = auctionStreamBalance[poolId] + feeStreamBalance[poolId];
    paid = owed > available ? available : owed;   // honest partial settlement on shortfall

    // drain auction stream first, then fee stream
    // ... transfer paid to lp ...
    // checkpoint the LP in LossMeterLib so they can't re-claim the same amount
}
```

---

## 9. `LettersOfMarque.sol`

```solidity
contract LettersOfMarque is ILettersOfMarque {
    mapping(address => uint256) public bondedAmount;
    uint256 public constant MIN_BOND = 10_000e18;   // governance-set

    function postBond(uint256 amount) external { ... }
    function isLicensed(address lp) external view returns (bool) {
        return bondedAmount[lp] >= MIN_BOND;
    }
    function penalizeUnbondedJIT(address lp, uint256 taxAmount) external onlyHook { ... }
    function slash(address lp, uint256 amount) external onlyHook { ... }
}
```

`SalvageHook._afterAddLiquidity` should check `lettersOfMarque.isLicensed(sender)` when the deposit lands inside the "final approach" window (last *k* blocks before a detected large trade) and route through `penalizeUnbondedJIT` if not licensed — wire this in once the core path is tested.

---

## 10. `ConvoyPositionAuction.sol`

```solidity
contract ConvoyPositionAuction is IConvoyPositionAuction {
    struct Bid { address lp; uint256 feeShareSacrificed; }
    Bid[] public epochBids;
    mapping(address => uint8) public payoutRank;   // 0 = paid first
    uint8 public constant PROTECTED_SLOTS = 2;

    function bidForProtection(uint256 feeShareSacrificed) external { ... }
    function resolveEpoch() external {
        // sort epochBids descending by feeShareSacrificed,
        // assign payoutRank 0..PROTECTED_SLOTS-1 to the top bidders
    }
}
```

`GeneralAverageFund.claim` should consult `payoutRank` when `available < owed` across multiple claimants in the same block, paying lower ranks first.

---

## 11. `FleetSettlement.sol` (upcoming — build last)

```solidity
contract FleetSettlement is IFleetSettlement {
    function submitBundledBid(PoolId[] calldata pools, uint256 totalBid) external {
        uint256[] memory gaps = new uint256[](pools.length);
        uint256 sumGaps;
        for (uint i = 0; i < pools.length; i++) {
            gaps[i] = ISalvageHook(hookFor[pools[i]]).lastMeasuredGap();  // read-only view
            sumGaps += gaps[i];
        }
        for (uint i = 0; i < pools.length; i++) {
            uint256 share = FullMath.mulDiv(totalBid, gaps[i], sumGaps);
            IGeneralAverageFund(fundFor[pools[i]]).depositAuctionProceeds(pools[i], share);
        }
        // all deposits above must succeed atomically — if any pool's
        // fund call reverts, the whole bundled settlement reverts,
        // per the same atomicity principle used everywhere else
    }
}
```

---

## 12. Interfaces reference

| File | Key methods |
|---|---|
| `IPriceOracle.sol` | `latestRoundData() returns (uint80, int256, uint256, uint256, uint80)` — mirrors Chainlink's `AggregatorV3Interface` exactly, use it directly rather than reinventing |
| `ISalvageAuction.sol` | `submitBid`, `currentBid`, `collectBid`, `windowLength` |
| `IConvoyBatch.sol` | `submitToBatch`, `classifyBySize`, `settleBatch` |
| `IGeneralAverageFund.sol` | `depositAuctionProceeds`, `depositFeeSlice`, `claim`, `balance` |
| `ILettersOfMarque.sol` | `postBond`, `isLicensed`, `penalizeUnbondedJIT`, `slash` |
| `IConvoyPositionAuction.sol` | `bidForProtection`, `resolveEpoch`, `payoutRank` |
| `IFleetSettlement.sol` | `submitBundledBid` |

---

## 13. Full call-flow walkthroughs

**Whale trade (salvage auction lane):**
`SalvageAuction.submitBid()` (off-chain competition, multiple calls) → winning bot calls `PoolManager.swap()` → v4 calls `SalvageHook._beforeSwap()` → checks `sender == winner` → `salvageAuction.collectBid()` → `fund.depositAuctionProceeds()` → v4 executes the actual swap → v4 calls `SalvageHook._afterSwap()` → `lossMeter.measureLoss()` → `manifest.getExposedRanges()` → `lossMeter.accrue()`.

**Retail trade (convoy lane):**
User signs intent off-chain → protected RPC relay → solver batches many intents → solver calls `ConvoyBatch.settleBatch()` → for each order, `ConvoyBatch` calls `PoolManager.swap()` with `sender == address(convoyBatch)` → `SalvageHook._beforeSwap()` recognizes this and skips the auction-winner check entirely.

**LP deposit:**
LP calls v4 `PositionManager.modifyLiquidity()` directly (stock v4, no custom code) → v4 calls `SalvageHook._afterAddLiquidity()` → `manifest.recordPosition()`.

**LP claim:**
LP calls `GeneralAverageFund.claim()` → fund reads the LP's current liquidity and `lossGrowthInside` from the hook → computes owed amount → pays from whichever stream(s) have balance → checkpoints the LP.

---

## 14. Build and test order

1. `ManifestLib` + `LossMeterLib` in isolation, with the three-overlapping-LP-range fixture as the core regression test.
2. `SalvageHook` wired to both libraries, tested against a local v4 pool fork with a mock oracle.
3. `GeneralAverageFund`, fee-stream only — prove `claim()` math against the seven-block worked timeline before adding the auction stream.
4. `SalvageAuction`, fixed-window — add "no cure, no pay" as a revert-path test (force a swap failure after bid collection, assert the whole transaction reverts including the bid charge).
5. Storm-scaled `windowLength()` — property-test against synthetic volatility inputs.
6. `ConvoyBatch` — start with a trusted single-solver model before considering solver decentralization.
7. `LettersOfMarque`, `ConvoyPositionAuction` — once the core is stable.
8. `FleetSettlement` — last, and budget the most audit time here; it's the highest-risk new surface.

---

## 15. Known open items — do not treat as solved

- `LossMeterLib.accrue`'s flat-accumulator version only handles fully-overlapping exposure; the partial-overlap (LP1/LP2/LP3) case needs the full per-tick `lossGrowthOutside` walk before this is correct for real concentrated-liquidity pools.
- `_estimatePriceImpactBps` in `ConvoyBatch` needs a concrete implementation — likely reusing v4's own swap-simulation math rather than a separate estimate, to avoid the two disagreeing.
- Oracle staleness handling (`measureLoss`) currently just zeroes out measurement on stale data — decide whether a stale oracle should instead pause the salvage-auction lane entirely, which is safer but more disruptive.
- Every contract above omits access-control detail (`Ownable`, timelocks, upgrade paths) — deliberately, since that's a governance design decision independent of this architecture, not a gap in it.
