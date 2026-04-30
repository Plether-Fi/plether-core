// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract CarryMathTest is Test {

    function test_ComputeLpBackedNotional_ZeroWhenMarginExceedsNotional() public pure {
        uint256 lpBackedNotionalUsdc = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 200_000e6);
        assertEq(lpBackedNotionalUsdc, 0);
    }

    function test_ComputeLpBackedNotional_GrowsWithLeverage() public pure {
        uint256 lowLeverageCarryBase = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 50_000e6);
        uint256 highLeverageCarryBase = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6);
        assertGt(highLeverageCarryBase, lowLeverageCarryBase);
        assertEq(lowLeverageCarryBase, 50_000e6);
        assertEq(highLeverageCarryBase, 90_000e6);
    }

    function test_ComputePendingCarry_ZeroAtZeroTime() public pure {
        uint256 carryUsdc = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 0
        );
        assertEq(carryUsdc, 0);
    }

    function test_ComputePendingCarry_GrowsLinearlyWithTime() public pure {
        uint256 oneDayCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 1 days
        );
        uint256 twoDayCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 2 days
        );
        assertEq(twoDayCarry, oneDayCarry * 2);
        assertGt(oneDayCarry, 0);
    }

    function test_ComputeLpBackedUtilization_CapsAtFullUtilization() public pure {
        assertEq(PositionRiskAccountingLib.computeLpBackedUtilizationBps(0, 0), 0);
        assertEq(PositionRiskAccountingLib.computeLpBackedUtilizationBps(50_000e6, 100_000e6), 5000);
        assertEq(PositionRiskAccountingLib.computeLpBackedUtilizationBps(150_000e6, 100_000e6), 10_000);
        assertEq(PositionRiskAccountingLib.computeLpBackedUtilizationBps(1, 0), 10_000);
    }

    function test_ComputeVariableCarryRate_UsesKinkedLpBackedUtilization() public pure {
        assertEq(PositionRiskAccountingLib.computeVariableCarryRateBps(200, 0, 7000, 300, 3000), 200);
        assertEq(PositionRiskAccountingLib.computeVariableCarryRateBps(200, 3500, 7000, 300, 3000), 350);
        assertEq(PositionRiskAccountingLib.computeVariableCarryRateBps(200, 7000, 7000, 300, 3000), 500);
        assertEq(PositionRiskAccountingLib.computeVariableCarryRateBps(200, 10_000, 7000, 300, 3000), 3500);
    }

    function test_ComputeVariablePendingCarry_PreservesFlatCarryWhenSlopesAreZero() public pure {
        CfdTypes.RiskParams memory params = _riskParams(500, 7000, 0, 0);
        uint256 carryBaseUsdc = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6);

        uint256 flatCarry = PositionRiskAccountingLib.computePendingCarryUsdc(carryBaseUsdc, 500, 7 days);
        uint256 variableCarry = PositionRiskAccountingLib.computePendingCarryUsdc(carryBaseUsdc, params, 9000, 7 days);

        assertEq(variableCarry, flatCarry);
    }

    function test_ComputeVariablePendingCarry_IncreasesWithLpBackedUtilization() public pure {
        CfdTypes.RiskParams memory params = _riskParams(200, 7000, 300, 3000);
        uint256 carryBaseUsdc = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6);

        uint256 lowUtilCarry = PositionRiskAccountingLib.computePendingCarryUsdc(carryBaseUsdc, params, 3500, 7 days);
        uint256 kinkCarry = PositionRiskAccountingLib.computePendingCarryUsdc(carryBaseUsdc, params, 7000, 7 days);
        uint256 fullUtilCarry = PositionRiskAccountingLib.computePendingCarryUsdc(carryBaseUsdc, params, 10_000, 7 days);

        assertGt(kinkCarry, lowUtilCarry);
        assertGt(fullUtilCarry, kinkCarry);
    }

    function _riskParams(
        uint256 baseCarryBps,
        uint256 carryKinkUtilizationBps,
        uint256 carrySlope1Bps,
        uint256 carrySlope2Bps
    ) private pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: baseCarryBps,
            carryKinkUtilizationBps: carryKinkUtilizationBps,
            carrySlope1Bps: carrySlope1Bps,
            carrySlope2Bps: carrySlope2Bps,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

}
