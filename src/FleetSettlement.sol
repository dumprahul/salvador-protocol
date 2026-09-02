// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IFleetSettlement} from "./interfaces/IFleetSettlement.sol";
import {ISalvageHook} from "./interfaces/ISalvageHook.sol";
import {IGeneralAverageFund} from "./interfaces/IGeneralAverageFund.sol";

/// @title FleetSettlement
/// @notice UPCOMING per the whitepaper (section IX) and explicitly "build last, budget the most
/// audit time here" per the architecture doc's build order — the shared settlement layer across
/// multiple already-trustworthy pool hooks, the highest-risk new surface in the whole system.
///
/// Bundles salvage corrections across correlated pools into one bid, splitting it across each
/// pool's general average fund strictly in proportion to that pool's own, independently measured
/// gap (`ISalvageHook.lastMeasuredGap`) — never a caller-supplied split, so no pool's hook has to
/// trust the bidder's claim about how to divide it.
contract FleetSettlement is IFleetSettlement {
    mapping(PoolId => address) public hookFor;
    mapping(PoolId => address) public fundFor;
    address public immutable owner;

    error NotOwner();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error NoMeasuredGap();
    error EmptyBundle();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function registerPool(PoolId poolId, address hook_, address fund_) external onlyOwner {
        if (hookFor[poolId] != address(0)) revert PoolAlreadyRegistered();
        hookFor[poolId] = hook_;
        fundFor[poolId] = fund_;
    }
}
