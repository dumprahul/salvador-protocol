// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IConvoyBatch} from "./interfaces/IConvoyBatch.sol";

/// @title ConvoyBatch
/// @notice Groups retail-sized swaps into one uniform-price batch (Budish/Cramton/Shim frequent
/// batch auctions) so there is no ordering inside the batch to sandwich. Larger trades are left to
/// route through the salvage auction lane instead — see `classifyBySize`.
///
/// @dev Roadmap item 6 ("start with a trusted single-solver model before considering solver
/// decentralization") — this is that trusted-single-solver version.
///
/// @dev `_estimatePriceImpactBps` is flagged in the architecture doc (section 15) as needing "a
/// concrete implementation — likely reusing v4's own swap-simulation math". This implementation
/// reuses `SqrtPriceMath.getNextSqrtPriceFromInput` for a single-step (no tick-crossing) price-move
/// estimate. It intentionally does not walk tick crossings the way a full swap simulation would:
/// a trade large enough to cross several ticks already produces a large single-step price move,
/// so the classification bias from this shortcut is conservative (toward "not retail"), never the
/// dangerous direction.
contract ConvoyBatch is IConvoyBatch {
    using StateLibrary for IPoolManager;

    mapping(bytes32 => Order[]) public pendingBatch; // key: poolId + epoch
    mapping(PoolId => uint256) public currentEpoch;

    IPoolManager public immutable poolManager;
    address public immutable authorizedSolver;
    uint256 public constant PRICE_IMPACT_THRESHOLD_BPS = 100; // 1%, see classifyBySize

    constructor(IPoolManager _poolManager, address _authorizedSolver) {
        poolManager = _poolManager;
        authorizedSolver = _authorizedSolver;
    }

    /// @notice Queue a retail-sized order into the pending batch for `poolId`'s current epoch.
    /// Called by the protected RPC relay on the user's behalf, or directly by a user willing to
    /// accept batch-window latency.
    function submitToBatch(PoolId poolId, Order calldata order) external {
        if (!classifyBySize(poolId, order)) revert NotRetailSized();
        pendingBatch[_batchKey(poolId, currentEpoch[poolId])].push(order);
        emit OrderSubmitted(poolId, order.trader, order.amountIn, order.zeroForOne);
    }

    function classifyBySize(PoolId poolId, Order calldata order) public view returns (bool) {
        uint256 impactBps = _estimatePriceImpactBps(poolId, order.amountIn, order.zeroForOne);
        return impactBps <= PRICE_IMPACT_THRESHOLD_BPS;
    }

    function _estimatePriceImpactBps(PoolId poolId, uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (uint256 impactBps)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0 || sqrtPriceX96 == 0) return type(uint256).max;

        uint160 sqrtPriceNextX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, zeroForOne);

        uint256 diff = sqrtPriceX96 > sqrtPriceNextX96 ? sqrtPriceX96 - sqrtPriceNextX96 : sqrtPriceNextX96 - sqrtPriceX96;
        // sqrtPrice moves by ~half the price's relative move for small moves; scale to bps of price
        impactBps = (uint256(diff) * 2 * 10_000) / uint256(sqrtPriceX96);
    }

    function _batchKey(PoolId poolId, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, epoch));
    }
}
