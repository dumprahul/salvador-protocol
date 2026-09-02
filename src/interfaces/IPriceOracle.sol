// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mirrors Chainlink's AggregatorV3Interface exactly, so any Chainlink feed
/// (or Chainlink-compatible feed) can be used directly without an adapter.
interface IPriceOracle {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
