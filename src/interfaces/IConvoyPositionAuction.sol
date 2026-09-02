// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IConvoyPositionAuction {
    event ProtectionBid(address indexed lp, uint256 feeShareSacrificed);
    event EpochResolved(uint256 indexed epoch, uint256 bidCount);

    /// @notice Bid for one of this epoch's protected payout slots by sacrificing a share of fees.
    function bidForProtection(uint256 feeShareSacrificed) external;

    /// @notice Sort the epoch's bids and assign payout ranks to the top bidders.
    function resolveEpoch() external;

    /// @notice 0 = paid first when the general average fund is short on a claim. Any LP without a
    /// protected slot reads back the sentinel `UNRANKED`.
    function payoutRank(address lp) external view returns (uint8);
}
