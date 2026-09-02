// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ManifestLib
/// @notice Internal library (storage lives inside SalvageHook, per the architecture doc's explicit
/// decision to avoid a second CALL on every swap). Tracks per-LP tick-range exposure so a later
/// loss event can be attributed to exactly the positions the price path actually crossed.
library ManifestLib {
    struct Position {
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Storage {
        mapping(bytes32 => Position) positions; // key: keccak(lp, tickLower, tickUpper)
    }

    error LiquidityUnderflow();

    function positionKey(address lp, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encode(lp, tickLower, tickUpper));
    }

    /// @notice Apply a signed liquidity delta to `lp`'s [tickLower, tickUpper] position (mint =
    /// positive, burn = negative).
    function recordPosition(Storage storage self, address lp, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
    {
        bytes32 key = positionKey(lp, tickLower, tickUpper);
        Position storage p = self.positions[key];

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
    }

    function getPosition(Storage storage self, address lp, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Position memory)
    {
        return self.positions[positionKey(lp, tickLower, tickUpper)];
    }
}
