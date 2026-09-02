// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Supplies recent realized volatility for a pool, used to storm-scale the salvage
/// auction's bidding window. Implementation (e.g. a rolling on-chain estimator, or a pushed
/// off-chain feed) is intentionally out of scope for this architecture.
interface IVolatilityFeed {
    /// @return volBps Recent realized volatility for `poolId`, in basis points.
    function recentVolatility(PoolId poolId) external view returns (uint256 volBps);
}
