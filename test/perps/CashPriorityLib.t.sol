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
        assertEq(
            reservation.deferredClaimServiceableUsdc, 0, "Fresh payout reservations do not service deferred claims"
        );
    }

    function test_ReserveDeferredClaim_PreservesFeesAndOtherDeferredClaimsUnderShortfall() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 20e6, 30e6, 20e6, 30e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            0,
            "Deferred claim service should preserve protocol fees and other deferred beneficiaries under shortfall"
        );
    }

    function test_ReserveDeferredClaim_UsesOnlyResidualCashAfterFeesAndOtherClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 20e6, 60e6, 10e6, 60e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            10e6,
            "Deferred beneficiary claim should use only cash left after preserving fees and other deferred claims"
        );
        assertEq(reservation.protocolFeeWithdrawalUsdc, 0, "Protocol fees should remain non-withdrawable while senior claims exhaust liquidity");
        assertEq(reservation.freeCashUsdc, 0, "No fresh cash remains above total deferred claims and fees");
    }

    function test_ReserveDeferredClaim_ClaimsFullAmountWhenOnlyClaimantRemains() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveDeferredClaim(40e6, 10e6, 30e6, 0, 30e6);

        assertEq(
            reservation.deferredClaimServiceableUsdc,
            30e6,
            "Deferred beneficiary should claim fully when physical cash covers fees and no other deferred claims exist"
        );
    }

    function test_CanWithdrawProtocolFees_OnlyUsesCashAboveDeferredClaims() public pure {
        assertTrue(CashPriorityLib.canWithdrawProtocolFees(100e6, 20e6, 30e6, 10e6, 20e6));
        assertFalse(CashPriorityLib.canWithdrawProtocolFees(40e6, 20e6, 30e6, 10e6, 20e6));
    }

}
