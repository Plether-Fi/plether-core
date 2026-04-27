// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CashPriorityLib} from "src/perps/libraries/CashPriorityLib.sol";

contract CashPriorityLibTest is Test {

    function test_ReserveFreshPayouts_ReservesAllClaimBalances() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveFreshPayouts(100e6, 10e6, 30e6, 20e6);

        assertEq(reservation.totalSeniorClaimsUsdc, 50e6, "Total senior claims should sum claim obligations");
        assertEq(reservation.reservedSeniorCashUsdc, 50e6, "Fresh payouts must reserve the full claim balances");
        assertEq(reservation.protocolFeeWithdrawalUsdc, 10e6, "Protocol fees remain withdrawable after senior claims");
        assertEq(
            reservation.freeCashUsdc, 40e6, "Fresh payouts may only use cash above claim balances and protocol fees"
        );
        assertEq(reservation.claimServiceableUsdc, 0, "Fresh payout reservations do not service claim balances");
    }

    function test_ReserveClaimService_FreezesWhenPhysicalCashFallsBelowAggregateClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveClaimService(40e6, 20e6, 30e6, 20e6, 30e6);

        assertEq(
            reservation.claimServiceableUsdc,
            0,
            "claim balance service should freeze while aggregate non-spendable claim liabilities exceed physical cash"
        );
    }

    function test_ReserveClaimService_RemainsFrozenDuringShortfallEvenIfCurrentClaimCouldBeCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveClaimService(40e6, 20e6, 60e6, 10e6, 60e6);

        assertEq(
            reservation.claimServiceableUsdc,
            0,
            "claim beneficiary balance should remain frozen until aggregate non-spendable claim liabilities are fully covered"
        );
        assertEq(
            reservation.protocolFeeWithdrawalUsdc,
            0,
            "Protocol fees should remain non-withdrawable while senior claims exhaust liquidity"
        );
        assertEq(reservation.freeCashUsdc, 0, "No fresh cash remains above total claim balances and fees");
    }

    function test_ReserveClaimService_ClaimsFullAmountWhenAggregateClaimLiabilitiesAreFullyCovered() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveClaimService(20e6, 20e6, 20e6, 0, 20e6);

        assertEq(
            reservation.protocolFeeWithdrawalUsdc,
            0,
            "No fee cash should remain once claim balances fully reserve the available cash"
        );
        assertEq(
            reservation.claimServiceableUsdc,
            20e6,
            "claim balances should be fully serviceable once aggregate non-spendable claim liabilities are fully covered"
        );
    }

    function test_ReserveClaimService_ClaimsFullAmountWhenOnlyClaimantRemains() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveClaimService(40e6, 10e6, 30e6, 0, 30e6);

        assertEq(
            reservation.claimServiceableUsdc,
            30e6,
            "claim beneficiary should be fully serviceable when physical cash covers fees and no other claim balances exist"
        );
    }

    function test_CanWithdrawProtocolFees_OnlyUsesCashAboveClaims() public pure {
        assertTrue(CashPriorityLib.canWithdrawProtocolFees(100e6, 20e6, 30e6, 10e6, 20e6));
        assertFalse(CashPriorityLib.canWithdrawProtocolFees(40e6, 20e6, 30e6, 10e6, 20e6));
    }

}
