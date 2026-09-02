// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";

/// @notice Minimal PoolManager caller that IS the swap's `sender` as v4 hooks see it — a real v4
/// router (like PoolSwapTest) calls `manager.swap()` from its own address, so a router-mediated
/// swap can never satisfy SalvageHook's `sender == winner` check for a specific bidder EOA/contract.
/// This contract stands in for "the winning bidder calling PoolManager directly", settling its own
/// deltas out of whatever balance it's been funded with.
contract Bidder {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function doSwap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(CallbackData(key, params)));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, "");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) CurrencySettler.settle(data.key.currency0, manager, address(this), uint256(uint128(-d0)), false);
        if (d1 < 0) CurrencySettler.settle(data.key.currency1, manager, address(this), uint256(uint128(-d1)), false);
        if (d0 > 0) CurrencySettler.take(data.key.currency0, manager, address(this), uint256(uint128(d0)), false);
        if (d1 > 0) CurrencySettler.take(data.key.currency1, manager, address(this), uint256(uint128(d1)), false);

        return abi.encode(delta);
    }
}
