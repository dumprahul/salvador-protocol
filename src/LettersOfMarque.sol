// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILettersOfMarque} from "./interfaces/ILettersOfMarque.sol";

/// @title LettersOfMarque
/// @notice Bonded JIT-liquidity licensing, shared across every pool's hook. An LP posts a bond in
/// the governance-set bond token; once bonded above `MIN_BOND` they're "licensed" and exempt from
/// the JIT tax a hook applies to unbonded deposits landing in the final-approach window before a
/// detected large trade (see architecture doc section 9 — wiring this into
/// `SalvageHook._afterAddLiquidity` is deliberately deferred until the core path is tested).
///
/// @dev A single global registry, not per-pool: any registered hook may penalize or slash any LP,
/// since JIT sniping is the same behavior regardless of which pool it targets. Hook registration is
/// owner-gated for the same minimal-access-control reason as the other satellites.
/// @custom:security-contact See SECURITY.md
contract LettersOfMarque is ILettersOfMarque {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public bondedAmount;
    mapping(address => bool) public isHook;

    IERC20 public immutable bondToken;
    address public immutable owner;
    uint256 public constant MIN_BOND = 10_000e18; // governance-set

    error NotOwner();
    error OnlyHookCaller();
    error InsufficientBondedBalance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyHook() {
        if (!isHook[msg.sender]) revert OnlyHookCaller();
        _;
    }

    constructor(IERC20 _bondToken, address _owner) {
        bondToken = _bondToken;
        owner = _owner;
    }

    function setHook(address hook_, bool allowed) external onlyOwner {
        isHook[hook_] = allowed;
    }

    function postBond(uint256 amount) external {
        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        bondedAmount[msg.sender] += amount;
        emit BondPosted(msg.sender, amount);
    }

    /// @notice Withdraw bond down to (but not below) MIN_BOND is not required — an LP may fully
    /// exit and simply stop being licensed. `slash` and `penalizeUnbondedJIT` reduce the bonded
    /// balance directly; this lets an LP withdraw whatever remains under their own control.
    function withdrawBond(uint256 amount) external {
        if (amount > bondedAmount[msg.sender]) revert InsufficientBondedBalance();
        bondedAmount[msg.sender] -= amount;
        bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    function isLicensed(address lp) external view returns (bool) {
        return bondedAmount[lp] >= MIN_BOND;
    }

    function penalizeUnbondedJIT(address lp, uint256 taxAmount) external onlyHook {
        uint256 bonded = bondedAmount[lp];
        uint256 seized = taxAmount > bonded ? bonded : taxAmount;
        bondedAmount[lp] = bonded - seized;
        emit JITPenalized(lp, seized);
    }

    function slash(address lp, uint256 amount) external onlyHook {
        uint256 bonded = bondedAmount[lp];
        uint256 seized = amount > bonded ? bonded : amount;
        bondedAmount[lp] = bonded - seized;
        emit Slashed(lp, seized);
    }
}
