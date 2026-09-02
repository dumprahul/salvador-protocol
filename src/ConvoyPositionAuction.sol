// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IConvoyPositionAuction} from "./interfaces/IConvoyPositionAuction.sol";

/// @title ConvoyPositionAuction
/// @notice Market-priced payout order: LPs bid for one of a limited number of "protected" payout
/// slots by sacrificing a share of their fee income; `GeneralAverageFund.claim` is meant to consult
/// `payoutRank` when multiple claimants compete for a shortfall in the same block, paying lower
/// ranks first (see architecture doc section 10 — wiring this into the fund is a later-stage
/// addition per the roadmap, once the core path is stable).
///
/// @dev Per-pool: one auction instance per pool, since fee-share sacrifice and protected slots are
/// meaningful only within a single pool's economics.
contract ConvoyPositionAuction is IConvoyPositionAuction {
    struct Bid {
        address lp;
        uint256 feeShareSacrificed;
    }

    Bid[] public epochBids;
    mapping(address => uint8) internal _payoutRankPlusOne; // 0 = unranked (mapping default), else rank+1
    mapping(address => bool) internal _hasBidThisEpoch;

    uint8 public constant PROTECTED_SLOTS = 2;
    uint8 public constant UNRANKED = type(uint8).max;
    uint256 public epoch;

    function bidForProtection(uint256 feeShareSacrificed) external {
        require(!_hasBidThisEpoch[msg.sender], "already bid this epoch");
        _hasBidThisEpoch[msg.sender] = true;
        epochBids.push(Bid({lp: msg.sender, feeShareSacrificed: feeShareSacrificed}));
        emit ProtectionBid(msg.sender, feeShareSacrificed);
    }

    /// @notice Sort the epoch's bids descending by fee share sacrificed and assign payout ranks
    /// 0..PROTECTED_SLOTS-1 to the top bidders.
    function resolveEpoch() external {
        uint256 n = epochBids.length;

        for (uint256 i = 1; i < n; i++) {
            Bid memory key = epochBids[i];
            uint256 j = i;
            while (j > 0 && epochBids[j - 1].feeShareSacrificed < key.feeShareSacrificed) {
                epochBids[j] = epochBids[j - 1];
                j--;
            }
            epochBids[j] = key;
        }

        for (uint256 i = 0; i < n; i++) {
            address lp = epochBids[i].lp;
            _payoutRankPlusOne[lp] = i < PROTECTED_SLOTS ? uint8(i + 1) : 0;
            _hasBidThisEpoch[lp] = false;
        }

        emit EpochResolved(epoch, n);
        epoch += 1;
        delete epochBids;
    }

    function payoutRank(address lp) external view returns (uint8) {
        uint8 plusOne = _payoutRankPlusOne[lp];
        return plusOne == 0 ? UNRANKED : plusOne - 1;
    }
}
