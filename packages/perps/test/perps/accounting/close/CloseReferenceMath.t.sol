// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CloseReferenceMath} from "../../invariant/ghost/CloseReferenceMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Hand-calculated, fixed-atom close vectors. Production planners and getters do not supply expectations.
contract CloseReferenceMathTest is Test {

    function test_ClaimNetsFirstAndStrictHealthRetainsAnExtraAtom() public pure {
        CloseReferenceMath.Input memory x = _base();
        x.lots = 2;
        x.closeLots = 1;
        x.basis = 20;
        x.price = 100;
        x.margin = 100;
        x.cash = 100;
        x.claim = 100;
        x.allClaims = 100;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        // Each lot loses 90. The first consumes 90 claim atoms, leaving claim 10 and pledge 100.
        // The remainder needs 91 collateral for positive equity: retain pledge 81 and release exactly 19.
        assertTrue(v.valid);
        assertEq(v.closedBasis, 10);
        assertEq(v.claimConsumed, 90);
        assertEq(v.pledgeConsumed, 0);
        assertEq(v.safeMarginRelease, 19);
        assertEq(v.remainingMargin, 81);
        assertEq(v.remainingClaim, 10);
        assertEq(v.remainingEquity, 1);
        assertEq(v.preTerminalLpDelta, 180);
        assertEq(v.requiredResidualLpDelta, 90);
        assertEq(v.remainingCash, 100);
    }

    function test_DelayedChangedMarkRequiresExtraPledgeForBothSides() public pure {
        CloseReferenceMath.Input memory x = _delayedLoss();
        CloseReferenceMath.Values memory longResult = CloseReferenceMath.calculate(x);
        // $4,000 total loss; half realizes $2,000, using $1,000 claim plus $1,000 pledge.
        // The surviving $6,000 notional requires equity >$60. Of $2,100 pledge, only $39.999999 may leave.
        assertTrue(longResult.valid);
        assertEq(longResult.claimConsumed, 1000e6);
        assertEq(longResult.pledgeConsumed, 1000e6);
        assertEq(longResult.safeMarginRelease, 39_999_999);
        assertEq(longResult.remainingMargin, 2_060_000_001);
        assertEq(longResult.remainingEquity, 60_000_001);
        assertEq(longResult.remainingCash, 2_521_600_000);
        assertEq(longResult.remainingFree, 151_599_999);
        assertEq(longResult.remainingLiquidationReserve, 6e6);
        assertEq(longResult.committedMarginConsumed, 0);
        assertEq(longResult.treasuryCredit, 2_400_000);
        assertEq(longResult.poolCashAfter, 1_001_000e6);

        x.isLong = false;
        x.basis = 12_000e6;
        x.price = 80_000_000;
        CloseReferenceMath.Values memory shortResult = CloseReferenceMath.calculate(x);
        assertTrue(shortResult.valid);
        assertEq(shortResult.claimConsumed, 1000e6);
        assertEq(shortResult.pledgeConsumed, 1000e6);
        assertEq(shortResult.safeMarginRelease, 59_999_999);
        assertEq(shortResult.remainingMargin, 2_040_000_001);
        assertEq(shortResult.remainingEquity, 40_000_001);
        assertEq(shortResult.treasuryCredit, 1_600_000);
        assertEq(shortResult.remainingLiquidationReserve, 4e6);
        assertEq(shortResult.remainingCash, 2_522_400_000);
    }

    function test_BasisDustCanRequireMoreThanProRataLossBeforeHealthRejects() public pure {
        CloseReferenceMath.Input memory x = _base();
        x.lots = 2;
        x.closeLots = 1;
        x.basis = 1;
        x.price = 1;
        x.margin = 1;
        x.cash = 1;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertFalse(v.valid);
        assertEq(v.revertCode, 6);
        assertEq(v.closedBasis, 0);
        assertEq(v.pledgeConsumed, 1, "the lost basis atom cannot disappear behind a zero pro-rata allocation");
        assertEq(v.writtenOff, 0);
    }

    function test_PartialCannotSpendClaimsLiquidationReserveOrQueuedMargin() public pure {
        CloseReferenceMath.Input memory x = _base();
        x.lots = 2;
        x.closeLots = 1;
        x.basis = 160e6;
        x.price = 80_000_000;
        x.claim = 200e6;
        x.allClaims = 200e6;
        x.liquidationReserve = 100e6;
        x.committedMargin = 100e6;
        x.protectedBounty = 20e6;
        x.cash = 220e6;
        CloseReferenceMath.Values memory partialResult = CloseReferenceMath.calculate(x);
        assertFalse(partialResult.valid);
        assertEq(partialResult.revertCode, 4);
        assertEq(partialResult.actionWaived, 32_000);
        assertEq(partialResult.committedMarginConsumed, 0);
        assertEq(partialResult.freeConsumed, 0);
        assertEq(partialResult.claimConsumed, 0);

        x.closeLots = 2;
        CloseReferenceMath.Values memory fullResult = CloseReferenceMath.calculate(x);
        assertTrue(fullResult.valid);
        assertEq(fullResult.actionCash, 64_000);
        assertEq(fullResult.freeConsumed, 64_000, "terminal liquidation reserve is eligible cash");
        assertEq(fullResult.committedMarginConsumed, 0);
        assertEq(fullResult.remainingCash, 219_936_000);
        assertEq(fullResult.remainingFree, 99_936_000);
        assertEq(fullResult.remainingClaim, 200e6);
        assertEq(fullResult.treasuryCredit, 64_000);
    }

    function test_TerminalChargesConsumeSurplusBeforePendingMarginAndPreserveBounty() public pure {
        CloseReferenceMath.Input memory x = _flatPriceFull();
        x.margin = 3e6;
        x.liquidationReserve = 2e6;
        x.otherActionReserve = 1e6;
        x.committedMargin = 100e6;
        x.protectedBounty = 20e6;
        x.cash = 127e6; // includes one settlementToken initially free
        x.vpiDelta = 16_800_000;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertTrue(v.valid);
        assertEq(v.actionAssessed, 20e6);
        assertEq(v.spendableActionConsumed, 1e6);
        assertEq(v.freeConsumed, 3e6);
        assertEq(v.releasedMarginConsumed, 3e6);
        assertEq(v.committedMarginConsumed, 13e6);
        assertEq(v.actionWaived, 0);
        assertEq(v.remainingCash, 107e6);
        assertEq(v.remainingFree, 0);
        assertEq(v.treasuryCredit, 3_200_000);
        assertEq(v.poolCashAfter, 1_000_016_800_000);
    }

    function test_ClawbackWithheldFromGainReleasesItsBackingExactlyOnce() public pure {
        CloseReferenceMath.Input memory x = _flatPriceFull();
        x.price = 79_940_000;
        x.margin = 20e6;
        x.liquidationReserve = 2e6;
        x.lifetimeVpi = -5e6;
        x.vpiReserve = 5e6;
        x.protectedBounty = 2e6;
        x.cash = 29e6;
        x.poolCash = 10e6;
        x.poolAccounted = 10e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertTrue(v.valid);
        assertEq(v.priceGain, 6e6);
        assertEq(v.vpi, 5e6);
        assertEq(v.actionWithheld, 6e6);
        assertEq(v.vpiConsumed, 0);
        assertEq(v.vpiReleased, 5e6);
        assertEq(v.actionCash, 2_197_600);
        assertEq(v.feeFromCash, 2_197_600);
        assertEq(v.feeTopUp, 1e6);
        assertEq(v.treasuryCredit, 3_197_600);
        assertEq(v.poolCashAfter, 9e6);
        assertEq(v.remainingCash, 26_802_400);
        assertEq(v.remainingFree, 24_802_400);
    }

    function test_ImmediateAndDeferredPartialGainsBecomeExactlyOneKindOfBacking() public pure {
        CloseReferenceMath.Input memory x = _base();
        x.lots = 2;
        x.closeLots = 1;
        x.basis = 160e6;
        x.price = 60_000_000;
        x.margin = 2e6;
        x.cash = 2e6;
        x.poolCash = 100e6;
        x.poolAccounted = 100e6;
        CloseReferenceMath.Values memory immediate = CloseReferenceMath.calculate(x);
        assertTrue(immediate.valid);
        assertEq(immediate.immediatePayout, 19_976_000);
        assertEq(immediate.deferredPayout, 0);
        assertEq(immediate.remainingMargin, 20_976_000);
        assertEq(immediate.remainingClaim, 0);
        assertEq(immediate.remainingCash, 21_976_000);
        assertEq(immediate.poolCashAfter, 80e6);
        assertEq(immediate.treasuryCredit, 24_000);

        x.poolCash = 10e6;
        x.poolAccounted = 10e6;
        CloseReferenceMath.Values memory deferred = CloseReferenceMath.calculate(x);
        assertTrue(deferred.valid);
        assertEq(deferred.immediatePayout, 0);
        assertEq(deferred.deferredPayout, 19_976_000);
        assertEq(deferred.remainingMargin, 1e6);
        assertEq(deferred.remainingClaim, 19_976_000);
        assertEq(deferred.remainingCash, 2e6);
        assertEq(deferred.poolCashAfter, 10e6);
        assertEq(deferred.allClaimsAfter, 19_976_000);
        assertEq(deferred.treasuryCredit, 0, "a withheld fee cannot take cash protected by the newly deferred claim");
    }

    function test_NewClaimHasPriorityOverCashPaymentOfAnActionRebate() public pure {
        CloseReferenceMath.Input memory x = _flatPriceFull();
        x.price = 78_000_000;
        x.margin = 20e6;
        x.liquidationReserve = 2e6;
        x.protectedBounty = 2e6;
        x.cash = 24e6;
        x.lifetimeVpi = 10e6;
        x.vpiDelta = -10e6;
        x.claim = 10e6;
        x.allClaims = 10e6;
        x.poolCash = 100e6;
        x.poolAccounted = 100e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertTrue(v.valid);
        assertEq(v.priceGain, 200e6);
        assertEq(v.deferredPayout, 200e6);
        assertEq(v.rebateAssessed, 6_880_000);
        assertEq(v.rebatePaid, 0);
        assertEq(v.rebateWaived, 6_880_000);
        assertEq(v.remainingClaim, 210e6);
        assertEq(v.poolCashAfter, 100e6);
        assertEq(v.remainingCash, 24e6);
        assertEq(v.treasuryCredit, 0);
    }

    function test_FadHealthAndFrozenSpreadAreIndependentInputs() public pure {
        CloseReferenceMath.Input memory x = _delayedLoss();
        x.maintenanceBps = 500;
        CloseReferenceMath.Values memory fad = CloseReferenceMath.calculate(x);
        assertFalse(fad.valid);
        assertEq(fad.revertCode, 6);
        assertEq(fad.maintenance, 300e6);
        assertEq(fad.assessedSpread, 0, "FAD alone does not assess frozen spread");
        x.maintenanceBps = 100;
        x.frozen = true;
        CloseReferenceMath.Values memory frozen = CloseReferenceMath.calculate(x);
        assertTrue(frozen.valid);
        assertEq(frozen.assessedSpread, 30e6);
        assertEq(frozen.actionCash, 32_400_000);
        assertEq(frozen.treasuryCredit, 2_400_000);
        assertEq(frozen.poolCashAfter, 1_001_030e6);
        assertEq(frozen.remainingMargin, 2_060_000_001);
    }

    function test_UnpaidCarrySharesEligibleTerminalCashButNeverConsumesBounties() public pure {
        CloseReferenceMath.Input memory x = _flatPriceFull();
        x.liquidationReserve = 2e6;
        x.lifetimeVpi = -5e6;
        x.vpiReserve = 5e6;
        x.otherActionReserve = 1e6;
        x.committedMargin = 10e6;
        x.protectedBounty = 20e6;
        x.cash = 38e6;
        x.unpaidCarry = 11e6; // margin and ordinary free cash have already been exhausted by the collector
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertTrue(v.valid);
        assertEq(v.actionAssessed, 19_200_000);
        assertEq(v.vpiConsumed, 5e6);
        assertEq(v.spendableActionConsumed, 1e6);
        assertEq(v.freeConsumed, 2e6);
        assertEq(v.committedMarginConsumed, 10e6);
        assertEq(v.actionCash, 18e6);
        assertEq(v.actionWaived, 1_200_000);
        assertEq(v.remainingCash, 20e6, "every remaining atom belongs to protected execution bounties");
        assertEq(v.remainingFree, 0);
        assertEq(v.treasuryCredit, 3_200_000);
        assertEq(v.poolCashAfter, 1_000_014_800_000);
        assertEq(v.carryCash, 9_800_000);
        assertEq(v.carryWithheld, 0);
        assertEq(v.carryVpiOffset, 0);
        assertEq(v.carryWaived, 1_200_000);
    }

    function test_CarryAttributionExcludesPhysicalFeeAndClawbackPayments() public pure {
        CloseReferenceMath.Input memory x = _carryPriority();
        x.lifetimeVpi = -3e6;
        x.vpiReserve = 3e6;
        x.otherActionReserve = 2e6;
        x.cash = 25e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        // Five collected dollars pay three dollars of clawback, one of fee, and only one of carry.
        assertTrue(v.valid);
        assertEq(v.actionAssessed, 14e6);
        assertEq(v.actionCash, 5e6);
        assertEq(v.vpiConsumed, 3e6);
        assertEq(v.treasuryCredit, 1e6);
        assertEq(v.carryCash, 1e6);
        assertEq(v.carryWithheld, 0);
        assertEq(v.carryVpiOffset, 0);
        assertEq(v.carryWaived, 9e6);
        assertEq(v.poolCashAfter, 1_000_004e6);
        assertEq(v.remainingCash, 20e6);
    }

    function test_CarryWithholdingAndPhysicalCashAreDisjoint() public pure {
        CloseReferenceMath.Input memory x = _carryPriority();
        x.basis += 6e6;
        x.lifetimeVpi = -3e6;
        x.vpiReserve = 3e6;
        x.otherActionReserve = 2e6;
        x.cash = 25e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        // Six dollars of gain pay the clawback, fee and two of carry. The five eligible custody dollars
        // (including the released clawback backing) pay five more carry; three carry dollars are waived.
        assertTrue(v.valid);
        assertEq(v.actionWithheld, 6e6);
        assertEq(v.actionCash, 5e6);
        assertEq(v.vpiConsumed, 0);
        assertEq(v.vpiReleased, 3e6);
        assertEq(v.carryWithheld, 2e6);
        assertEq(v.carryCash, 5e6);
        assertEq(v.carryVpiOffset, 0);
        assertEq(v.carryWaived, 3e6);
        assertEq(v.poolCashAfter, 1_000_004e6);
        assertEq(v.remainingCash, 20e6);
    }

    function test_NegativeVpiResolvesCarryWithoutPretendingCashArrived() public pure {
        CloseReferenceMath.Input memory x = _carryPriority();
        x.lifetimeVpi = 20e6;
        x.vpiDelta = -6e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        assertTrue(v.valid);
        assertEq(v.actionAssessed, 5e6);
        assertEq(v.actionWaived, 5e6); // one unpaid fee plus four unpaid carry
        assertEq(v.carryVpiOffset, 6e6);
        assertEq(v.carryCash, 0);
        assertEq(v.carryWithheld, 0);
        assertEq(v.carryWaived, 4e6);
        assertEq(v.poolCashAfter, 1_000_000e6);
        assertEq(v.remainingCash, 20e6);

        x.vpiDelta = -20e6;
        v = CloseReferenceMath.calculate(x);
        // Twenty dollars of negative VPI net the ten carry and one fee, leaving a nine-dollar cash rebate.
        assertTrue(v.valid);
        assertEq(v.carryVpiOffset, 10e6);
        assertEq(v.carryCash, 0);
        assertEq(v.carryWithheld, 0);
        assertEq(v.carryWaived, 0);
        assertEq(v.rebatePaid, 9e6);
        assertEq(v.poolCashAfter, 999_991e6);
        assertEq(v.remainingCash, 29e6);
    }

    function test_NegativeVpiOffsetsJuniorSpreadBeforeCarry() public pure {
        CloseReferenceMath.Input memory x = _carryPriority();
        x.frozen = true;
        x.lifetimeVpi = 20e6;
        x.vpiDelta = -16e6;
        x.otherActionReserve = 5e6;
        x.cash = 25e6;
        CloseReferenceMath.Values memory v = CloseReferenceMath.calculate(x);
        // $16 VPI offsets $12.50 spread, then $3.50 carry. Five custody dollars pay $1 fee and $4 carry.
        assertTrue(v.valid);
        assertEq(v.assessedSpread, 12_500_000);
        assertEq(v.actionAssessed, 7_500_000);
        assertEq(v.carryVpiOffset, 3_500_000);
        assertEq(v.carryCash, 4e6);
        assertEq(v.carryWithheld, 0);
        assertEq(v.carryWaived, 2_500_000);
        assertEq(v.poolCashAfter, 1_000_004e6);
        assertEq(v.remainingCash, 20e6);
    }

    function test_TypedInvalidCloseInputsAndUnderfundedVpi() public pure {
        CloseReferenceMath.Input memory x = _flatPriceFull();
        x.closeLots = 0;
        assertEq(CloseReferenceMath.calculate(x).revertCode, 3);
        x.closeLots = 101;
        assertEq(CloseReferenceMath.calculate(x).revertCode, 1);
        x.closeLots = 100;
        x.lifetimeVpi = -1;
        assertEq(CloseReferenceMath.calculate(x).revertCode, 5);
    }

    function _base() private pure returns (CloseReferenceMath.Input memory x) {
        x.isLong = true;
        x.poolCash = 1_000_000e6;
        x.poolAccounted = 1_000_000e6;
    }

    function _flatPriceFull() private pure returns (CloseReferenceMath.Input memory x) {
        x = _base();
        x.lots = 100;
        x.closeLots = 100;
        x.basis = 8000e6;
        x.price = 80_000_000;
    }

    function _carryPriority() private pure returns (CloseReferenceMath.Input memory x) {
        x = _base();
        x.lots = 100;
        x.closeLots = 100;
        x.basis = 2500e6;
        x.price = 25_000_000; // $2,500 notional gives exactly one settlementToken execution fee.
        x.unpaidCarry = 10e6;
        x.protectedBounty = 20e6;
        x.cash = 20e6;
    }

    function _delayedLoss() private pure returns (CloseReferenceMath.Input memory x) {
        x = _base();
        x.lots = 100;
        x.closeLots = 50;
        x.basis = 8000e6;
        x.price = 120_000_000;
        x.margin = 3100e6;
        x.claim = 1000e6;
        x.allClaims = 1000e6;
        x.liquidationReserve = 20e6;
        x.committedMargin = 300e6;
        x.protectedBounty = 4e6;
        x.cash = 3524e6;
        x.maintenanceBps = 100;
    }

}
