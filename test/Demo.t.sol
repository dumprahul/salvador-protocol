// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {SalvageHook} from "../src/SalvageHook.sol";
import {SalvageAuction} from "../src/SalvageAuction.sol";
import {ConvoyBatch} from "../src/ConvoyBatch.sol";
import {IConvoyBatch} from "../src/interfaces/IConvoyBatch.sol";
import {GeneralAverageFund} from "../src/GeneralAverageFund.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IVolatilityFeed} from "../src/interfaces/IVolatilityFeed.sol";

import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockVolatilityFeed} from "./mocks/MockVolatilityFeed.sol";
import {Bidder} from "./helpers/Bidder.sol";

/// @notice Narrated, submission-ready walkthrough of SALVAGE's two trading lanes against one real,
/// freshly deployed `PoolManager` — a retail order clearing through `ConvoyBatch` with no gating
/// and no LP loss, and a whale/corrective trade that wins the salvage auction, moves the pool price,
/// and pays the exposed LP for exactly the loss it caused. Run with:
///
///   forge test --match-contract DemoTest -vvv
///
/// `-vvv` prints both the `console2.log` narration below and the full call trace, so every step —
/// bid collection, the swap itself, loss accrual, the LP's claim — is visible as a real state
/// transition, not just an assertion.
contract DemoTest is Deployers {
    SalvageHook internal hook;
    SalvageAuction internal auction;
    ConvoyBatch internal convoyBatch;
    GeneralAverageFund internal fund;
    MockPriceOracle internal oracle;
    MockVolatilityFeed internal volFeed;

    PoolId internal poolId;
    address internal lp; // v4 attributes the LP position to whichever address called modifyLiquidity

    address internal constant SOLVER = address(0x501702);
    address internal constant RETAIL_TRADER = address(0xA11CE);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        oracle = new MockPriceOracle(18, 1e18);
        volFeed = new MockVolatilityFeed();

        fund = new GeneralAverageFund(address(this));
        auction = new SalvageAuction(IVolatilityFeed(address(volFeed)), fund, address(this));
        convoyBatch = new ConvoyBatch(manager, SOLVER, address(this));

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        PoolKey memory pendingKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        bytes memory constructorArgs =
            abi.encode(manager, pendingKey, address(auction), address(convoyBatch), address(fund), address(oracle));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SalvageHook).creationCode, constructorArgs);

        hook =
            new SalvageHook{salt: salt}(manager, pendingKey, auction, convoyBatch, fund, IPriceOracle(address(oracle)));
        require(address(hook) == hookAddress, "hook address mismatch");

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hookAddress)
        });
        poolId = key.toId();

        fund.registerPool(poolId, address(hook), currency1AsIERC20());
        fund.setAuthorizedDepositor(poolId, address(auction), true);
        auction.registerPool(poolId, address(hook), currency1AsIERC20());
        convoyBatch.registerPool(poolId, key);

        manager.initialize(key, SQRT_PRICE_1_1);

        lp = address(modifyLiquidityRouter);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function currency1AsIERC20() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency1));
    }

    function currency0AsIERC20() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency0));
    }

    /// @notice Part 1: a retail-sized order clears through the convoy lane with zero gating and
    /// zero loss charged to the LP, while a whale-sized order on the exact same entrypoint is
    /// rejected outright.
    function test_demo_retailTrade() public {
        console2.log("===== RETAIL LANE: small trader through ConvoyBatch =====");

        uint256 amountIn = 1e15;
        MockERC20(Currency.unwrap(currency1)).mint(RETAIL_TRADER, 1 ether);
        vm.prank(RETAIL_TRADER);
        MockERC20(Currency.unwrap(currency1)).approve(address(convoyBatch), type(uint256).max);
        console2.log("Alice (retail) funded with 1 quote token, approves ConvoyBatch");

        IConvoyBatch.Order memory retailOrder =
            IConvoyBatch.Order({trader: RETAIL_TRADER, zeroForOne: false, amountIn: amountIn, minOut: 1});
        bool retailOk = convoyBatch.classifyBySize(poolId, retailOrder);
        console2.log("Alice's order classifyBySize (retail-sized?)", retailOk);
        assertTrue(retailOk, "small order must classify as retail");

        IConvoyBatch.Order memory whaleShapedOrder =
            IConvoyBatch.Order({trader: RETAIL_TRADER, zeroForOne: false, amountIn: 500 ether, minOut: 0});
        bool whaleOk = convoyBatch.classifyBySize(poolId, whaleShapedOrder);
        console2.log("A 500-token order through the SAME entrypoint classifyBySize (retail-sized?)", whaleOk);
        assertFalse(whaleOk, "oversized order must not classify as retail");

        vm.prank(RETAIL_TRADER);
        convoyBatch.submitToBatch(poolId, retailOrder);
        console2.log("Order queued into ConvoyBatch's pending batch for this epoch");

        uint256 quoteBefore = currency1AsIERC20().balanceOf(RETAIL_TRADER);
        uint256 baseBefore = currency0AsIERC20().balanceOf(RETAIL_TRADER);

        vm.prank(SOLVER);
        convoyBatch.settleBatch(poolId, MAX_PRICE_LIMIT, "");
        console2.log("Solver called settleBatch -> ConvoyBatch itself called PoolManager.swap()");

        uint256 quoteAfter = currency1AsIERC20().balanceOf(RETAIL_TRADER);
        uint256 baseAfter = currency0AsIERC20().balanceOf(RETAIL_TRADER);
        console2.log("Alice paid (quote token wei)", quoteBefore - quoteAfter);
        console2.log("Alice received (base token wei)", baseAfter - baseBefore);

        assertEq(quoteAfter, quoteBefore - amountIn, "exact-input amount must be pulled");
        assertGt(baseAfter, baseBefore, "trader must receive base token");

        uint256 lpClaimable = hook.claimableFor(lp);
        console2.log("LP's claimable loss after the retail trade (must be zero)", lpClaimable);
        assertEq(lpClaimable, 0, "convoy-lane trade must not accrue any loss to the LP");

        console2.log("No bid, no auction-winner check, no LP loss: retail flows through untaxed.");
    }

    /// @notice Part 2: a whale/corrective trade — a bot wins the salvage auction (beating a rival
    /// bidder first), executes the correcting swap itself in one atomic transaction, and the
    /// resulting loss is measured and paid to the exposed LP out of the very bid that was just
    /// collected.
    function test_demo_whaleTrade() public {
        console2.log("===== AUCTION LANE: whale/corrective bot wins, swaps, LP gets paid =====");

        Bidder rival = new Bidder(manager);
        Bidder winner = new Bidder(manager);

        MockERC20(Currency.unwrap(currency1)).mint(address(rival), 100 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(winner), 100 ether);
        vm.prank(address(rival));
        MockERC20(Currency.unwrap(currency1)).approve(address(auction), type(uint256).max);
        vm.prank(address(winner));
        MockERC20(Currency.unwrap(currency1)).approve(address(auction), type(uint256).max);

        oracle.setPrice(1.05e18);
        console2.log("Oracle now says currency0 is worth 5 percent more than the pool's live price");

        vm.prank(address(rival));
        auction.submitBid(poolId, 0.5 ether);
        console2.log("Rival bot bids 0.5 quote token for the right to correct this pool");

        vm.prank(address(winner));
        auction.submitBid(poolId, 1 ether);
        console2.log("Winning bot outbids the rival with 1.0 quote token");

        (address currentWinner, uint256 currentAmount) = auction.currentBid(poolId);
        console2.log("Current auction winner's bid amount", currentAmount);
        assertEq(currentWinner, address(winner), "second bidder must be the current winner");

        uint256 fundBalanceBefore = fund.balance(poolId);
        uint256 lpClaimableBefore = hook.claimableFor(lp);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1e15, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        vm.prank(address(winner));
        winner.doSwap(key, params);
        console2.log("Winner executed PoolManager.swap() directly -- ONE atomic transaction did:");
        console2.log("  1) SalvageHook.beforeSwap collected the 1.0 token bid into the fund");
        console2.log("  2) the swap itself ran");
        console2.log("  3) SalvageHook.afterSwap measured the oracle gap and credited the exposed LP");

        (, uint256 remainingBid) = auction.currentBid(poolId);
        console2.log("Bid remaining uncollected, must be zero", remainingBid);
        assertEq(remainingBid, 0, "no cure no pay: the winning bid must be fully collected");

        console2.log("Fund balance before", fundBalanceBefore);
        console2.log("Fund balance after", fund.balance(poolId));
        assertEq(fund.balance(poolId), fundBalanceBefore + 1 ether, "fund must hold the collected bid");

        uint256 lpClaimableAfter = hook.claimableFor(lp);
        console2.log("LP claimable loss before this swap", lpClaimableBefore);
        console2.log("LP claimable loss after this swap", lpClaimableAfter);
        assertGt(lpClaimableAfter, lpClaimableBefore, "swap against a mispriced oracle must accrue loss");

        console2.log("--- separate transaction: the LP actually claims ---");
        uint256 lpQuoteBefore = currency1AsIERC20().balanceOf(lp);
        uint256 paid = fund.claim(poolId, lp);
        uint256 lpQuoteAfter = currency1AsIERC20().balanceOf(lp);

        console2.log("LP claimed and was paid (quote token wei)", paid);
        console2.log("LP's real token balance moved by", lpQuoteAfter - lpQuoteBefore);
        assertEq(lpQuoteAfter - lpQuoteBefore, paid, "LP must actually receive the paid tokens");
        assertEq(paid, lpClaimableAfter, "full claimable amount must be paid (fund had enough)");
        assertEq(hook.claimableFor(lp), 0, "claim must fully settle the outstanding loss");

        console2.log("The whale's own bid just paid the LP it hit. No cure, no pay.");
    }
}
