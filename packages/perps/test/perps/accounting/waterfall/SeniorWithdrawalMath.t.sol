// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    HousePoolWaterfallAccountingLib as Waterfall
} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract SeniorWithdrawalMathTest is Test {

    function test_ImpairedAtomWithdrawalPreservesShareOwnership() public pure {
        uint256 hwm = 600_009_221_390;
        uint256 supply = 600_000e9;
        uint256 fundedShares = supply * 5001 / 10_000;
        (uint256 nextPrincipal, uint256 nextHwm) = Waterfall.scaleSeniorOnWithdraw(3, hwm, 2, fundedShares, supply);
        assertEq(nextPrincipal, 1);
        assertEq(nextHwm, hwm - hwm * fundedShares / supply);
    }

    function testFuzz_HealthyWithdrawalKeepsAllRemainingPrincipalProtected(
        uint128 principal,
        uint128 requested
    ) public pure {
        uint256 assets = uint256(requested) % (uint256(principal) + 1);
        (uint256 nextPrincipal, uint256 nextHwm) =
            Waterfall.scaleSeniorOnWithdraw(principal, principal, assets, assets, principal);
        assertEq(nextPrincipal, uint256(principal) - assets);
        assertEq(nextHwm, nextPrincipal);
    }

    function testFuzz_ImpairedWithdrawalPreservesRecoveryAndShareOwnership(
        uint120 principal,
        uint120 gap,
        uint120 requested,
        uint120 supply,
        uint120 requestedShares
    ) public pure {
        uint256 p = uint256(principal) + 1;
        uint256 h = p + gap;
        uint256 assets = uint256(requested) % (p + 1);
        uint256 s = uint256(supply) + 1;
        uint256 shares = assets == 0 ? 0 : uint256(requestedShares) % s + 1;
        (uint256 nextPrincipal, uint256 nextHwm) = Waterfall.scaleSeniorOnWithdraw(p, h, assets, shares, s);
        assertEq(nextPrincipal, p - assets);
        assertLe(nextHwm, h);
        // Independent cross-products bound protection by both principal and real-share ownership.
        assertGe(nextHwm * p, h * nextPrincipal);
        uint256 principalRounding = nextHwm * p - h * nextPrincipal;
        if (h > p && assets > 0 && assets < p) {
            assertGe(nextHwm * s, h * (s - shares));
            uint256 shareRounding = nextHwm * s - h * (s - shares);
            assertTrue(principalRounding < p || shareRounding < s, "one protection bound must be tight");
        } else {
            assertLt(principalRounding, p);
        }
    }

    function test_ZeroFundingPreservesWipedOutRecoveryRights() public pure {
        (uint256 nextPrincipal, uint256 nextHwm) = Waterfall.scaleSeniorOnWithdraw(0, 100, 0, 0, 0);
        assertEq(nextPrincipal, 0);
        assertEq(nextHwm, 100);
    }

    function test_PartialFundingRoundsProtectionUpAndFinalFundingClearsIt() public pure {
        (uint256 nextPrincipal, uint256 nextHwm) = Waterfall.scaleSeniorOnWithdraw(7, 10, 2, 2, 7);
        assertEq(nextPrincipal, 5);
        assertEq(nextHwm, 8);
        (nextPrincipal, nextHwm) = Waterfall.scaleSeniorOnWithdraw(nextPrincipal, nextHwm, 1, 1, 5);
        assertEq(nextPrincipal, 4);
        assertEq(nextHwm, 7);
        (nextPrincipal, nextHwm) = Waterfall.scaleSeniorOnWithdraw(nextPrincipal, nextHwm, 4, 3, 4);
        assertEq(nextPrincipal, 0);
        assertEq(nextHwm, 0);
    }

    function test_FullPrecisionSupportsOverflowingIntermediateProduct() public pure {
        uint256 principal = type(uint256).max - 1;
        uint256 assets = principal / 2;
        (uint256 nextPrincipal, uint256 nextHwm) =
            Waterfall.scaleSeniorOnWithdraw(principal, type(uint256).max, assets, assets, principal);
        assertEq(nextPrincipal, assets);
        assertEq(nextHwm, assets + 1);
    }

    function test_ShareFloorSupportsOverflowingIntermediateProduct() public pure {
        uint256 hwm = type(uint256).max;
        uint256 supply = type(uint256).max - 1;
        uint256 shares = supply / 2;
        (uint256 nextPrincipal, uint256 nextHwm) = Waterfall.scaleSeniorOnWithdraw(3, hwm, 2, shares, supply);
        assertEq(nextPrincipal, 1);
        assertEq(nextHwm, hwm / 2 + 1);
    }

}
