// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ManifestLib} from "../src/libraries/ManifestLib.sol";

/// @notice Exercises ManifestLib.getExposedRanges against the architecture doc's named
/// LP1/LP2/LP3 partial-overlap fixture (section 4's "worth the most test-writing time in the
/// entire manifest" note). A price move that crosses ticks [0, 300] must correctly identify every
/// position whose range overlaps any part of that stretch, including partial overlaps at either
/// end — a coarse "which single tick did the trade land on" check would miss LP1 and LP3 entirely.
contract ManifestLibHarness {
    using ManifestLib for ManifestLib.Storage;

    ManifestLib.Storage internal manifest;

    function recordPosition(address lp, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        manifest.recordPosition(lp, tickLower, tickUpper, liquidityDelta);
    }

    function getExposedRanges(int24 tickA, int24 tickB) external view returns (ManifestLib.Exposure[] memory) {
        return manifest.getExposedRanges(tickA, tickB);
    }

    function positionsOf(address lp) external view returns (bytes32[] memory) {
        return manifest.positionsOf(lp);
    }

    function liquidityOf(address lp, int24 tickLower, int24 tickUpper) external view returns (uint128) {
        return manifest.getPosition(lp, tickLower, tickUpper).liquidity;
    }
}

contract ManifestLibTest is Test {
    ManifestLibHarness internal harness;

    address internal constant LP1 = address(0x1111);
    address internal constant LP2 = address(0x2222);
    address internal constant LP3 = address(0x3333);
    address internal constant LP_UNTOUCHED = address(0x4444);

    function setUp() public {
        harness = new ManifestLibHarness();
    }

    /// @notice The named fixture: LP1 covers [-100, 100] (overlaps only the start of the crossed
    /// range), LP2 covers [50, 250] (fully inside the crossed range), LP3 covers [200, 400]
    /// (overlaps only the end). A swap crossing ticks [0, 300] must hit all three, and must not hit
    /// an LP whose range sits entirely outside the crossed stretch.
    function test_LP1LP2LP3_partialOverlap() public {
        harness.recordPosition(LP1, -100, 100, 1_000e18);
        harness.recordPosition(LP2, 50, 250, 2_000e18);
        harness.recordPosition(LP3, 200, 400, 3_000e18);
        harness.recordPosition(LP_UNTOUCHED, 500, 600, 4_000e18); // entirely outside [0, 300]

        ManifestLib.Exposure[] memory hits = harness.getExposedRanges(0, 300);

        assertEq(hits.length, 3, "expected exactly LP1, LP2, LP3 to be hit");

        bool sawLp1;
        bool sawLp2;
        bool sawLp3;
        for (uint256 i = 0; i < hits.length; i++) {
            if (hits[i].lp == LP1) {
                sawLp1 = true;
                assertEq(hits[i].liquidity, 1_000e18);
            } else if (hits[i].lp == LP2) {
                sawLp2 = true;
                assertEq(hits[i].liquidity, 2_000e18);
            } else if (hits[i].lp == LP3) {
                sawLp3 = true;
                assertEq(hits[i].liquidity, 3_000e18);
            } else {
                fail();
            }
        }
        assertTrue(sawLp1 && sawLp2 && sawLp3, "all three overlapping LPs must be identified");
    }

    /// @notice tickA/tickB may arrive in either order (the hook derives them from
    /// sqrtPriceBefore/sqrtPriceAfter, whose relative order depends on swap direction).
    function test_orderIndependent() public {
        harness.recordPosition(LP1, -100, 100, 1_000e18);

        ManifestLib.Exposure[] memory forward = harness.getExposedRanges(0, 300);
        ManifestLib.Exposure[] memory reverse = harness.getExposedRanges(300, 0);

        assertEq(forward.length, 1);
        assertEq(reverse.length, 1);
        assertEq(forward[0].lp, reverse[0].lp);
    }

    /// @notice A range entirely outside the crossed stretch is never returned.
    function test_excludesNonOverlapping() public {
        harness.recordPosition(LP_UNTOUCHED, 500, 600, 4_000e18);
        ManifestLib.Exposure[] memory hits = harness.getExposedRanges(0, 300);
        assertEq(hits.length, 0);
    }
}
