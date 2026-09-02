// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IConvoyBatch} from "./interfaces/IConvoyBatch.sol";

/// @title ConvoyBatch
/// @notice Groups retail-sized swaps into one uniform-price batch (Budish/Cramton/Shim frequent
/// batch auctions) so there is no ordering inside the batch to sandwich. Larger trades are left to
/// route through the salvage auction lane instead — see `classifyBySize`.
///
/// @dev Roadmap item 6 ("start with a trusted single-solver model before considering solver
/// decentralization") — this is that trusted-single-solver version.
contract ConvoyBatch is IConvoyBatch {
    mapping(bytes32 => Order[]) public pendingBatch; // key: poolId + epoch
    mapping(PoolId => uint256) public currentEpoch;

    IPoolManager public immutable poolManager;
    address public immutable authorizedSolver;

    constructor(IPoolManager _poolManager, address _authorizedSolver) {
        poolManager = _poolManager;
        authorizedSolver = _authorizedSolver;
    }

    /// @notice Queue a retail-sized order into the pending batch for `poolId`'s current epoch.
    /// Called by the protected RPC relay on the user's behalf, or directly by a user willing to
    /// accept batch-window latency.
    function submitToBatch(PoolId poolId, Order calldata order) external {
        pendingBatch[_batchKey(poolId, currentEpoch[poolId])].push(order);
        emit OrderSubmitted(poolId, order.trader, order.amountIn, order.zeroForOne);
    }

    function _batchKey(PoolId poolId, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, epoch));
    }
}
