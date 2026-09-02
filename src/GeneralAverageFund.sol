// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";
import {ISalvageHook} from "./interfaces/ISalvageHook.sol";

/// @title GeneralAverageFund
/// @notice Per-pool escrow with two income streams: auction proceeds (funded and paid out
/// atomically alongside a winning salvage bid) and a fee slice (a governance-set cut of ordinary
/// trading fees, genuinely accumulating as a standing balance). Claims are paid the lesser of
/// what's owed and what's available — an honest partial settlement, never an inflated one; see the
/// whitepaper's Bancor comparison for why that "no minting" property is the whole point.
///
/// @dev The architecture doc's pseudocode declares a single immutable `hook` per fund while also
/// keying every balance by `PoolId` — workable only if `hook` is generalized to a per-pool
/// registry, which is what this takes. Registration is owner-gated.
///
/// @dev Both `depositAuctionProceeds` and `depositFeeSlice` pull real ERC20 balance via
/// `transferFrom` — the architecture doc's pseudocode only bumps an internal counter, but a fund
/// that can pay out claims it never actually received would be exactly the Bancor failure mode
/// this design is explicitly built to avoid.
contract GeneralAverageFund is IGeneralAverageFund {
    mapping(PoolId => uint256) public auctionStreamBalance;
    mapping(PoolId => uint256) public feeStreamBalance;
    mapping(PoolId => address) public hookForPool;
    mapping(PoolId => address) public auctionForPool;
    mapping(PoolId => IERC20) public quoteTokenForPool;

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

    function registerPool(PoolId poolId, address hook_, address auction_, IERC20 quoteToken_) external onlyOwner {
        if (hookForPool[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookForPool[poolId] = hook_;
        auctionForPool[poolId] = auction_;
        quoteTokenForPool[poolId] = quoteToken_;
    }

    /// @notice Pulls `amount` of the pool's quote token from the salvage auction contract, which
    /// must have already approved this fund (see SalvageAuction.collectBid).
    function depositAuctionProceeds(PoolId poolId, uint256 amount) external {
        address hook_ = hookForPool[poolId];
        address auction_ = auctionForPool[poolId];
        if (hook_ == address(0)) revert PoolNotRegistered();
        if (msg.sender != hook_ && msg.sender != auction_) revert Unauthorized();

        quoteTokenForPool[poolId].transferFrom(auction_, address(this), amount);
        auctionStreamBalance[poolId] += amount;
        emit AuctionProceedsDeposited(poolId, amount);
    }

    function depositFeeSlice(PoolId poolId, uint256 amount) external {
        IERC20 token = quoteTokenForPool[poolId];
        if (address(token) == address(0)) revert PoolNotRegistered();

        token.transferFrom(msg.sender, address(this), amount);
        feeStreamBalance[poolId] += amount;
        emit FeeSliceDeposited(poolId, amount);
    }

    function claim(PoolId poolId, address lp) external returns (uint256 paid) {
        address hook_ = hookForPool[poolId];
        if (hook_ == address(0)) revert PoolNotRegistered();

        uint256 owed = ISalvageHook(hook_).claimableFor(lp);
        if (owed == 0) return 0;

        uint256 available = auctionStreamBalance[poolId] + feeStreamBalance[poolId];
        paid = owed > available ? available : owed;
        if (paid == 0) return 0;

        uint256 fromAuction = paid > auctionStreamBalance[poolId] ? auctionStreamBalance[poolId] : paid;
        auctionStreamBalance[poolId] -= fromAuction;
        feeStreamBalance[poolId] -= (paid - fromAuction);

        ISalvageHook(hook_).settleClaim(lp, paid);

        quoteTokenForPool[poolId].transfer(lp, paid);

        emit Claimed(poolId, lp, owed, paid);
    }

    function balance(PoolId poolId) external view returns (uint256) {
        return auctionStreamBalance[poolId] + feeStreamBalance[poolId];
    }
}
