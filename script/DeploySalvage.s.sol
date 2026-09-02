// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
        convoyBatch = new ConvoyBatch(poolManager, vm.envAddress("AUTHORIZED_SOLVER"));

        console.log("GeneralAverageFund:", address(fund));
        console.log("SalvageAuction:", address(auction));
        console.log("ConvoyBatch:", address(convoyBatch));

        vm.stopBroadcast();
    }
}
