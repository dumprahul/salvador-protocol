// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";
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
        convoyBatch = new ConvoyBatch(manager, address(this)); // trusted-single-solver stub; not exercised here

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
}
