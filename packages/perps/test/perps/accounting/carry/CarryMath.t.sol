// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract CarryMathTest is Test {

    function test_ComputeCurrentCarryIndex_UsesOnlyAnnualRateAndElapsedTime() public pure {
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(0, 0, 365 days, 500), 0.05e18);
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 100 + 365 days, 500), 1.05e18);
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(0, 0, 365 days / 2, 1000), 0.05e18);
    }

    function test_ComputeIndexedCarry_FullYearAtFivePercent() public pure {
        uint256 carryIndexDelta = PositionRiskAccountingLib.computeCurrentCarryIndex(0, 0, 365 days, 500);
        assertEq(carryIndexDelta, 0.05e18);
        assertEq(PositionRiskAccountingLib.computeIndexedCarryAssets(100_000e6, carryIndexDelta), 5000e6);
        assertEq(PositionRiskAccountingLib.computeIndexedCarryAssets(0, carryIndexDelta), 0);
    }

    function test_ComputeCurrentCarryIndex_AccumulatesSimpleAnnualRate() public pure {
        uint256 index = PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 100 + 365 days, 500);
        assertEq(index, 1.05e18);
        assertEq(PositionRiskAccountingLib.computeIndexedCarryAssets(100_000e6, index - 1e18), 5000e6);
    }

    function test_ComputeCurrentCarryIndex_ZeroRateAndNonAdvancingTime() public pure {
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 100 + 365 days, 0), 1e18);
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 100, 500), 1e18);
        assertEq(PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 99, 500), 1e18);
    }

    function test_ComputeIndexedCarry_OneSecondRoundsToSettlementAtoms() public pure {
        uint256 index = PositionRiskAccountingLib.computeCurrentCarryIndex(0, 0, 1, 500);
        assertEq(PositionRiskAccountingLib.computeIndexedCarryAssets(10_000e6, index), 15);
        assertEq(PositionRiskAccountingLib.computeIndexedCarryAssets(120_000e6, index), 190);
    }

}
