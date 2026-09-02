// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ISalvageAuction} from "./interfaces/ISalvageAuction.sol";
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
    struct Bid {
        address bidder;
        uint256 amount;
        bool collected;
    }

    mapping(PoolId => Bid) public winningBid;
    mapping(PoolId => uint256) public windowStart;
    mapping(PoolId => address) public hookForPool;
    mapping(PoolId => IERC20) public quoteTokenForPool;

    IGeneralAverageFund public immutable fund;
    address public immutable owner;

    error NotOwner();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IGeneralAverageFund _fund, address _owner) {
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
        if (amount <= winningBid[poolId].amount) revert BidTooLow();
        winningBid[poolId] = Bid({bidder: msg.sender, amount: amount, collected: false});
        emit BidSubmitted(poolId, msg.sender, amount);
    }

    function currentBid(PoolId poolId) external view returns (address winner, uint256 amount) {
        Bid memory b = winningBid[poolId];
        return (b.bidder, b.collected ? 0 : b.amount);
    }

    function collectBid(PoolId poolId, address winner) external {
        if (msg.sender != hookForPool[poolId]) revert NotHook();
        Bid storage b = winningBid[poolId];
        if (b.collected) revert AlreadyCollected();
        b.collected = true;

        IERC20 token = quoteTokenForPool[poolId];
        token.transferFrom(winner, address(this), b.amount);
        token.approve(address(fund), b.amount);

        emit BidCollected(poolId, winner, b.amount);
    }
}
