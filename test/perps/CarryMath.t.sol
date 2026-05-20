// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract CarryMathTest is Test {

    function test_ComputeBorrowBase_ZeroWhenMarginCoversMaxProfit() public pure {
        uint256 borrowBaseUsdc = PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 200_000e6);
        assertEq(borrowBaseUsdc, 0);
    }

    function test_ComputeBorrowBase_GrowsWithLeverage() public pure {
        uint256 lowLeverageCarryBase = PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 50_000e6);
        uint256 highLeverageCarryBase = PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 10_000e6);
        assertGt(highLeverageCarryBase, lowLeverageCarryBase);
        assertEq(lowLeverageCarryBase, 50_000e6);
        assertEq(highLeverageCarryBase, 90_000e6);
    }

    function test_ComputeUtilizedCarryRate_ScalesBySideUtilization() public pure {
        uint256 utilizationBps = PositionRiskAccountingLib.computeBorrowUtilizationBps(100_000e6, 200_000e6);
        uint256 utilizedRateBps = PositionRiskAccountingLib.computeUtilizedCarryRateBps(500, utilizationBps);
        assertEq(utilizationBps, 5000);
        assertEq(utilizedRateBps, 250);
    }

    function test_ComputeIndexedCarry_FullYearAtFivePercent() public pure {
        uint256 carryIndexDelta = PositionRiskAccountingLib.computeCarryIndexIncrement(500, 365 days);
        uint256 carryUsdc = PositionRiskAccountingLib.computeIndexedCarryUsdc(90_000e6, carryIndexDelta);
        assertEq(carryIndexDelta, 0.05e18);
        assertEq(carryUsdc, 4500e6);
    }

    function test_ComputeCurrentCarryIndex_UsesSinglePassUtilizationFormula() public pure {
        uint256 index =
            PositionRiskAccountingLib.computeCurrentCarryIndex(1e18, 100, 100 + 365 days, 100_000e6, 200_000e6, 500);
        assertEq(index, 1.025e18);
    }

}
