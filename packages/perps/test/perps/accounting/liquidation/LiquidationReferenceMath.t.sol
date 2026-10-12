// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LiquidationReferenceMath} from "../../invariant/ghost/LiquidationReferenceMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Literal liquidation vectors checked in USDC atoms independently of production accounting.
/// @dev Inputs start after direct carry collection. A lot is 100 tokens, so lots times an eight-decimal
/// price is a six-decimal USDC amount. No execution fixture, production helper, or Python runtime is required.
contract LiquidationReferenceMathTest is Test {

    function test_ClaimFirstLossLeavesOldClaimAndPledgeIntact() public pure {
        LiquidationReferenceMath.Input memory x = _short();
        x.basis = 12_000e6;
        x.price = 119_000_000;
        x.pledge = 20e6;
        x.free = 10e6;
        x.cash = 45e6;
        x.claim = 150e6;
        x.allClaims = 200e6;
        x.poolCash = 500e6;
        x.liquidationReserve = 12e6;
        x.unpaidCarry = 0;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertTrue(v.eligible);
        assertEq(v.pnl, -int256(100e6));
        assertEq(v.equity, int256(70e6));
        assertEq(v.maintenance, 119e6);
        assertEq(v.claimConsumed, 100e6);
        assertEq(v.pledgeConsumed, 0);
        assertEq(v.writtenOff, 0);
        assertEq(v.remainingClaim, 50e6);
        assertEq(v.charge, 11_900_000);
        assertEq(v.keeper, 5_950_000);
        assertEq(v.lpFee, 5_950_000);
        assertEq(v.retainedCash, 33_100_000);
        assertEq(v.poolCashAfter, 505_950_000);
        assertEq(v.allClaimsAfter, 100e6);
        _assertConservation(x, v);
    }

    function test_ExhaustedClaimAndPledgeWriteOffOnlyUncollectiblePriceLoss() public pure {
        LiquidationReferenceMath.Input memory x = _short();
        x.basis = 12_000e6;
        x.price = 60_000_001;
        x.pledge = 75e6;
        x.free = 11e6;
        x.cash = 100e6;
        x.claim = 125e6;
        x.allClaims = 300e6;
        x.poolCash = 1000e6;
        x.liquidationReserve = 12e6;
        x.unpaidCarry = 0;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.pnl, -int256(5_999_999_900));
        assertEq(v.equity, -int256(5_799_999_900));
        assertEq(v.maintenance, 60_000_001);
        assertEq(v.claimConsumed, 125e6);
        assertEq(v.pledgeConsumed, 75e6);
        assertEq(v.writtenOff, 5_799_999_900);
        assertEq(v.charge, 6e6);
        assertEq(v.keeper, 3e6);
        assertEq(v.lpFee, 3e6);
        assertEq(v.remainingClaim, 0);
        assertEq(v.retainedCash, 19e6);
        assertEq(v.poolCashAfter, 1078e6);
        assertEq(v.allClaimsAfter, 175e6);
        _assertConservation(x, v);
    }

    function test_BothSidesNonDollarGainWithholdsCarryAndPreservesOldClaims() public pure {
        for (uint256 side; side < 2; ++side) {
            LiquidationReferenceMath.Input memory x = side == 0 ? _long() : _short();
            LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
            assertTrue(v.eligible, "unpaid carry independently permits positive-equity liquidation");
            assertEq(v.pnl, int256(1000e6));
            assertEq(v.equity, int256(1500e6));
            assertEq(v.maintenance, side == 0 ? 110e6 : 90e6);
            assertEq(v.claimConsumed, 0);
            assertEq(v.remainingClaim, 500e6);
            assertEq(v.carryWithheld, 200e6);
            assertEq(v.carryCash, 0);
            assertEq(v.carryWaived, 0);
            assertEq(v.fresh, 800e6);
            assertEq(v.immediate, 800e6);
            assertEq(v.deferred, 0);
            assertEq(v.charge, side == 0 ? 11e6 : 8e6);
            assertEq(v.retainedCash, side == 0 ? 801e6 : 800e6);
            assertEq(v.poolCashAfter, side == 0 ? 1_205_500_000 : 1204e6);
            assertEq(v.allClaimsAfter, 700e6);
            _assertConservation(x, v);
        }
    }

    function test_BothSidesPositiveGainCanWaiveCarryButCannotCreateFreshPayout() public pure {
        for (uint256 side; side < 2; ++side) {
            LiquidationReferenceMath.Input memory x = side == 0 ? _long() : _short();
            x.unpaidCarry = 1300e6;
            x.actionReserve = 17e6;
            x.committedMargin = 23e6;
            x.cash = side == 0 ? 52e6 : 48e6;

            LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
            assertEq(v.pnl, int256(1000e6));
            assertEq(v.carryWithheld, 1000e6);
            assertEq(v.actionReserveConsumed, 17e6);
            assertEq(v.freeConsumed, 0);
            assertEq(v.committedConsumed, 23e6);
            assertEq(v.carryCash, 40e6);
            assertEq(v.carryWaived, 260e6);
            assertEq(v.fresh, 0);
            assertEq(v.immediate, 0);
            assertEq(v.deferred, 0);
            assertEq(v.remainingClaim, 500e6, "old claim never funds carry");
            assertEq(v.retainedCash, side == 0 ? 1e6 : 0, "unused liquidation reserve survives waiver");
            assertEq(v.poolCashAfter, side == 0 ? 2_045_500_000 : 2044e6);
            _assertConservation(x, v);
        }
    }

    function test_WithheldNegativeVpiReleasesItsBackingForCarryBeforeWaiver() public pure {
        LiquidationReferenceMath.Input memory x = _long();
        x.price = 119_500_000;
        x.vpiClawback = 80e6;
        x.unpaidCarry = 90e6;
        x.actionReserve = 7e6;
        x.committedMargin = 11e6;
        x.cash = 113e6; // $12 liquidation + $80 VPI + $7 action + $11 committed + $3 protected.
        x.poolCash = 1000e6;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.pnl, int256(50e6));
        assertEq(v.vpiWithheld, 50e6);
        assertEq(v.vpiConsumed, 30e6);
        assertEq(v.vpiReleased, 50e6);
        assertEq(v.carryWithheld, 0);
        assertEq(v.actionReserveConsumed, 7e6);
        assertEq(v.freeConsumed, 50e6, "released VPI reserve becomes eligible carry cash");
        assertEq(v.committedConsumed, 11e6);
        assertEq(v.carryCash, 68e6);
        assertEq(v.carryWaived, 22e6);
        assertEq(v.fresh, 0);
        assertEq(v.charge, 11_950_000);
        assertEq(v.keeper, 5_975_000);
        assertEq(v.lpFee, 5_975_000);
        assertEq(v.retainedCash, 3_050_000, "protected cash and unused liquidation reserve remain");
        assertEq(v.remainingClaim, 500e6);
        assertEq(v.poolCashAfter, 1_103_975_000);
        assertEq(v.allClaimsAfter, 700e6);
        _assertConservation(x, v);
    }

    function test_GainPaysVpiAndCarryAndRetainsReleasedVpiBacking() public pure {
        LiquidationReferenceMath.Input memory x = _long();
        x.vpiClawback = 80e6;
        x.cash = 92e6;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.vpiWithheld, 80e6);
        assertEq(v.vpiConsumed, 0);
        assertEq(v.vpiReleased, 80e6);
        assertEq(v.carryWithheld, 200e6);
        assertEq(v.carryCash, 0);
        assertEq(v.carryWaived, 0);
        assertEq(v.freeConsumed, 0);
        assertEq(v.fresh, 720e6);
        assertEq(v.immediate, 720e6);
        assertEq(v.retainedCash, 801e6);
        assertEq(v.poolCashAfter, 1_285_500_000);
        _assertConservation(x, v);
    }

    function test_ExactCashAfterOldClaimReservePaysImmediately() public pure {
        LiquidationReferenceMath.Input memory x = _short();
        x.poolCash = 1496e6;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.lpFee, 4e6);
        assertEq(v.fresh, 800e6);
        assertEq(v.immediate, 800e6, "$1496 + $4 fee - $700 old claims exactly funds $800");
        assertEq(v.deferred, 0);
        assertEq(v.retainedCash, 800e6);
        assertEq(v.poolCashAfter, 700e6);
        assertEq(v.remainingClaim, 500e6);
        assertEq(v.allClaimsAfter, 700e6);
        _assertConservation(x, v);
    }

    function test_OneAtomBelowPayoutEqualityDefersTheEntireFreshGain() public pure {
        LiquidationReferenceMath.Input memory x = _short();
        x.poolCash = 1_495_999_999;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.fresh, 800e6);
        assertEq(v.immediate, 0);
        assertEq(v.deferred, 800e6);
        assertEq(v.retainedCash, 0);
        assertEq(v.poolCashAfter, 1_499_999_999);
        assertEq(v.remainingClaim, 1300e6);
        assertEq(v.allClaimsAfter, 1500e6);
        _assertConservation(x, v);
    }

    function test_HealthyClaimBackedGainBecomesLiquidatableWithOneAtomUncoveredCarry() public pure {
        LiquidationReferenceMath.Input memory x = _short();
        x.unpaidCarry = 0;
        LiquidationReferenceMath.Values memory healthy = LiquidationReferenceMath.calculate(x);
        assertFalse(healthy.eligible);
        assertEq(healthy.pnl, int256(1000e6));
        assertEq(healthy.equity, int256(1500e6));
        assertEq(healthy.maintenance, 90e6);
        assertEq(healthy.charge, 0, "healthy results contain diagnostics without settlement");
        assertEq(healthy.fresh, 0);

        x.unpaidCarry = 1;
        LiquidationReferenceMath.Values memory delinquent = LiquidationReferenceMath.calculate(x);
        assertTrue(delinquent.eligible);
        assertEq(delinquent.equity, int256(1500e6), "carry is not subtracted again from price equity");
        assertEq(delinquent.carryWithheld, 1);
        assertEq(delinquent.fresh, 999_999_999);
        assertEq(delinquent.remainingClaim, 500e6);
        _assertConservation(x, delinquent);
    }

    function test_MaintenanceEqualityLiquidatesAndOneAtomAboveIsHealthy() public pure {
        LiquidationReferenceMath.Input memory x = _long();
        x.price = 120_000_000;
        x.pledge = 120e6;
        x.cash = 132e6;
        x.claim = 0;
        x.allClaims = 0;
        x.unpaidCarry = 0;

        LiquidationReferenceMath.Values memory atThreshold = LiquidationReferenceMath.calculate(x);
        assertEq(atThreshold.equity, int256(120e6));
        assertEq(atThreshold.maintenance, 120e6);
        assertTrue(atThreshold.eligible);
        assertEq(atThreshold.charge, 12e6);
        assertEq(atThreshold.retainedCash, 120e6);
        _assertConservation(x, atThreshold);

        x.pledge = 120_000_001;
        x.cash = 132_000_001;
        LiquidationReferenceMath.Values memory healthy = LiquidationReferenceMath.calculate(x);
        assertFalse(healthy.eligible);
        assertEq(healthy.equity, int256(120_000_001));
        assertEq(healthy.maintenance, 120e6);
        assertEq(healthy.charge, 0);
    }

    function test_ChargeFloorIsReserveCappedAndOddAtomGoesToLp() public pure {
        LiquidationReferenceMath.Input memory x = _long();
        x.lots = 1;
        x.basis = 70_000_001;
        x.price = 60_000_001;
        x.cash = 999_999;
        x.claim = 0;
        x.allClaims = 0;
        x.poolCash = 100e6;
        x.liquidationReserve = 999_999;
        x.unpaidCarry = 1;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.pnl, int256(10e6));
        assertEq(v.maintenance, 600_000);
        assertEq(v.charge, 999_999);
        assertEq(v.keeper, 499_999);
        assertEq(v.lpFee, 500_000);
        assertEq(v.fresh, 9_999_999);
        assertEq(v.retainedCash, 9_999_999);
        assertEq(v.poolCashAfter, 90_500_001);
        _assertConservation(x, v);
    }

    function test_CarryWaiverCannotSpendOldClaimOrUnusedLiquidationReserve() public pure {
        LiquidationReferenceMath.Input memory x = _long();
        x.lots = 1;
        x.basis = 70_000_001;
        x.price = 70_000_001;
        x.cash = 5e6;
        x.claim = 100e6;
        x.allClaims = 100e6;
        x.poolCash = 1000e6;
        x.liquidationReserve = 5e6;
        x.unpaidCarry = 3e6;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        assertEq(v.pnl, 0);
        assertEq(v.charge, 1e6);
        assertEq(v.carryCash, 0);
        assertEq(v.carryWaived, 3e6);
        assertEq(v.remainingClaim, 100e6);
        assertEq(v.retainedCash, 4e6);
        assertEq(v.poolCashAfter, 1_000_500_000);
        _assertConservation(x, v);
    }

    function testFuzz_PostCollectionLiquidationConservesCustodyAndObligations(
        bool isLong,
        uint256 basisSeed,
        uint256 priceSeed,
        uint256 carrySeed,
        uint256 collateralSeed,
        uint256 cashSeed
    ) public pure {
        LiquidationReferenceMath.Input memory x;
        x.isLong = isLong;
        x.lots = bound(basisSeed, 1, 1000);
        x.basis = x.lots * bound(basisSeed / 1000, 60_000_001, 140_000_003);
        x.price = bound(priceSeed, 60_000_001, 140_000_003);
        x.unpaidCarry = bound(carrySeed, 0, 200_000e6);
        // A post-collection arrear cannot coexist with available pledge or free settlement.
        if (x.unpaidCarry == 0) {
            x.pledge = collateralSeed % 1000e6;
            x.free = (collateralSeed / 1000e6) % 1000e6;
        }
        x.claim = collateralSeed % 10_000e6;
        x.allClaims = x.claim + (collateralSeed / 10_000e6) % 10_000e6;
        x.poolCash = bound(cashSeed, 0, 200_000e6);
        x.liquidationReserve = cashSeed % 100e6;
        x.vpiClawback = (cashSeed / 100e6) % 100e6;
        x.actionReserve = (cashSeed / 10_000e6) % 100e6;
        x.committedMargin = (cashSeed / 1_000_000e6) % 100e6;
        x.cash = x.pledge + x.free + x.liquidationReserve + x.vpiClawback + x.actionReserve + x.committedMargin + 3e6; // Protected execution bounty is deliberately excluded from eligible action sources.
        x.maintenanceBps = 100;

        LiquidationReferenceMath.Values memory v = LiquidationReferenceMath.calculate(x);
        if (v.eligible) {
            _assertConservation(x, v);
            assertGe(v.retainedCash, 3e6, "terminal settlement preserves protected cash");
        } else {
            assertEq(x.unpaidCarry, 0, "any uncovered carry makes a live position liquidatable");
            assertGt(v.equity, int256(v.maintenance));
            assertEq(v.charge, 0);
        }
    }

    function _assertConservation(
        LiquidationReferenceMath.Input memory x,
        LiquidationReferenceMath.Values memory v
    ) private pure {
        assertTrue(v.eligible);
        assertEq(x.cash + x.poolCash, v.retainedCash + v.poolCashAfter + v.keeper, "physical custody");
        assertEq(x.claim + v.deferred, v.remainingClaim + v.claimConsumed, "same-account claims");
        assertEq(x.allClaims + v.deferred, v.allClaimsAfter + v.claimConsumed, "global claims");
        assertEq(x.allClaims - x.claim, v.allClaimsAfter - v.remainingClaim, "other accounts retain their claims");
        assertEq(v.charge, v.keeper + v.lpFee, "liquidation fee destinations");
        assertEq(x.vpiClawback, v.vpiWithheld + v.vpiConsumed, "VPI recovery");
        assertEq(x.unpaidCarry, v.carryWithheld + v.carryCash + v.carryWaived, "carry disposition");
        assertEq(v.carryCash, v.actionReserveConsumed + v.freeConsumed + v.committedConsumed, "carry cash sources");
        assertEq(v.gain, v.vpiWithheld + v.carryWithheld + v.fresh, "positive price PnL destinations");
        assertEq(v.fresh, v.immediate + v.deferred, "fresh payout routing");
        assertTrue(v.immediate == 0 || v.deferred == 0, "fresh payout is not partially funded");
        assertLe(v.charge, x.liquidationReserve);
        assertLe(v.actionReserveConsumed, x.actionReserve);
        assertLe(v.freeConsumed, x.free + v.vpiReleased);
        assertLe(v.committedConsumed, x.committedMargin);
        if (v.pnl < 0) {
            assertEq(uint256(-v.pnl), v.claimConsumed + v.pledgeConsumed + v.writtenOff, "price loss disposition");
            if (v.pledgeConsumed != 0 || v.writtenOff != 0) {
                assertEq(v.claimConsumed, x.claim, "price loss exhausts claims before pledge or write-off");
            }
            if (v.writtenOff != 0) {
                assertEq(v.pledgeConsumed, x.pledge);
            }
        } else {
            assertEq(v.claimConsumed, 0, "nonnegative PnL never spends old claims");
            assertEq(v.pledgeConsumed, 0);
            assertEq(v.writtenOff, 0);
        }
        if (v.fresh != 0) {
            assertEq(v.carryWaived, 0, "fresh price payout excludes carry waiver");
        }
        if (v.carryWaived != 0) {
            assertEq(v.actionReserveConsumed, x.actionReserve);
            assertEq(v.freeConsumed, x.free + v.vpiReleased);
            assertEq(v.committedConsumed, x.committedMargin);
        }
    }

    function _long() private pure returns (LiquidationReferenceMath.Input memory x) {
        x = _short();
        x.isLong = true;
        x.basis = 12_000e6;
        x.price = 110_000_000;
        x.cash = 12e6;
        x.liquidationReserve = 12e6;
    }

    function _short() private pure returns (LiquidationReferenceMath.Input memory x) {
        x.lots = 100;
        x.basis = 8000e6;
        x.price = 90_000_000;
        x.cash = 8e6;
        x.claim = 500e6;
        x.allClaims = 700e6;
        x.poolCash = 2000e6;
        x.liquidationReserve = 8e6;
        x.unpaidCarry = 200e6;
        x.maintenanceBps = 100;
    }

}
