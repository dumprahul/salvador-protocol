// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IFleetSettlement} from "./interfaces/IFleetSettlement.sol";
import {ISalvageHook} from "./interfaces/ISalvageHook.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";

/// @title FleetSettlement
/// @notice UPCOMING per the whitepaper (section IX) and explicitly "build last, budget the most
/// audit time here" per the architecture doc's build order — the shared settlement layer across
/// multiple already-trustworthy pool hooks, the highest-risk new surface in the whole system.
///
/// Bundles salvage corrections across correlated pools into one bid, splitting it across each
/// pool's general average fund strictly in proportion to that pool's own, independently measured
/// gap (`ISalvageHook.lastMeasuredGap`) — never a caller-supplied split, so no pool's hook has to
/// trust the bidder's claim about how to divide it.
contract FleetSettlement is IFleetSettlement {
    mapping(PoolId => address) public hookFor;
    mapping(PoolId => address) public fundFor;
    address public immutable owner;

    error NotOwner();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error NoMeasuredGap();
    error EmptyBundle();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function registerPool(PoolId poolId, address hook_, address fund_) external onlyOwner {
        if (hookFor[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookFor[poolId] = hook_;
        fundFor[poolId] = fund_;
    }

    /// @notice Split `totalBid` across `pools`' funds by each pool's own measured gap.
    function submitBundledBid(PoolId[] calldata pools, uint256 totalBid, IERC20 bidToken) external {
        uint256 n = pools.length;
        if (n == 0) revert EmptyBundle();

        uint256[] memory gaps = new uint256[](n);
        uint256 sumGaps;
        for (uint256 i = 0; i < n; i++) {
            address hook_ = hookFor[pools[i]];
            if (hook_ == address(0)) revert PoolNotRegistered();
            gaps[i] = ISalvageHook(hook_).lastMeasuredGap(pools[i]);
            sumGaps += gaps[i];
        }
        if (sumGaps == 0) revert NoMeasuredGap();

        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            uint256 share;
            if (i == n - 1) {
                share = totalBid - distributed; // last pool absorbs rounding remainder
            } else {
                share = FullMath.mulDiv(totalBid, gaps[i], sumGaps);
                distributed += share;
            }
            if (share > 0) {
                address fund_ = fundFor[pools[i]];
                bidToken.approve(fund_, share);
                IGeneralAverageFund(fund_).depositAuctionProceeds(pools[i], share);
            }
        }

        emit BundledBidSettled(totalBid, n);
    }
}
