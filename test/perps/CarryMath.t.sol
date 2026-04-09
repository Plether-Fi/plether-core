// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

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
        uint256 carryUsdc = PositionRiskAccountingLib.computePendingCarryUsdc(PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 0);
        assertEq(carryUsdc, 0);
    }

    function test_ComputePendingCarry_GrowsLinearlyWithTime() public pure {
        uint256 oneDayCarry = PositionRiskAccountingLib.computePendingCarryUsdc(PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 1 days);
        uint256 twoDayCarry = PositionRiskAccountingLib.computePendingCarryUsdc(PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 2 days);
        assertEq(twoDayCarry, oneDayCarry * 2);
        assertGt(oneDayCarry, 0);
    }

}
