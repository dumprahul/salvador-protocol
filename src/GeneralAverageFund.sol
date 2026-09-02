// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";
import {ISalvageHook} from "./interfaces/ISalvageHook.sol";

/// @title GeneralAverageFund
/// @notice Per-pool escrow with two income streams: auction proceeds (funded and paid out
/// atomically alongside a winning salvage bid) and a fee slice (a governance-set cut of ordinary
/// trading fees). Claims are paid the lesser of what's owed and what's available — an honest
/// partial settlement, never an inflated one.
///
/// @dev The architecture doc's pseudocode declares a single immutable `hook` per fund while also
/// keying every balance by `PoolId` — workable only if `hook` is generalized to a per-pool
/// registry, which is what this takes. Registration is owner-gated: access control is explicitly
/// out of scope for the architecture doc (section 15), but *some* minimal gate is required for the
/// per-pool hook binding to be safe.
contract GeneralAverageFund is IGeneralAverageFund {
    mapping(PoolId => uint256) public auctionStreamBalance;
    mapping(PoolId => uint256) public feeStreamBalance;
    mapping(PoolId => address) public hookForPool;
    mapping(PoolId => address) public auctionForPool;

    address public immutable owner;

    error NotOwner();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function registerPool(PoolId poolId, address hook_, address auction_) external onlyOwner {
        if (hookForPool[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookForPool[poolId] = hook_;
        auctionForPool[poolId] = auction_;
    }

    function depositAuctionProceeds(PoolId poolId, uint256 amount) external {
        address hook_ = hookForPool[poolId];
        if (hook_ == address(0)) revert PoolNotRegistered();
        if (msg.sender != hook_ && msg.sender != auctionForPool[poolId]) revert Unauthorized();
        auctionStreamBalance[poolId] += amount;
        emit AuctionProceedsDeposited(poolId, amount);
    }

    function depositFeeSlice(PoolId poolId, uint256 amount) external {
        feeStreamBalance[poolId] += amount;
        emit FeeSliceDeposited(poolId, amount);
    }

    function claim(PoolId poolId, address lp) external returns (uint256 paid) {
        address hook_ = hookForPool[poolId];
        if (hook_ == address(0)) revert PoolNotRegistered();

        uint256 owed = ISalvageHook(hook_).claimableFor(lp);
        if (owed == 0) return 0;

        uint256 available = auctionStreamBalance[poolId] + feeStreamBalance[poolId];
        paid = owed > available ? available : owed; // honest partial settlement on shortfall
        if (paid == 0) return 0;

        uint256 fromAuction = paid > auctionStreamBalance[poolId] ? auctionStreamBalance[poolId] : paid;
        auctionStreamBalance[poolId] -= fromAuction;
        feeStreamBalance[poolId] -= (paid - fromAuction);

        ISalvageHook(hook_).settleClaim(lp, paid);

        emit Claimed(poolId, lp, owed, paid);
    }

    function balance(PoolId poolId) external view returns (uint256) {
        return auctionStreamBalance[poolId] + feeStreamBalance[poolId];
    }
}
