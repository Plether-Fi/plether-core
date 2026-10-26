// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";

contract CashPriorityLibTest is Test {

    function test_ReserveFreshPayouts_ReservesAllTraderClaims() public pure {
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveFreshPayouts(100e6, 50e6);

        assertEq(reservation.totalSeniorClaimsAssets, 50e6, "Total senior claims should sum trader claim obligations");
        assertEq(reservation.reservedSeniorCashAssets, 50e6, "Fresh payouts must reserve all trader claims");
        assertEq(reservation.freeCashAssets, 50e6, "Fresh payouts may use cash above trader claims");
    }

}
