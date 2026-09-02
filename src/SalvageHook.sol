// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {BaseHook} from "./hooks/BaseHook.sol";
import {ManifestLib} from "./libraries/ManifestLib.sol";
import {LossMeterLib} from "./libraries/LossMeterLib.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISalvageAuction} from "./interfaces/ISalvageAuction.sol";
import {IConvoyBatch} from "./interfaces/IConvoyBatch.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";

/// @title SalvageHook
/// @notice The single v4 hook contract for one pool. Owns the Manifest and Loss Meter as internal
/// library storage (see architecture doc section 1 for why those two are libraries, not separate
/// deployed contracts) and routes the two trading lanes — salvage-auction and convoy-batch — into
/// SalvageAuction / ConvoyBatch / GeneralAverageFund, the independently deployed satellite
/// contracts that legitimately need their own security boundary.
contract SalvageHook is BaseHook {
    using ManifestLib for ManifestLib.Storage;
    using LossMeterLib for LossMeterLib.Storage;
    using PoolIdLibrary for PoolKey;

    ManifestLib.Storage internal manifest;
    LossMeterLib.Storage internal lossMeter;

    ISalvageAuction public immutable salvageAuction;
    IConvoyBatch public immutable convoyBatch;
    IGeneralAverageFund public immutable fund;
    IPriceOracle public immutable oracle;
    uint8 public immutable oracleDecimals;

    /// @dev Cached at construction; every external call site assumes this hook instance serves
    /// exactly one pool (see architecture doc section 1 — v4 permits one hook address per pool).
    PoolId public immutable poolId;

    error WrongPool();

    constructor(
        IPoolManager _poolManager,
        PoolKey memory _key,
        ISalvageAuction _salvageAuction,
        IConvoyBatch _convoyBatch,
        IGeneralAverageFund _fund,
        IPriceOracle _oracle
    ) BaseHook(_poolManager) {
        salvageAuction = _salvageAuction;
        convoyBatch = _convoyBatch;
        fund = _fund;
        oracle = _oracle;
        oracleDecimals = _oracle.decimals();
        poolId = _key.toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // manifest must hear about new positions
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // manifest must hear about closed positions
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

    function _requireThisPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }
}
