// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IConvoyBatch {
    /// @dev `trader` must have approved `ConvoyBatch` itself for at least `amountIn` of the input
    /// currency before the batch containing this order is settled — settlement's `transferFrom`
    /// call is made by `ConvoyBatch`, exactly as a stock v4 router pulls from a user who approved
    /// the router (see `ConvoyBatch._pay`), not from anyone who approved `PoolManager` directly.
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
    error NotOwner();
    error NotPoolManager();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error MinOutNotMet();

    /// @notice One-time binding of `poolId`'s full `PoolKey`, needed to call `PoolManager.swap`
    /// directly during batch settlement. Callable only by the deployer-owner, once per pool.
    function registerPool(PoolId poolId, PoolKey calldata key) external;

    /// @notice Queue a retail-sized order into the pending batch for `poolId`'s current epoch.
    function submitToBatch(PoolId poolId, Order calldata order) external;

    /// @notice Whether `order` qualifies as retail-sized (price impact under threshold) for `poolId`.
    function classifyBySize(PoolId poolId, Order calldata order) external view returns (bool);

    /// @notice Settle the pending batch for `poolId` at one uniform clearing price: executes every
    /// queued order against the real pool itself (`sender == address(this)`, which `SalvageHook`
    /// waves through), each one price-protected by `clearingPriceX96` and its own `minOut`.
    /// Callable only by the authorized solver.
    function settleBatch(PoolId poolId, uint256 clearingPriceX96, bytes calldata solverProof) external;
}
