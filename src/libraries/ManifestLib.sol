// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ManifestLib
/// @notice Internal library (storage lives inside SalvageHook, per the architecture doc's explicit
/// decision to avoid a second CALL on every swap). Tracks per-LP tick-range exposure so a later
/// loss event can be attributed to exactly the positions the price path actually crossed.
///
/// @dev Position keys are also tracked in an array so `getExposedRanges` can enumerate them — a
/// bare `mapping` cannot be iterated. Positions are swap-removed from the array once their
/// liquidity returns to zero, so the array only grows with the pool's live position count, not
/// with lifetime deposit/withdraw activity.
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
        mapping(address => bytes32[]) positionKeysByLp; // lp => every key it has ever touched (may include zero-liquidity ranges it re-enters later)
    }

    struct Exposure {
        bytes32 key;
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
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
            self.positionKeysByLp[lp].push(key);
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

    /// @notice Every live position whose [tickLower, tickUpper] range overlaps any part of the
    /// range the price path crossed this swap. `tickA`/`tickB` may be given in either order.
    ///
    /// @dev This is a direct, exact overlap scan over the pool's live positions rather than a
    /// TickBitmap-style walk — SALVAGE's manifest indexes positions by LP, not by the pool's own
    /// initialized-tick bitmap (which lives in PoolManager, external state this library
    /// deliberately does not call out to). Cost is O(live positions in the pool), not O(ticks
    /// crossed); see the worked LP1/LP2/LP3 partial-overlap fixture in the test suite for why a
    /// coarser per-tick shortcut would misattribute loss across overlapping ranges.
    function getExposedRanges(Storage storage self, int24 tickA, int24 tickB)
        internal
        view
        returns (Exposure[] memory)
    {
        (int24 lo, int24 hi) = tickA <= tickB ? (tickA, tickB) : (tickB, tickA);

        uint256 n = self.positionKeys.length;
        Exposure[] memory hits = new Exposure[](n);
        uint256 count;

        for (uint256 i = 0; i < n; i++) {
            bytes32 key = self.positionKeys[i];
            Position storage p = self.positions[key];
            // overlap test: ranges [tickLower, tickUpper) and [lo, hi] intersect
            if (p.tickLower < hi && p.tickUpper > lo) {
                hits[count] = Exposure({
                    key: key, lp: p.lp, tickLower: p.tickLower, tickUpper: p.tickUpper, liquidity: p.liquidity
                });
                count++;
            }
        }

        // trim to actual hit count
        assembly {
            mstore(hits, count)
        }
        return hits;
    }

    function getPosition(Storage storage self, address lp, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Position memory)
    {
        return self.positions[positionKey(lp, tickLower, tickUpper)];
    }

    /// @notice Every position key `lp` has ever opened (including ranges currently at zero
    /// liquidity, since a claimable loss balance can still be outstanding against them).
    function positionsOf(Storage storage self, address lp) internal view returns (bytes32[] memory) {
        return self.positionKeysByLp[lp];
    }
}
