// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LossMeterLib} from "../src/libraries/LossMeterLib.sol";
import {ManifestLib} from "../src/libraries/ManifestLib.sol";

/// @notice Exercises LossMeterLib.accrue against the whitepaper's worked proportional-payout logic
/// (section VIII's seven-block timeline), adapted to this implementation's direct per-position
/// accrual (see the deviation note on LossMeterLib.Storage for why the doc's flat
/// lossGrowthGlobal-only checkpoint scheme is not, by itself, correct under partial overlaps).
contract LossMeterLibHarness {
    using LossMeterLib for LossMeterLib.Storage;

    LossMeterLib.Storage internal lossMeter;

    function accrue(ManifestLib.Exposure[] memory hit, uint256 totalLoss) external {
        lossMeter.accrue(hit, totalLoss);
    }

    function getClaimable(bytes32 posKey) external view returns (uint256) {
        return lossMeter.getClaimable(posKey);
    }

    function checkpoint(bytes32 posKey, uint256 paid) external {
        lossMeter.checkpoint(posKey, paid);
    }
}

contract LossMeterLibTest is Test {
    LossMeterLibHarness internal harness;

    bytes32 internal constant KEY_X = keccak256("LP_X");
    bytes32 internal constant KEY_Y = keccak256("LP_Y");

    function setUp() public {
        harness = new LossMeterLibHarness();
    }

    /// @notice Whitepaper section VIII: LP_X alone (100,000 liquidity) absorbs a $9.20 loss event,
    /// then LP_Y joins (50,000 liquidity) and a second $2.50 loss event is split 100k:50k.
    /// LP_X's total = 9.20 + 2.50 * (100/150); LP_Y's total = 2.50 * (50/150).
    function test_sevenBlockTimeline_directAccrual() public {
        ManifestLib.Exposure[] memory onlyX = new ManifestLib.Exposure[](1);
        onlyX[0] = ManifestLib.Exposure({key: KEY_X, lp: address(0), tickLower: 0, tickUpper: 0, liquidity: 100_000});
        harness.accrue(onlyX, 9.2e18);

        ManifestLib.Exposure[] memory both = new ManifestLib.Exposure[](2);
        both[0] = ManifestLib.Exposure({key: KEY_X, lp: address(0), tickLower: 0, tickUpper: 0, liquidity: 100_000});
        both[1] = ManifestLib.Exposure({key: KEY_Y, lp: address(0), tickLower: 0, tickUpper: 0, liquidity: 50_000});
        harness.accrue(both, 2.5e18);

        uint256 claimableX = harness.getClaimable(KEY_X);
        uint256 claimableY = harness.getClaimable(KEY_Y);

        // 9.20 + 2.50 * (100_000/150_000) = 9.20 + 1.6666... ~= 10.8666...
        assertApproxEqAbs(claimableX, 10.8666e18, 0.001e18);
        // 2.50 * (50_000/150_000) = 0.8333...
        assertApproxEqAbs(claimableY, 0.8333e18, 0.001e18);

        // exact split sums to the total distributed (no dust lost, per the last-index rounding fixup)
        assertEq(claimableX + claimableY, 9.2e18 + 2.5e18);
    }
}
