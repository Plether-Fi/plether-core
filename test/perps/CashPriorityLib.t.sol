// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CashPriorityLib} from "src/perps/libraries/CashPriorityLib.sol";

contract CashPriorityLibTest is Test {

    function test_ReserveFreshPayouts_ReservesAllDeferredSeniorClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveFreshPayouts(100e6, 10e6, 30e6, 20e6);

        assertEq(reservation.totalSeniorClaimsUsdc, 50e6, "Total senior claims should sum deferred obligations");
        assertEq(reservation.reservedSeniorCashUsdc, 50e6, "Fresh payouts must reserve the full deferred queue");
        assertEq(reservation.protocolFeeWithdrawalUsdc, 10e6, "Protocol fees remain withdrawable after senior claims");
        assertEq(
            reservation.freeCashUsdc, 40e6, "Fresh payouts may only use cash above deferred claims and protocol fees"
        );
        assertEq(reservation.headClaimServiceableUsdc, 0, "Fresh payout reservations do not service deferred claims");
    }

    function test_ReserveDeferredHeadClaim_PrioritizesHeadOverLaterClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredHeadClaim(40e6, 10e6, 70e6, 30e6, 70e6);

        assertEq(reservation.totalSeniorClaimsUsdc, 100e6, "Total senior claims should include both deferred classes");
        assertEq(
            reservation.reservedSeniorCashUsdc, 100e6, "Fresh reservation accounting should still see all senior claims"
        );
        assertEq(reservation.freeCashUsdc, 0, "No fresh cash should remain while senior claims exceed physical cash");
        assertEq(
            reservation.headClaimServiceableUsdc,
            30e6,
            "Head claims may only use cash left after reserving protocol fees"
        );
    }

    function test_CanWithdrawProtocolFees_OnlyUsesCashAboveDeferredClaims() public pure {
        assertTrue(CashPriorityLib.canWithdrawProtocolFees(100e6, 20e6, 30e6, 10e6, 20e6));
        assertFalse(CashPriorityLib.canWithdrawProtocolFees(40e6, 20e6, 30e6, 10e6, 20e6));
    }

}
