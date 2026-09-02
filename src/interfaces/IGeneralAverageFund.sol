// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IGeneralAverageFund {
    event AuctionProceedsDeposited(PoolId indexed poolId, uint256 amount);
    event FeeSliceDeposited(PoolId indexed poolId, uint256 amount);
    event Claimed(PoolId indexed poolId, address indexed lp, uint256 owed, uint256 paid);

    error Unauthorized();

    /// @notice Deposit a winning salvage-auction bid into `poolId`'s fund. Callable by the hook
    /// or the salvage auction contract, atomically alongside bid collection.
    function depositAuctionProceeds(PoolId poolId, uint256 amount) external;

    /// @notice Deposit a governance-set slice of ordinary trading fees into `poolId`'s fund.
    function depositFeeSlice(PoolId poolId, uint256 amount) external;

    /// @notice Settle `lp`'s accrued loss-share claim for `poolId`, paying out of whichever
    /// stream(s) currently hold balance. Pays the lesser of what is owed and what is available —
    /// an honest partial settlement on shortfall, never an inflated one.
    function claim(PoolId poolId, address lp) external returns (uint256 paid);

    /// @notice Combined balance (auction stream + fee stream) currently escrowed for `poolId`.
    function balance(PoolId poolId) external view returns (uint256);
}
