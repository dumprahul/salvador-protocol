// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
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
/// registry, which is what this takes. Registration is owner-gated: access control is explicitly
/// out of scope for the architecture doc (section 15), but *some* minimal gate is required for the
/// per-pool hook binding to be safe, so a simple deployer-owner fills that gap pragmatically.
///
/// @dev Both `depositAuctionProceeds` and `depositFeeSlice` pull real ERC20 balance via
/// `transferFrom` — the architecture doc's pseudocode only bumps an internal counter, but a fund
/// that can pay out claims it never actually received would be exactly the Bancor failure mode
/// this design is explicitly built to avoid.
///
/// @dev `depositAuctionProceeds` always sources tokens from `msg.sender` (which must already hold
/// and have approved them) rather than from a fixed, single registered auction address. This is
/// what lets more than one kind of caller fund a pool's auction stream — SalvageAuction.collectBid
/// for the ordinary single-pool lane, and FleetSettlement.submitBundledBid for the bundled
/// cross-pool lane — without the fund needing to know about FleetSettlement specifically. Callers
/// are allowlisted per pool via `authorizedDepositors`.
/// @custom:security-contact See SECURITY.md
contract GeneralAverageFund is IGeneralAverageFund {
    using SafeERC20 for IERC20;

    mapping(PoolId => uint256) public auctionStreamBalance;
    mapping(PoolId => uint256) public feeStreamBalance;
    mapping(PoolId => address) public hookForPool;
    mapping(PoolId => IERC20) public quoteTokenForPool;
    mapping(PoolId => mapping(address => bool)) public authorizedDepositors;

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

    /// @notice One-time binding of a pool's hook and quote token. Callable only by the
    /// deployer-owner, once per pool.
    function registerPool(PoolId poolId, address hook_, IERC20 quoteToken_) external onlyOwner {
        if (hookForPool[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookForPool[poolId] = hook_;
        quoteTokenForPool[poolId] = quoteToken_;
    }

    /// @notice Authorize (or revoke) `depositor` as a source of auction proceeds for `poolId` —
    /// e.g. that pool's SalvageAuction, or a shared FleetSettlement contract.
    function setAuthorizedDepositor(PoolId poolId, address depositor, bool allowed) external onlyOwner {
        authorizedDepositors[poolId][depositor] = allowed;
    }

    /// @notice Pulls `amount` of the pool's quote token from `msg.sender`, which must be an
    /// authorized depositor for `poolId` and must already hold and have approved the tokens (see
    /// SalvageAuction.collectBid and FleetSettlement.submitBundledBid).
    function depositAuctionProceeds(PoolId poolId, uint256 amount) external {
        if (hookForPool[poolId] == address(0)) revert PoolNotRegistered();
        if (!authorizedDepositors[poolId][msg.sender]) revert Unauthorized();

        quoteTokenForPool[poolId].safeTransferFrom(msg.sender, address(this), amount);
        auctionStreamBalance[poolId] += amount;
        emit AuctionProceedsDeposited(poolId, amount);
    }

    /// @notice Pulls `amount` of the pool's quote token from the caller (the pool's governance-set
    /// fee-routing address) into the fee stream.
    function depositFeeSlice(PoolId poolId, uint256 amount) external {
        IERC20 token = quoteTokenForPool[poolId];
        if (address(token) == address(0)) revert PoolNotRegistered();

        token.safeTransferFrom(msg.sender, address(this), amount);
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

        // drain auction stream first, then fee stream
        uint256 fromAuction = paid > auctionStreamBalance[poolId] ? auctionStreamBalance[poolId] : paid;
        auctionStreamBalance[poolId] -= fromAuction;
        feeStreamBalance[poolId] -= (paid - fromAuction);

        // checkpoint the LP in the hook's loss meter so the same amount can't be re-claimed
        ISalvageHook(hook_).settleClaim(lp, paid);

        quoteTokenForPool[poolId].safeTransfer(lp, paid);

        emit Claimed(poolId, lp, owed, paid);
    }

    function balance(PoolId poolId) external view returns (uint256) {
        return auctionStreamBalance[poolId] + feeStreamBalance[poolId];
    }
}
