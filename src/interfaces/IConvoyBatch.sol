// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IConvoyBatch {
    struct Order {
        address trader;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    event OrderSubmitted(PoolId indexed poolId, address indexed trader, uint256 amountIn, bool zeroForOne);
    event BatchSettled(PoolId indexed poolId, uint256 clearingPriceX96, uint256 ordersFilled);

    error UnauthorizedSolver();
    error NotRetailSized();

    /// @notice Queue a retail-sized order into the pending batch for `poolId`'s current epoch.
    function submitToBatch(PoolId poolId, Order calldata order) external;

    /// @notice Whether `order` qualifies as retail-sized (price impact under threshold) for `poolId`.
    function classifyBySize(PoolId poolId, Order calldata order) external view returns (bool);

    /// @notice Settle the pending batch for `poolId` at one uniform clearing price. Callable only
    /// by the authorized solver.
    function settleBatch(PoolId poolId, uint256 clearingPriceX96, bytes calldata solverProof) external;
}
