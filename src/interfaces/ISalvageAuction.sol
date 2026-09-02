// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISalvageAuction {
    event BidSubmitted(PoolId indexed poolId, address indexed bidder, uint256 amount);
    event BidCollected(PoolId indexed poolId, address indexed winner, uint256 amount);

    error WindowClosed();
    error NotHook();
    error AlreadyCollected();
    error BidTooLow();

    /// @notice Submit or raise a bid for the right to correct `poolId`'s stale price this window.
    function submitBid(PoolId poolId, uint256 amount) external;

    /// @notice Length, in blocks, of the currently open (or most recently opened) bidding window
    /// for `poolId`, scaled by recent measured volatility.
    function windowLength(PoolId poolId) external view returns (uint256 blocks);

    /// @notice The current winning bidder and their (uncollected) bid amount for `poolId`.
    /// Returns amount == 0 once the winning bid has already been collected this window.
    function currentBid(PoolId poolId) external view returns (address winner, uint256 amount);

    /// @notice Collects the winning bid for `poolId` on behalf of `winner`. Callable only by the hook,
    /// and only once per window. Reverts (undoing collection) if the swap that follows reverts too —
    /// this is what implements "no cure, no pay".
    function collectBid(PoolId poolId, address winner) external;
}
