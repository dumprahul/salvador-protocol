// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import {GeneralAverageFund} from "../src/GeneralAverageFund.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IVolatilityFeed} from "../src/interfaces/IVolatilityFeed.sol";

import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockVolatilityFeed} from "./mocks/MockVolatilityFeed.sol";
import {Bidder} from "./helpers/Bidder.sol";

/// @notice End-to-end integration test: a real PoolManager, a real mined SalvageHook address, and
/// the full satellite deployment sequence. Uses Uniswap's own `Deployers` test harness (a real
/// `PoolManager` + `PoolSwapTest`/`PoolModifyLiquidityTest` routers, real `MockERC20` currencies)
/// rather than any custom pool stand-in — this is what "tested against a local v4 pool fork"
/// (architecture doc, build order step 2) means in a Foundry test: a freshly deployed, fully real
/// `PoolManager`, not a fork of a live chain.
contract SalvageHookTest is Deployers {
    SalvageHook internal hook;
    SalvageAuction internal auction;
    ConvoyBatch internal convoyBatch;
    GeneralAverageFund internal fund;
    MockPriceOracle internal oracle;
    MockVolatilityFeed internal volFeed;

    PoolId internal poolId;
    address internal lp; // the address v4 attributes liquidity to: the modifyLiquidityRouter itself

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies(); // sets global currency0/currency1, sorted

        // currency1 is the designated quote token throughout (see LossMeterLib.measureLoss's
        // documented oracle convention: price of currency0 denominated in currency1).
        oracle = new MockPriceOracle(18, 1e18); // starts at parity; nudged per-test below
        volFeed = new MockVolatilityFeed();

        fund = new GeneralAverageFund(address(this));
        auction = new SalvageAuction(IVolatilityFeed(address(volFeed)), fund, address(this));
        convoyBatch = new ConvoyBatch(manager, address(this), address(this));

        // Mine a hook address with exactly the four permission bits SalvageHook needs.
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

        // Wire the satellites together, exactly the deployment sequence the contracts' own
        // NatSpec describes.
        fund.registerPool(poolId, address(hook), currency1AsIERC20());
        fund.setAuthorizedDepositor(poolId, address(auction), true);
        auction.registerPool(poolId, address(hook), currency1AsIERC20());
        convoyBatch.registerPool(poolId, key);

        manager.initialize(key, SQRT_PRICE_1_1);

        // LP deposits through the stock v4 router — v4 attributes the position to whichever
        // address directly called PoolManager.modifyLiquidity(), which is the router itself (see
        // PoolModifyLiquidityTest.unlockCallback). This matches the architecture doc's "LP deposit"
        // call-flow: "LP calls v4 PositionManager.modifyLiquidity() directly (stock v4, no custom
        // code)".
        lp = address(modifyLiquidityRouter);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function currency1AsIERC20() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency1));
    }

    /// @notice A plain swap through a stock router is never allowed through this pool: the caller
    /// is neither ConvoyBatch nor the current auction winner.
    function test_ungatedSwapReverts() public {
        // v4 wraps hook reverts in CustomRevert.WrappedError (ERC-7751), so we can't match the bare
        // selector here — the underlying revert (visible with -vvvv) is NotThisBlocksWinner.
        vm.expectRevert();
        swap(key, false, -1e15, ZERO_BYTES);
    }

    /// @notice SalvageAuction.windowLength widens under measured volatility and stays tight when
    /// calm — the storm-scaled window from architecture doc section VI.
    function test_stormScaledWindow() public {
        volFeed.setVolatility(poolId, 10); // calm
        assertEq(auction.windowLength(poolId), auction.MIN_WINDOW_BLOCKS());

        volFeed.setVolatility(poolId, 10_000); // storm
        assertEq(auction.windowLength(poolId), auction.MAX_WINDOW_BLOCKS());

        volFeed.setVolatility(poolId, 275); // midpoint between the two thresholds
        uint256 mid = auction.windowLength(poolId);
        assertGt(mid, auction.MIN_WINDOW_BLOCKS());
        assertLt(mid, auction.MAX_WINDOW_BLOCKS());
    }

    /// @notice The full salvage-auction lane, matching architecture doc section 13's walkthrough:
    /// bid -> winner's own swap -> beforeSwap gate + bid collection + fund deposit -> swap executes
    /// -> afterSwap measures the oracle gap -> loss accrues to the exposed LP -> LP claims and is
    /// paid from the very bid that was just collected.
    function test_salvageAuctionLane_fullPipeline() public {
        Bidder bidder = new Bidder(manager);

        // Fund the bidder: quote token to pay the auction bid, plus both currencies to settle the
        // swap itself (it's paying currency1 in, receiving currency0 out — see the oracle gap
        // direction chosen below).
        MockERC20(Currency.unwrap(currency1)).mint(address(bidder), 100 ether);
        vm.prank(address(bidder));
        MockERC20(Currency.unwrap(currency1)).approve(address(auction), type(uint256).max);

        // Oracle says currency0 is worth 5% more (in currency1 terms) than the pool's ~1:1 price.
        // Buying currency0 from the pool at ~1:1 while it's "really" worth 1.05 is exactly the
        // LVR mechanism from the whitepaper's own worked example (section II): the trader captures
        // the gap, which the loss meter must attribute to the exposed LP.
        oracle.setPrice(1.05e18);

        uint256 bidAmount = 1 ether;
        vm.prank(address(bidder));
        auction.submitBid(poolId, bidAmount);

        (address winner, uint256 amount) = auction.currentBid(poolId);
        assertEq(winner, address(bidder));
        assertEq(amount, bidAmount);

        uint256 fundBalanceBefore = fund.balance(poolId);

        // Small trade, well inside the LP's [-120, 120] tick range: pay currency1, receive
        // currency0 (zeroForOne = false), exact input.
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1e15, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        vm.prank(address(bidder));
        bidder.doSwap(key, params);

        // "No cure, no pay" collection: the bid is gone from the auction and landed in the fund.
        (, uint256 remainingBid) = auction.currentBid(poolId);
        assertEq(remainingBid, 0, "bid should be collected");
        assertEq(fund.balance(poolId), fundBalanceBefore + bidAmount, "fund should hold the collected bid");

        // The exposed LP now has a real, nonzero claim.
        uint256 claimable = hook.claimableFor(lp);
        assertGt(claimable, 0, "swap against a mispriced oracle must accrue a measurable loss to the LP");

        // The LP claims and is actually paid real tokens out of the fund the bid just filled.
        uint256 lpBalanceBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(lp);
        uint256 paid = fund.claim(poolId, lp);

        assertGt(paid, 0, "claim should pay out something");
        assertEq(paid, claimable > bidAmount ? bidAmount : claimable, "paid = min(owed, available)");
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(lp),
            lpBalanceBefore + paid,
            "LP must actually receive tokens"
        );
        assertEq(
            hook.claimableFor(lp), claimable - paid, "checkpoint must reduce outstanding claim by exactly what was paid"
        );
    }

    /// @notice A stale oracle zeroes the loss measurement rather than reverting the trade — the
    /// architecture doc's documented default (section "measureLoss" / build roadmap open item).
    function test_staleOracle_zeroesLossWithoutRevertingTrade() public {
        Bidder bidder = new Bidder(manager);
        MockERC20(Currency.unwrap(currency1)).mint(address(bidder), 100 ether);
        vm.prank(address(bidder));
        MockERC20(Currency.unwrap(currency1)).approve(address(auction), type(uint256).max);

        vm.warp(10 hours); // give ourselves room to move the oracle's updatedAt into the past
        oracle.setPrice(1.05e18);
        oracle.setStale(block.timestamp - 2 hours); // older than LossMeterLib.MAX_ORACLE_STALENESS

        vm.prank(address(bidder));
        auction.submitBid(poolId, 1 ether);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1e15, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        vm.prank(address(bidder));
        bidder.doSwap(key, params); // must not revert

        assertEq(hook.claimableFor(lp), 0, "stale oracle must not accrue any loss");
    }
}
