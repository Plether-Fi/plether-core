// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CashPriorityLib} from "src/perps/libraries/CashPriorityLib.sol";

contract CashPriorityLibTest is Test {

    function test_ReserveFreshPayouts_ReservesAllTraderClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveFreshPayouts(100e6, 50e6);

        assertEq(reservation.totalSeniorClaimsUsdc, 50e6, "Total senior claims should sum trader claim obligations");
        assertEq(reservation.reservedSeniorCashUsdc, 50e6, "Fresh payouts must reserve all trader claims");
        assertEq(reservation.freeCashUsdc, 50e6, "Fresh payouts may use cash above trader claims");
        assertEq(reservation.claimServiceableUsdc, 0, "Fresh payout reservations do not service trader claims");
    }

    function test_ReserveTraderClaimService_FreezesWhenPhysicalCashFallsBelowAggregateClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveClaimService(40e6, 50e6, 30e6);

        assertEq(
            reservation.claimServiceableUsdc,
            0,
            "Trader claim service should freeze while aggregate trader claim liabilities exceed physical cash"
        );
    }

    function test_ReserveTraderClaimService_RemainsFrozenDuringShortfallEvenIfCurrentClaimCouldBeCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveClaimService(40e6, 60e6, 60e6);

        assertEq(
            reservation.claimServiceableUsdc,
            0,
            "Trader claim should remain frozen until aggregate trader claim liabilities are fully covered"
        );
        assertEq(reservation.freeCashUsdc, 0, "No fresh cash remains above total trader claims");
    }

    function test_ReserveTraderClaimService_ServicesFullAmountWhenAggregateClaimsAreFullyCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveClaimService(20e6, 20e6, 20e6);

        assertEq(
            reservation.claimServiceableUsdc,
            20e6,
            "Trader claims should be fully serviceable once aggregate trader claim liabilities are fully covered"
        );
    }

    function test_ReserveTraderClaimService_ServicesFullAmountWhenOnlyClaimantRemains() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveClaimService(40e6, 30e6, 30e6);

        assertEq(
            reservation.claimServiceableUsdc,
            30e6,
            "Trader claimant should settle fully when physical cash covers the claim balance"
        );
    }

}
