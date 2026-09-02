// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Surface a SalvageHook exposes to other protocol contracts: FleetSettlement reads the
/// most recently measured gap; the pool's GeneralAverageFund reads and settles LP claims.
interface ISalvageHook {
    /// @notice The realized loss (in quote-token terms) measured on the most recent swap for
    /// `poolId`. Used by FleetSettlement to split a bundled bid proportionally across pools.
    function lastMeasuredGap(PoolId poolId) external view returns (uint256);

    /// @notice Total outstanding claimable loss-share across every range `lp` has ever opened in
    /// this hook's pool.
    function claimableFor(address lp) external view returns (uint256 totalOwed);

    /// @notice Settle `paid` against `lp`'s outstanding claim. Callable only by this hook's
    /// general average fund.
    function settleClaim(address lp, uint256 paid) external;
}
