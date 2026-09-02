// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

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
    using StateLibrary for IPoolManager;

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

    error NotThisBlocksWinner();
    error BidNotCollected();
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

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta, /* delta */
        BalanceDelta, /* feesAccrued */
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _requireThisPool(key);
        manifest.recordPosition(sender, params.tickLower, params.tickUpper, params.liquidityDelta);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta, /* delta */
        BalanceDelta, /* feesAccrued */
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _requireThisPool(key);
        // force settlement of any pending claim BEFORE the position size changes, or a later claim
        // calculation could use a liquidity figure that no longer matches what was actually exposed
        // during the loss event
        fund.claim(poolId, sender);
        manifest.recordPosition(sender, params.tickLower, params.tickUpper, params.liquidityDelta);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireThisPool(key);

        (uint160 sqrtPriceX96Now,,,) = poolManager.getSlot0(poolId);
        lossMeter.snapshotPriceBefore(sqrtPriceX96Now);

        if (sender == address(convoyBatch)) {
            // this call IS the solver's batch settlement — ConvoyBatch has already computed the
            // uniform clearing price and is now executing it; nothing further to gate here.
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // otherwise: treat as a salvage-auction-lane trade. Only this block's winning bidder is
        // allowed through this path.
        (address winner, uint256 bidAmount) = salvageAuction.currentBid(poolId);
        if (sender != winner) revert NotThisBlocksWinner();
        if (bidAmount == 0) revert BidNotCollected();

        // "no cure, no pay" lives in this call ordering: the bid is collected AND deposited into
        // the fund NOW, before the swap runs (SalvageAuction.collectBid does both atomically). If
        // the swap that follows reverts for any reason, this entire beforeSwap call reverts with
        // it, and the collection above is undone — the bot pays nothing for a rescue that didn't
        // happen.
        salvageAuction.collectBid(poolId, winner);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _requireThisPool(key);

        (uint256 realizedLoss, uint160 sqrtPriceBefore) = lossMeter.measureLoss(delta, oracle, oracleDecimals);

        if (realizedLoss > 0) {
            (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolId);
            ManifestLib.Exposure[] memory hit = manifest.getExposedRanges(
                TickMath.getTickAtSqrtPrice(sqrtPriceBefore), TickMath.getTickAtSqrtPrice(sqrtPriceAfter)
            );
            lossMeter.accrue(hit, realizedLoss);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _requireThisPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }
}
