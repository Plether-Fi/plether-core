// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CashPriorityLib} from "src/perps/libraries/CashPriorityLib.sol";

contract CashPriorityLibTest is Test {

    function test_ReserveFreshPayouts_ReservesAllDeferredSeniorClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveFreshPayouts(100e6, 30e6, 20e6);

        assertEq(reservation.totalSeniorClaimsUsdc, 50e6, "Total senior claims should sum deferred obligations");
        assertEq(reservation.reservedSeniorCashUsdc, 50e6, "Fresh payouts must reserve the full deferred queue");
        assertEq(reservation.freeCashUsdc, 50e6, "Fresh payouts may use cash above deferred claims");
        assertEq(
            reservation.deferredClaimServiceableUsdc, 0, "Fresh payout reservations do not service deferred claims"
        );
    }

    function test_ReserveDeferredClaim_FreezesWhenPhysicalCashFallsBelowAggregateDeferredClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 30e6, 20e6, 30e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            0,
            "Deferred claim service should freeze while aggregate deferred liabilities exceed physical cash"
        );
    }

    function test_ReserveDeferredClaim_RemainsFrozenDuringShortfallEvenIfCurrentClaimCouldBeCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 60e6, 10e6, 60e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            0,
            "Deferred beneficiary claim should remain frozen until aggregate deferred liabilities are fully covered"
        );
        assertEq(reservation.freeCashUsdc, 0, "No fresh cash remains above total deferred claims");
    }

    function test_ReserveDeferredClaim_ClaimsFullAmountWhenAggregateDeferredLiabilitiesAreFullyCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(20e6, 20e6, 0, 20e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            20e6,
            "Deferred claims should be fully serviceable once aggregate deferred liabilities are fully covered"
        );
    }

    function test_ReserveDeferredClaim_ClaimsFullAmountWhenOnlyClaimantRemains() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 30e6, 0, 30e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            30e6,
            "Deferred beneficiary should claim fully when physical cash covers the deferred queue"
        );
    }

}
