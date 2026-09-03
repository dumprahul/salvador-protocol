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
import {IConvoyBatch} from "../src/interfaces/IConvoyBatch.sol";
import {GeneralAverageFund} from "../src/GeneralAverageFund.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IVolatilityFeed} from "../src/interfaces/IVolatilityFeed.sol";

import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockVolatilityFeed} from "./mocks/MockVolatilityFeed.sol";

/// @notice Exercises the retail/convoy lane's settlement execution end to end: a real
/// `PoolManager.swap()` call made by `ConvoyBatch` itself (satisfying `SalvageHook`'s
/// `sender == address(convoyBatch)` check), with real ERC20 balances moving for the trader.
contract ConvoyBatchTest is Deployers {
    SalvageHook internal hook;
    SalvageAuction internal auction;
    ConvoyBatch internal convoyBatch;
    GeneralAverageFund internal fund;
    MockPriceOracle internal oracle;
    MockVolatilityFeed internal volFeed;

    PoolId internal poolId;
    address internal constant SOLVER = address(0xB0B0);
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
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function currency1AsIERC20() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency1));
    }

    function currency0AsIERC20() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency0));
    }

    /// @notice A whale-sized order (large enough to move price past the 1% threshold) is rejected
    /// at submission — it never even makes it into the batch.
    function test_classifyBySize_rejectsWhaleOrder() public {
        IConvoyBatch.Order memory whaleOrder =
            IConvoyBatch.Order({trader: RETAIL_TRADER, zeroForOne: false, amountIn: 500 ether, minOut: 0});

        assertFalse(convoyBatch.classifyBySize(poolId, whaleOrder));
        vm.expectRevert(IConvoyBatch.NotRetailSized.selector);
        vm.prank(RETAIL_TRADER);
        convoyBatch.submitToBatch(poolId, whaleOrder);
    }

    /// @notice A retail-sized order is accepted, and the solver's settleBatch call actually
    /// executes it against the real pool — `ConvoyBatch` itself calls `PoolManager.swap()`, so
    /// `SalvageHook._beforeSwap` waves it through with no auction bid required, and the trader's
    /// real ERC20 balances move by exactly what the swap produced.
    function test_settleBatch_executesRetailOrder() public {
        uint256 amountIn = 1e15; // small: well under the 1% price-impact threshold
        MockERC20(Currency.unwrap(currency1)).mint(RETAIL_TRADER, 1 ether);
        vm.prank(RETAIL_TRADER);
        MockERC20(Currency.unwrap(currency1)).approve(address(convoyBatch), type(uint256).max);

        IConvoyBatch.Order memory order =
            IConvoyBatch.Order({trader: RETAIL_TRADER, zeroForOne: false, amountIn: amountIn, minOut: 1});

        assertTrue(convoyBatch.classifyBySize(poolId, order));
        vm.prank(RETAIL_TRADER);
        convoyBatch.submitToBatch(poolId, order);

        uint256 traderQuoteBefore = currency1AsIERC20().balanceOf(RETAIL_TRADER);
        uint256 traderBaseBefore = currency0AsIERC20().balanceOf(RETAIL_TRADER);
        uint256 epochBefore = convoyBatch.currentEpoch(poolId);

        vm.prank(SOLVER);
        convoyBatch.settleBatch(poolId, MAX_PRICE_LIMIT, "");

        assertEq(convoyBatch.currentEpoch(poolId), epochBefore + 1, "epoch must advance");
        assertEq(
            currency1AsIERC20().balanceOf(RETAIL_TRADER),
            traderQuoteBefore - amountIn,
            "trader must pay exactly amountIn"
        );
        assertGt(
            currency0AsIERC20().balanceOf(RETAIL_TRADER), traderBaseBefore, "trader must actually receive base token"
        );
    }

    /// @notice A plain, non-ConvoyBatch, non-winning-bid swap is still rejected — the convoy lane's
    /// real execution doesn't loosen the auction lane's gate.
    function test_directSwapStillGated() public {
        vm.expectRevert();
        swap(key, false, -1e15, ZERO_BYTES);
    }
}
