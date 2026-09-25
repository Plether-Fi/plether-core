// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract FullCloseActionChargePlanTest is Test {

    CfdEnginePlanner private planner;
    uint256 private constant SIZE = 10_000e18;
    uint256 private constant PRICE = 1e8;
    uint256 private constant FEE = 10e6;

    function setUp() public {
        planner = new CfdEnginePlanner();
    }

    function _snapshot(
        uint256 pledge,
        uint256 liquidationReserve,
        uint256 free,
        uint256 committed,
        uint256 action
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap = _positionSnapshot(pledge);
        snap.liquidationReserveUsdc = liquidationReserve;
        snap.actionReserveUsdc = action;
        snap.accountBuckets = MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
            pledge + liquidationReserve + free + committed + action, pledge, liquidationReserve, committed, action
        );
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets(
            pledge, committed, action, snap.accountBuckets.totalLockedMarginUsdc
        );
    }

    // Keep position construction separate from bucket inputs for minimally optimized coverage builds.
    function _positionSnapshot(
        uint256 pledge
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.account = address(0xA11CE);
        snap.capPrice = 2e8;
        snap.position = CfdTypes.Position(SIZE, pledge, PRICE, 10_000e6, CfdTypes.Side.LONG, 1, 1, 0);
        snap.positionEntryCostUsdcAtoms = CfdMath.sizeToLots(SIZE) * PRICE;
        snap.positionBorrowBaseUsdc = pledge < 10_000e6 ? 10_000e6 - pledge : 0;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot(
            10_000e6,
            SIZE,
            snap.positionEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE,
            pledge,
            snap.positionBorrowBaseUsdc,
            0
        );
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = snap.poolAssetsUsdc;
        snap.executionFeeBps = 10;
        snap.riskParams.minBountyUsdc = 1e6;
        snap.riskParams.bountyBps = 10;
        snap.riskParams.maintMarginBps = 100;
    }

    function _plan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 price,
        uint256 size
    ) private view returns (CfdEnginePlanTypes.CloseDelta memory) {
        CfdTypes.Order memory order;
        order.account = snap.account;
        order.isClose = true;
        order.sizeDelta = size;
        return planner.planClose(snap, order, price, 1);
    }

    function test_FullClose_SurplusFundingBoundaries() public view {
        _checkFunding(100e6, 0, FEE, 0); // pledge only
        _checkFunding(0, 100e6, FEE, 0); // liquidation reserve only
        _checkFunding(6e6, 4e6, FEE, 0); // both required
        _checkFunding(0, FEE - 1, FEE - 1, 1);
        _checkFunding(FEE, 0, FEE, 0);
        _checkFunding(FEE + 1, 0, FEE, 0);
        _checkFunding(0, 0, 0, FEE); // genuinely exhausted safe exit
    }

    function _checkFunding(
        uint256 pledge,
        uint256 reserve,
        uint256 collected,
        uint256 waived
    ) private view {
        CfdEnginePlanTypes.CloseDelta memory d = _plan(_snapshot(pledge, reserve, 0, 0, 0), PRICE, SIZE);
        assertTrue(d.valid);
        assertEq(d.actionChargeAssessedUsdc, FEE);
        assertEq(d.actionChargeCollectedUsdc, collected);
        assertEq(d.actionChargeWaivedUsdc, waived);
        assertEq(d.posMarginAfter, 0);
        assertEq(d.priceLossWrittenOffUsdc, 0);
    }

    function test_FullClose_SurplusPrecedesCommittedMarginAndProtectsBounty() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(3e6, 2e6, 1e6, 100e6, 21e6);
        snap.protectedExecutionBountyUsdc = 20e6;
        CfdEnginePlanTypes.CloseDelta memory d = _plan(snap, PRICE, SIZE);
        assertTrue(d.valid);
        assertEq(d.actionReserveConsumedUsdc, 1e6);
        assertEq(d.actionCommittedMarginConsumedUsdc, 3e6);
        assertEq(d.actionChargeCollectedUsdc, FEE);
        assertEq(d.actionChargeWaivedUsdc, 0);
    }

    function test_Close_NearFullCannotUseReleasedSurplusOrCommittedMargin() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(200e6, 10e6, 0, 100e6, 0);
        CfdEnginePlanTypes.CloseDelta memory partialClose = _plan(snap, PRICE, SIZE - CfdTypes.SIZE_QUANTUM);
        assertFalse(partialClose.valid);
        assertEq(
            uint8(partialClose.revertCode),
            uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE)
        );
        assertGt(partialClose.unlockMarginUsdc, 0);
        assertEq(partialClose.actionCommittedMarginConsumedUsdc, 0);
        CfdEnginePlanTypes.CloseDelta memory full = _plan(snap, PRICE, SIZE);
        assertTrue(full.valid);
        assertEq(full.actionChargeWaivedUsdc, 0);
        assertEq(full.actionCommittedMarginConsumedUsdc, 0);
    }

    function test_FullClose_PriceLossCapCannotReachLiquidationReserve() public view {
        CfdEnginePlanTypes.CloseDelta memory d = _plan(_snapshot(1e6, 100e6, 0, 0, 0), 101_000_000, SIZE);
        assertTrue(d.valid);
        assertEq(d.priceLossUsdc, 100e6);
        assertEq(d.pricePnlPledgeConsumedUsdc, 1e6);
        assertEq(d.priceLossWrittenOffUsdc, 99e6);
        assertEq(d.actionChargeCollectedUsdc, d.actionChargeAssessedUsdc);
        assertEq(d.unlockMarginUsdc, 0);
    }

    function test_FullClose_CarryPrecedesSurplusAndDoesNotSpendClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(20e6, 8e6, 5e6, 0, 2e6);
        snap.protectedExecutionBountyUsdc = 2e6;
        snap.unsettledCarryUsdc = 30e6;
        snap.traderClaimBalanceForAccount = 1000e6;
        snap.totalTraderClaimBalanceUsdc = 1000e6;
        CfdEnginePlanTypes.CloseDelta memory d = _plan(snap, PRICE, SIZE);
        assertTrue(d.valid);
        assertEq(d.realizedCarryUsdc, 25e6);
        assertEq(d.unlockMarginUsdc, 0);
        assertEq(d.actionChargeAssessedUsdc, FEE + 5e6);
        assertEq(d.actionChargeCollectedUsdc, 8e6);
        assertEq(d.actionChargeWaivedUsdc, 7e6);
        assertEq(d.actionReserveConsumedUsdc, 0);
        assertEq(d.existingTraderClaimConsumedUsdc, 0);
        assertEq(d.existingTraderClaimRemainingUsdc, 1000e6);
    }

    function test_FullClose_VpiClawbackAndReleasedBackingAreNotDoubleCounted() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(20e6, 2e6, 0, 0, 7e6);
        snap.position.vpiAccrued = -5e6;
        snap.vpiRebateReserveUsdc = 5e6;
        snap.protectedExecutionBountyUsdc = 2e6;
        CfdEnginePlanTypes.CloseDelta memory flat = _plan(snap, PRICE, SIZE);
        assertEq(flat.vpiRebateReserveConsumedUsdc, 5e6);
        assertEq(flat.actionChargeCollectedUsdc, FEE + 5e6);
        assertEq(flat.actionReserveConsumedUsdc, 0);
        assertEq(flat.actionChargeWaivedUsdc, 0);
        // A $6 price gain withholds the entire clawback, releasing its backing into free settlement.
        CfdEnginePlanTypes.CloseDelta memory gain = _plan(snap, 99_940_000, SIZE);
        assertEq(gain.actionChargeWithheldUsdc, 6e6);
        assertEq(gain.vpiRebateReserveConsumedUsdc, 0);
        assertEq(gain.vpiRebateReserveAfterUsdc, 0);
        assertEq(gain.actionChargeWithheldUsdc + gain.actionChargeCollectedUsdc, gain.actionChargeAssessedUsdc);
        assertEq(gain.actionChargeWaivedUsdc, 0);
        assertEq(gain.actionProtocolFeeCreditedUsdc + gain.protocolFeeTopUpUsdc, gain.executionFeeUsdc);
    }

    function test_FullClose_PositiveAndNegativeVpiUseSurplusAfterNetting() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(100e6, 10e6, 0, 0, 0);
        snap.riskParams.vpiFactor = 0.1e18;
        snap.position.vpiAccrued = 100e6;
        CfdEnginePlanTypes.CloseDelta memory reducing = _plan(snap, PRICE, SIZE);
        assertTrue(reducing.valid);
        assertLt(reducing.closeState.vpiDeltaUsdc, 0);
        assertGt(reducing.actionChargeAssessedUsdc, 0);
        assertLt(reducing.actionChargeAssessedUsdc, FEE);
        assertEq(reducing.actionChargeCollectedUsdc, reducing.actionChargeAssessedUsdc);
        assertEq(reducing.actionChargeWaivedUsdc, 0);
        // Closing the long now worsens net short skew instead of reducing net long skew.
        snap.shortSide.openInterest = 2 * SIZE;
        snap.shortSide.entryNotional = 2 * snap.longSide.entryNotional;
        snap.shortSide.maxProfitUsdc = 20_000e6;
        CfdEnginePlanTypes.CloseDelta memory increasing = _plan(snap, PRICE, SIZE);
        assertTrue(increasing.valid);
        assertGt(increasing.closeState.vpiDeltaUsdc, 0);
        assertGt(increasing.actionChargeAssessedUsdc, FEE);
        assertEq(increasing.actionChargeCollectedUsdc, increasing.actionChargeAssessedUsdc);
        assertEq(increasing.actionChargeWaivedUsdc, 0);
    }

    function testFuzz_FullClose_CashPlacementDoesNotChangeRecovery(
        uint96 fundsSeed,
        uint96 allocationSeed,
        uint32 priceSeed
    ) public view {
        uint256 funds = bound(fundsSeed, 200e6, 1000e6);
        // Retain enough pledge for the largest price loss, so the price-loss cap is unchanged in both states.
        uint256 movable = bound(allocationSeed, 0, funds - 100e6);
        uint256 price = bound(priceSeed, 99_000_000, 101_000_000);
        CfdEnginePlanTypes.CloseDelta memory locked = _plan(_snapshot(funds, 10e6, 0, 0, 0), price, SIZE);
        CfdEnginePlanTypes.CloseDelta memory free = _plan(_snapshot(funds - movable, 10e6, movable, 0, 0), price, SIZE);
        assertTrue(locked.valid && free.valid);
        assertEq(locked.pricePnlPledgeConsumedUsdc, free.pricePnlPledgeConsumedUsdc);
        assertEq(locked.actionChargeCollectedUsdc, free.actionChargeCollectedUsdc);
        assertEq(locked.actionChargeWaivedUsdc, 0);
        assertEq(free.actionChargeWaivedUsdc, 0);
        assertEq(locked.freshTraderPayoutUsdc, free.freshTraderPayoutUsdc);
        assertEq(locked.solvency.effectiveAssetsAfterUsdc, free.solvency.effectiveAssetsAfterUsdc);
    }

}
