// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    HousePoolWaterfallAccountingLib as Waterfall
} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract SeniorWithdrawalMathTest is Test {

    function testFuzz_HealthyWithdrawalKeepsAllRemainingPrincipalProtected(
        uint128 principal,
        uint128 requested
    ) public pure {
        uint256 assets = uint256(requested) % (uint256(principal) + 1);
        Waterfall.WaterfallState memory next =
            Waterfall.scaleSeniorOnWithdraw(Waterfall.WaterfallState(principal, 37, principal), assets);
        assertEq(next.seniorPrincipal, uint256(principal) - assets);
        assertEq(next.seniorHighWaterMark, next.seniorPrincipal);
        assertEq(next.juniorPrincipal, 37);
    }

    function testFuzz_ImpairedWithdrawalPreservesRecoveryRatio(
        uint120 principal,
        uint120 gap,
        uint120 requested
    ) public pure {
        uint256 p = uint256(principal) + 1;
        uint256 h = p + gap;
        uint256 assets = uint256(requested) % (p + 1);
        Waterfall.WaterfallState memory next =
            Waterfall.scaleSeniorOnWithdraw(Waterfall.WaterfallState(p, 37, h), assets);
        assertEq(next.seniorPrincipal, p - assets);
        assertEq(next.juniorPrincipal, 37);
        // Cross-products independently bound the remaining recovery ratio and its rounding error.
        assertGe(next.seniorHighWaterMark * p, h * next.seniorPrincipal);
        assertLt(next.seniorHighWaterMark * p - h * next.seniorPrincipal, p);
    }

    function test_ZeroFundingPreservesWipedOutRecoveryRights() public pure {
        Waterfall.WaterfallState memory next = Waterfall.scaleSeniorOnWithdraw(Waterfall.WaterfallState(0, 37, 100), 0);
        assertEq(next.seniorPrincipal, 0);
        assertEq(next.seniorHighWaterMark, 100);
        assertEq(next.juniorPrincipal, 37);
    }

    function test_PartialFundingRoundsProtectionUpAndFinalFundingClearsIt() public pure {
        Waterfall.WaterfallState memory next = Waterfall.scaleSeniorOnWithdraw(Waterfall.WaterfallState(7, 37, 10), 2);
        assertEq(next.seniorPrincipal, 5);
        assertEq(next.seniorHighWaterMark, 8);
        next = Waterfall.scaleSeniorOnWithdraw(next, 1);
        assertEq(next.seniorPrincipal, 4);
        assertEq(next.seniorHighWaterMark, 7);
        next = Waterfall.scaleSeniorOnWithdraw(next, 4);
        assertEq(next.seniorPrincipal, 0);
        assertEq(next.seniorHighWaterMark, 0);
        assertEq(next.juniorPrincipal, 37);
    }

    function test_FullPrecisionSupportsOverflowingIntermediateProduct() public pure {
        uint256 principal = type(uint256).max - 1;
        uint256 assets = principal / 2;
        Waterfall.WaterfallState memory next =
            Waterfall.scaleSeniorOnWithdraw(Waterfall.WaterfallState(principal, 37, type(uint256).max), assets);
        assertEq(next.seniorPrincipal, assets);
        assertEq(next.seniorHighWaterMark, assets + 1);
        assertEq(next.juniorPrincipal, 37);
    }

}
