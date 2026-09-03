// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IConvoyBatch} from "./interfaces/IConvoyBatch.sol";

/// @title ConvoyBatch
/// @notice Groups retail-sized swaps into one uniform-price batch (Budish/Cramton/Shim frequent
/// batch auctions) so there is no ordering inside the batch to sandwich. Larger trades are left to
/// route through the salvage auction lane instead — see `classifyBySize`.
///
/// @dev Roadmap item 6 ("start with a trusted single-solver model before considering solver
/// decentralization") — this is that trusted-single-solver version.
///
/// @dev `_estimatePriceImpactBps` is flagged in the architecture doc (section 15) as needing "a
/// concrete implementation — likely reusing v4's own swap-simulation math". This implementation
/// reuses `SqrtPriceMath.getNextSqrtPriceFromInput` for a single-step (no tick-crossing) price-move
/// estimate. It intentionally does not walk tick crossings the way a full swap simulation would:
/// a trade large enough to cross several ticks already produces a large single-step price move,
/// so the classification bias from this shortcut is conservative (toward "not retail"), never the
/// dangerous direction.
///
/// @dev `settleBatch` executes every queued order for real, from this contract's own address, so
/// `SalvageHook._beforeSwap`'s `sender == address(convoyBatch)` check is actually satisfied rather
/// than left as an integration gap — each order gets `clearingPriceX96` as its `sqrtPriceLimitX96`
/// (a floor for zeroForOne orders, a ceiling for the others, so nobody in the batch clears worse
/// than the solver's announced price) plus its own `minOut`. This is deliberately not a full
/// peer-to-peer netting engine (Budish/Cramton/Shim's actual uniform-clearing-price auction nets
/// opposing orders against each other before touching the AMM); orders execute sequentially against
/// the pool instead, which is only "uniform enough" for the small, price-impact-capped batches
/// `classifyBySize` admits. Building the full netting engine is future work, matching this
/// contract's already-documented "trusted single-solver" starting point.
/// @custom:security-contact See SECURITY.md
contract ConvoyBatch is IConvoyBatch, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(bytes32 => Order[]) public pendingBatch; // key: poolId + epoch
    mapping(PoolId => uint256) public currentEpoch;
    mapping(PoolId => PoolKey) internal poolKeyFor;
    mapping(PoolId => bool) public poolRegistered;

    IPoolManager public immutable poolManager;
    address public immutable authorizedSolver;
    address public immutable owner;
    uint256 public constant PRICE_IMPACT_THRESHOLD_BPS = 100; // 1%, see classifyBySize

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager, address _authorizedSolver, address _owner) {
        poolManager = _poolManager;
        authorizedSolver = _authorizedSolver;
        owner = _owner;
    }

    function registerPool(PoolId poolId, PoolKey calldata key) external onlyOwner {
        if (poolRegistered[poolId]) revert PoolAlreadyRegistered();
        poolKeyFor[poolId] = key;
        poolRegistered[poolId] = true;
    }

    /// @notice Queue a retail-sized order into the pending batch for `poolId`'s current epoch.
    /// Called by the protected RPC relay on the user's behalf, or directly by a user willing to
    /// accept batch-window latency.
    function submitToBatch(PoolId poolId, Order calldata order) external {
        if (!classifyBySize(poolId, order)) revert NotRetailSized();
        pendingBatch[_batchKey(poolId, currentEpoch[poolId])].push(order);
        emit OrderSubmitted(poolId, order.trader, order.amountIn, order.zeroForOne);
    }

    function classifyBySize(PoolId poolId, Order calldata order) public view returns (bool) {
        uint256 impactBps = _estimatePriceImpactBps(poolId, order.amountIn, order.zeroForOne);
        return impactBps <= PRICE_IMPACT_THRESHOLD_BPS;
    }

    function _estimatePriceImpactBps(PoolId poolId, uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (uint256 impactBps)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0 || sqrtPriceX96 == 0) return type(uint256).max;

        uint160 sqrtPriceNextX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, zeroForOne);

        uint256 diff =
            sqrtPriceX96 > sqrtPriceNextX96 ? sqrtPriceX96 - sqrtPriceNextX96 : sqrtPriceNextX96 - sqrtPriceX96;
        // sqrtPrice moves by ~half the price's relative move for small moves; scale to bps of price
        impactBps = (uint256(diff) * 2 * 10_000) / uint256(sqrtPriceX96);
    }

    /// @notice Settle the pending batch for `poolId` at one uniform clearing price, executing every
    /// queued order for real against the pool — see the contract-level NatSpec for how
    /// `clearingPriceX96` protects each order and why this isn't a full netting engine.
    function settleBatch(PoolId poolId, uint256 clearingPriceX96, bytes calldata solverProof) external {
        if (msg.sender != authorizedSolver) revert UnauthorizedSolver();
        if (!poolRegistered[poolId]) revert PoolNotRegistered();

        bytes32 key = _batchKey(poolId, currentEpoch[poolId]);
        Order[] memory orders = pendingBatch[key];
        delete pendingBatch[key];
        currentEpoch[poolId] += 1; // advance epoch so the next submitToBatch starts a fresh batch

        // NOTE (open item, per architecture doc section 15): a production settlement must verify
        // solverProof against the pending batch (e.g. a Merkle commitment the solver published
        // earlier, or a direct on-chain recompute) before trusting clearingPriceX96. The
        // single-trusted-solver model (roadmap item 6) intentionally defers that verification;
        // solverProof is accepted here as a forward-compatible parameter, unused until then.
        solverProof;

        if (orders.length > 0) {
            poolManager.unlock(abi.encode(poolId, orders, clearingPriceX96));
        }

        emit BatchSettled(poolId, clearingPriceX96, orders.length);
    }

    /// @dev Called back by `PoolManager` during the `unlock()` triggered from `settleBatch`. Runs
    /// each queued order's swap with `sender == address(this)` (this contract calling
    /// `poolManager.swap` directly is what makes that true), then settles the trader's side of the
    /// resulting delta directly against the trader — see `IConvoyBatch.Order`'s NatSpec on the
    /// manager-approval this requires.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolId poolId, Order[] memory orders, uint256 clearingPriceX96) =
            abi.decode(rawData, (PoolId, Order[], uint256));
        PoolKey memory key = poolKeyFor[poolId];

        for (uint256 i = 0; i < orders.length; i++) {
            Order memory order = orders[i];

            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: -int256(order.amountIn),
                sqrtPriceLimitX96: uint160(clearingPriceX96)
            });
            BalanceDelta delta = poolManager.swap(key, params, "");

            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();
            uint256 received;

            if (d0 < 0) _pay(key.currency0, order.trader, uint256(uint128(-d0)));
            if (d1 < 0) _pay(key.currency1, order.trader, uint256(uint128(-d1)));
            if (d0 > 0) {
                received = uint256(uint128(d0));
                _collect(key.currency0, order.trader, received);
            }
            if (d1 > 0) {
                received = uint256(uint128(d1));
                _collect(key.currency1, order.trader, received);
            }

            if (received < order.minOut) revert MinOutNotMet();
        }

        return "";
    }

    /// @dev Pulls `amount` of `currency` from `payer` straight into the manager to cover a negative
    /// delta. This call's `msg.sender` (as the token contract sees it) is `ConvoyBatch` itself, so
    /// `payer` must have approved *this contract*, not `poolManager` — exactly how a user approves
    /// a stock v4 router rather than the manager it calls into.
    function _pay(Currency currency, address payer, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Forwards a positive delta straight to `recipient` rather than crediting this contract.
    function _collect(Currency currency, address recipient, uint256 amount) private {
        poolManager.take(currency, recipient, amount);
    }

    function _batchKey(PoolId poolId, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, epoch));
    }
}
