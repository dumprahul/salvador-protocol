// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Minimal Chainlink-shaped oracle for tests: a settable price with a settable
/// "updatedAt" timestamp, so staleness behavior (LossMeterLib.MAX_ORACLE_STALENESS) can be
/// exercised deliberately.
contract MockPriceOracle is IPriceOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public immutable decimals_;

    constructor(uint8 _decimals, int256 _price) {
        decimals_ = _decimals;
        price = _price;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setStale(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (1, price, updatedAt, updatedAt, 1);
    }
}
