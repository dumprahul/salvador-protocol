// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ISalvageAuction} from "./interfaces/ISalvageAuction.sol";
import {IVolatilityFeed} from "./interfaces/IVolatilityFeed.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";

/// @title SalvageAuction
/// @notice am-AMM / Angstrom-style priority auction, reframed as a salvage-reward market. Bots bid
/// for the right to correct a pool's stale price; the winning bid is only ever collected if the
/// correcting trade actually executes ("no cure, no pay" — enforced by the hook's call ordering,
/// not by this contract, since collection happens synchronously inside `_beforeSwap`).
///
/// @dev Same per-pool registry pattern as GeneralAverageFund, for the same reason: the doc's
/// pseudocode declares a single immutable `hook` while keying storage by `PoolId`.
contract SalvageAuction is ISalvageAuction {
    using SafeERC20 for IERC20;

    struct Bid {
        address bidder;
        uint256 amount;
        bool collected;
    }

    mapping(PoolId => Bid) public winningBid;
    mapping(PoolId => uint256) public windowStart;
    mapping(PoolId => address) public hookForPool;
    mapping(PoolId => IERC20) public quoteTokenForPool;

    IVolatilityFeed public immutable volatilityFeed;
    IGeneralAverageFund public immutable fund;
    address public immutable owner;

    /// @notice Governance-capped bounds for the storm-scaled window, in blocks.
    uint256 public constant MIN_WINDOW_BLOCKS = 1;
    uint256 public constant MAX_WINDOW_BLOCKS = 6;
    /// @notice Volatility (bps) below which the window sits at MIN_WINDOW_BLOCKS.
    uint256 public constant LOW_VOL_THRESHOLD_BPS = 50;
    /// @notice Volatility (bps) at or above which the window sits at MAX_WINDOW_BLOCKS.
    uint256 public constant HIGH_VOL_THRESHOLD_BPS = 500;

    error NotOwner();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IVolatilityFeed _volatilityFeed, IGeneralAverageFund _fund, address _owner) {
        volatilityFeed = _volatilityFeed;
        fund = _fund;
        owner = _owner;
    }

    function registerPool(PoolId poolId, address hook_, IERC20 quoteToken_) external onlyOwner {
        if (hookForPool[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookForPool[poolId] = hook_;
        quoteTokenForPool[poolId] = quoteToken_;
        windowStart[poolId] = block.number;
    }

    /// @notice Submit or raise a bid for `poolId`'s currently open window.
    function submitBid(PoolId poolId, uint256 amount) external {
        if (hookForPool[poolId] == address(0)) revert PoolNotRegistered();

        if (block.number >= windowStart[poolId] + windowLength(poolId)) {
            // previous window has lapsed with no collection (or already collected) — open a fresh one
            windowStart[poolId] = block.number;
            delete winningBid[poolId];
        }

        if (amount <= winningBid[poolId].amount) revert BidTooLow();
        winningBid[poolId] = Bid({bidder: msg.sender, amount: amount, collected: false});
        emit BidSubmitted(poolId, msg.sender, amount);
    }

    /// @notice Storm-scaled window length: widens under measured volatility so real competition
    /// has time to form; stays tight in calm markets so ordinary traders aren't delayed
    /// unnecessarily. Piecewise-linear between the governance-set low/high volatility thresholds.
    function windowLength(PoolId poolId) public view returns (uint256 blocks) {
        uint256 vol = volatilityFeed.recentVolatility(poolId);

        if (vol <= LOW_VOL_THRESHOLD_BPS) return MIN_WINDOW_BLOCKS;
        if (vol >= HIGH_VOL_THRESHOLD_BPS) return MAX_WINDOW_BLOCKS;

        uint256 span = HIGH_VOL_THRESHOLD_BPS - LOW_VOL_THRESHOLD_BPS;
        uint256 blockSpan = MAX_WINDOW_BLOCKS - MIN_WINDOW_BLOCKS;
        return MIN_WINDOW_BLOCKS + ((vol - LOW_VOL_THRESHOLD_BPS) * blockSpan) / span;
    }

    function currentBid(PoolId poolId) external view returns (address winner, uint256 amount) {
        Bid memory b = winningBid[poolId];
        return (b.bidder, b.collected ? 0 : b.amount);
    }

    /// @notice Collects the winner's bid and deposits it into the pool's general average fund in
    /// the same call — this contract must be registered as an authorized depositor for `poolId`
    /// on `fund` (see GeneralAverageFund.setAuthorizedDepositor).
    function collectBid(PoolId poolId, address winner) external {
        if (msg.sender != hookForPool[poolId]) revert NotHook();
        Bid storage b = winningBid[poolId];
        if (b.collected) revert AlreadyCollected();
        b.collected = true;

        IERC20 token = quoteTokenForPool[poolId];
        uint256 amount = b.amount;
        token.safeTransferFrom(winner, address(this), amount);
        token.forceApprove(address(fund), amount);
        fund.depositAuctionProceeds(poolId, amount);

        emit BidCollected(poolId, winner, amount);
    }
}
