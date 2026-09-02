// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IVolatilityFeed} from "../../src/interfaces/IVolatilityFeed.sol";

/// @notice Settable volatility feed for exercising SalvageAuction's storm-scaled window.
contract MockVolatilityFeed is IVolatilityFeed {
    mapping(PoolId => uint256) public vol;

    function setVolatility(PoolId poolId, uint256 volBps) external {
        vol[poolId] = volBps;
    }

    function recentVolatility(PoolId poolId) external view returns (uint256) {
        return vol[poolId];
    }
}
