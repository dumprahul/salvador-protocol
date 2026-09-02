// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ManifestLib} from "./ManifestLib.sol";

/// @title LossMeterLib
/// @notice Internal library (storage lives inside SalvageHook). Measures realized LVR per swap,
/// reusing Uniswap's feeGrowthGlobal pattern repointed at loss.
///
/// @dev A SalvageHook instance serves exactly one pool (v4 permits one hook address per pool — see
/// architecture doc section 1), so nothing here is keyed by PoolId; the hook itself is the
/// per-pool scope.
library LossMeterLib {
    struct Storage {
        uint256 lossGrowthGlobalX128; // observability only — mirrors feeGrowthGlobal's shape
        uint160 sqrtPriceBeforeSwap; // snapshot taken in _beforeSwap, consumed in _afterSwap
        uint256 lastMeasuredGap; // realized loss (quote-token wei) from the most recent swap
        mapping(bytes32 => uint256) claimableLoss; // position key => accrued, unclaimed loss-share
    }

    /// @notice Oracle reading older than this is treated as unusable for this swap (loss = 0),
    /// per the architecture doc's stale-price guard. Does NOT revert the trade.
    uint256 internal constant MAX_ORACLE_STALENESS = 1 hours;

    /// @notice Snapshot the pool's sqrtPriceX96 immediately before the swap executes, so
    /// `measureLoss` can later recover the tick range the trade crossed.
    function snapshotPriceBefore(Storage storage self, uint160 sqrtPriceX96Before) internal {
        self.sqrtPriceBeforeSwap = sqrtPriceX96Before;
    }

    /// @notice Compute the realized loss for the swap that just executed, comparing what the
    /// trader actually paid/received against what the oracle says it was worth. Convention:
    /// currency1 is the quote token — `oracle.latestRoundData()` returns the price of one unit of
    /// currency0 denominated in currency1, scaled by 10**oracle.decimals().
    ///
    /// A stale oracle zeroes the measurement for this swap rather than reverting the trade (the
    /// architecture doc leaves the alternative — pausing the salvage-auction lane entirely on
    /// stale data — as an open decision; zeroing is the less disruptive default).
    function measureLoss(Storage storage self, BalanceDelta delta, IPriceOracle oracle, uint8 oracleDecimals)
        internal
        returns (uint256 realizedLoss, uint160 sqrtPriceBefore)
    {
        sqrtPriceBefore = self.sqrtPriceBeforeSwap;

        (, int256 truePrice,, uint256 updatedAt,) = oracle.latestRoundData();
        if (block.timestamp - updatedAt >= MAX_ORACLE_STALENESS || truePrice <= 0) {
            self.lastMeasuredGap = 0;
            return (0, sqrtPriceBefore);
        }

        int128 d0 = BalanceDeltaLibrary.amount0(delta);
        int128 d1 = BalanceDeltaLibrary.amount1(delta);

        uint256 amount0Abs = d0 < 0 ? uint256(uint128(-d0)) : uint256(uint128(d0));
        uint256 amount0ValueInQuote = FullMath.mulDiv(amount0Abs, uint256(truePrice), 10 ** oracleDecimals);
        uint256 amount1Abs = d1 < 0 ? uint256(uint128(-d1)) : uint256(uint128(d1));

        if (d0 < 0 && d1 > 0) {
            realizedLoss = amount1Abs > amount0ValueInQuote ? amount1Abs - amount0ValueInQuote : 0;
        } else if (d1 < 0 && d0 > 0) {
            realizedLoss = amount0ValueInQuote > amount1Abs ? amount0ValueInQuote - amount1Abs : 0;
        } else {
            realizedLoss = 0;
        }

        self.lastMeasuredGap = realizedLoss;
    }

    /// @notice Distribute `totalLoss` across the positions `hit` reports as exposed, in proportion
    /// to each position's liquidity share of the total exposed liquidity.
    ///
    /// @dev Deviation from the architecture doc's `lossGrowthInside` checkpoint pattern, made
    /// deliberately per section 15's own warning: "a single flat lossGrowthGlobal bump is only
    /// correct when every exposed LP covers the SAME sub-range... do not ship the flat version
    /// believing it handles partial overlaps." A checkpoint-and-diff scheme that is correct under
    /// partial overlaps needs the full per-tick `lossGrowthOutside` walk Uniswap itself uses for
    /// fees — real, substantial additional machinery. Until that is built, `accrue` instead settles
    /// loss directly against the exact exposed-position list `ManifestLib.getExposedRanges` already
    /// computes. `lossGrowthGlobalX128` is retained purely as an observability accumulator; claims
    /// never read it.
    function accrue(Storage storage self, ManifestLib.Exposure[] memory hit, uint256 totalLoss) internal {
        if (totalLoss == 0 || hit.length == 0) return;

        uint256 totalLiquidity;
        for (uint256 i = 0; i < hit.length; i++) {
            totalLiquidity += hit[i].liquidity;
        }
        require(totalLiquidity > 0, "no exposed liquidity");

        self.lossGrowthGlobalX128 += FullMath.mulDiv(totalLoss, FixedPoint128.Q128, totalLiquidity);

        uint256 distributed;
        for (uint256 i = 0; i < hit.length; i++) {
            uint256 share;
            if (i == hit.length - 1) {
                // last position absorbs any rounding remainder so the sum exactly equals totalLoss
                share = totalLoss - distributed;
            } else {
                share = FullMath.mulDiv(totalLoss, hit[i].liquidity, totalLiquidity);
                distributed += share;
            }
            self.claimableLoss[hit[i].key] += share;
        }
    }
}
