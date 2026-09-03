// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {SalvageHook} from "../src/SalvageHook.sol";
import {SalvageAuction} from "../src/SalvageAuction.sol";
import {ConvoyBatch} from "../src/ConvoyBatch.sol";
import {GeneralAverageFund} from "../src/GeneralAverageFund.sol";
import {IVolatilityFeed} from "../src/interfaces/IVolatilityFeed.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Deploys the SALVAGE satellite contracts for a single pool and mines + deploys that
/// pool's SalvageHook, wiring everything together in the order README.md's "Satellite wiring
/// order" section describes. Configure the pool's PoolManager, quote token, oracle, and
/// volatility feed via environment variables before running.
contract DeploySalvageScript is Script {
    IPoolManager public poolManager;
    IERC20 public quoteToken;
    IPriceOracle public oracle;
    IVolatilityFeed public volatilityFeed;

    GeneralAverageFund public fund;
    SalvageAuction public auction;
    ConvoyBatch public convoyBatch;

    function setUp() public {
        poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        quoteToken = IERC20(vm.envAddress("QUOTE_TOKEN"));
        oracle = IPriceOracle(vm.envAddress("PRICE_ORACLE"));
        volatilityFeed = IVolatilityFeed(vm.envAddress("VOLATILITY_FEED"));
    }

    function run() public {
        vm.startBroadcast();

        fund = new GeneralAverageFund(msg.sender);
        auction = new SalvageAuction(volatilityFeed, fund, msg.sender);
        convoyBatch = new ConvoyBatch(poolManager, vm.envAddress("AUTHORIZED_SOLVER"), msg.sender);

        console.log("GeneralAverageFund:", address(fund));
        console.log("SalvageAuction:", address(auction));
        console.log("ConvoyBatch:", address(convoyBatch));

        // Mine and deploy this pool's SalvageHook, then wire it into the fund and auction and
        // initialize the pool — the same six-step sequence README.md documents.
        Currency currency0 = Currency.wrap(vm.envAddress("CURRENCY0"));
        Currency currency1 = Currency.wrap(address(quoteToken));
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        int24 tickSpacing = int24(vm.envInt("POOL_TICK_SPACING"));
        uint160 sqrtPriceX96 = uint160(vm.envUint("INITIAL_SQRT_PRICE_X96"));

        PoolKey memory pendingKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(0))
        });

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, pendingKey, address(auction), address(convoyBatch), address(fund), address(oracle));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(msg.sender, flags, type(SalvageHook).creationCode, constructorArgs);

        SalvageHook hook = new SalvageHook{salt: salt}(poolManager, pendingKey, auction, convoyBatch, fund, oracle);
        require(address(hook) == hookAddress, "hook address mismatch");
        console.log("SalvageHook:", address(hook));

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hookAddress)
        });

        fund.registerPool(hook.poolId(), address(hook), quoteToken);
        fund.setAuthorizedDepositor(hook.poolId(), address(auction), true);
        auction.registerPool(hook.poolId(), address(hook), quoteToken);
        convoyBatch.registerPool(hook.poolId(), key);

        poolManager.initialize(key, sqrtPriceX96);

        vm.stopBroadcast();
    }
}
