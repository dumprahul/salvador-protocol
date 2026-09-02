// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ManifestLib
/// @notice Internal library (storage lives inside SalvageHook, per the architecture doc's explicit
/// decision to avoid a second CALL on every swap). Tracks per-LP tick-range exposure so a later
/// loss event can be attributed to exactly the positions the price path actually crossed.
///
/// @dev Position keys are also tracked in an array so they can later be enumerated — a bare
/// `mapping` cannot be iterated. Positions are swap-removed from the array once their liquidity
/// returns to zero, so the array only grows with the pool's live position count, not with
/// lifetime deposit/withdraw activity.
library ManifestLib {
    struct Position {
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Storage {
        mapping(bytes32 => Position) positions; // key: keccak(lp, tickLower, tickUpper)
        mapping(bytes32 => uint256) positionIndex; // key => index in positionKeys (1-based; 0 = absent)
        bytes32[] positionKeys; // enumerable set of live (liquidity > 0) position keys
    }

    error LiquidityUnderflow();

    function positionKey(address lp, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encode(lp, tickLower, tickUpper));
    }

    /// @notice Apply a signed liquidity delta to `lp`'s [tickLower, tickUpper] position (mint =
    /// positive, burn = negative), keeping the enumerable position set in sync.
    function recordPosition(Storage storage self, address lp, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
    {
        bytes32 key = positionKey(lp, tickLower, tickUpper);
        Position storage p = self.positions[key];

        bool wasLive = p.liquidity > 0;

        if (p.lp == address(0)) {
            p.lp = lp;
            p.tickLower = tickLower;
            p.tickUpper = tickUpper;
        }

        if (liquidityDelta >= 0) {
            p.liquidity = p.liquidity + uint128(uint256(liquidityDelta));
        } else {
            uint128 removed = uint128(uint256(-liquidityDelta));
            if (removed > p.liquidity) revert LiquidityUnderflow();
            p.liquidity = p.liquidity - removed;
        }

        bool isLive = p.liquidity > 0;

        if (isLive && !wasLive) {
            self.positionKeys.push(key);
            self.positionIndex[key] = self.positionKeys.length; // 1-based
        } else if (!isLive && wasLive) {
            _removeKey(self, key);
        }
    }

    function _removeKey(Storage storage self, bytes32 key) private {
        uint256 idx1 = self.positionIndex[key]; // 1-based
        if (idx1 == 0) return;

        uint256 lastIdx1 = self.positionKeys.length;
        if (idx1 != lastIdx1) {
            bytes32 lastKey = self.positionKeys[lastIdx1 - 1];
            self.positionKeys[idx1 - 1] = lastKey;
            self.positionIndex[lastKey] = idx1;
        }
        self.positionKeys.pop();
        delete self.positionIndex[key];
    }

    function getPosition(Storage storage self, address lp, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Position memory)
    {
        return self.positions[positionKey(lp, tickLower, tickUpper)];
    }
}
