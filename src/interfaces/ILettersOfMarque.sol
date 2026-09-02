// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILettersOfMarque {
    event BondPosted(address indexed lp, uint256 amount);
    event BondWithdrawn(address indexed lp, uint256 amount);
    event JITPenalized(address indexed lp, uint256 taxAmount);
    event Slashed(address indexed lp, uint256 amount);

    error OnlyHook();
    error InsufficientBond();

    /// @notice Post bond to become licensed for just-in-time liquidity provision.
    function postBond(uint256 amount) external;

    /// @notice Whether `lp` currently holds enough bond to be considered a licensed JIT provider.
    function isLicensed(address lp) external view returns (bool);

    /// @notice Tax an unlicensed LP whose deposit landed inside the final-approach window before
    /// a detected large trade. Callable only by the hook.
    function penalizeUnbondedJIT(address lp, uint256 taxAmount) external;

    /// @notice Slash a licensed LP's bond for misbehavior. Callable only by the hook.
    function slash(address lp, uint256 amount) external;
}
