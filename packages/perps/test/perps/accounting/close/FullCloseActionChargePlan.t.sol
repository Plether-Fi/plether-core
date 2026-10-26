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
        snap.liquidationReserveAssets = liquidationReserve;
        snap.actionReserveAssets = action;
        snap.accountBuckets = MarginClearinghouseAccountingLib.buildIsolatedAccountAssetBuckets(
            pledge + liquidationReserve + free + committed + action, pledge, liquidationReserve, committed, action
        );
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets(
            pledge, committed, action, snap.accountBuckets.totalLockedMarginAssets
        );
    }

    // Keep position construction separate from bucket inputs for minimally optimized coverage builds.
    function _positionSnapshot(
        uint256 pledge
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.account = address(0xA11CE);
        snap.capPrice = 2e8;
        snap.position = CfdTypes.Position(SIZE, pledge, PRICE, 10_000e6, CfdTypes.Side.LONG, 1, 1, 0);
        snap.positionEntryCostAssetAtoms = CfdMath.sizeToLots(SIZE) * PRICE;
        snap.positionBorrowBaseAssets = pledge < 10_000e6 ? 10_000e6 - pledge : 0;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot(
            10_000e6,
            SIZE,
            snap.positionEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE,
            pledge,
            snap.positionBorrowBaseAssets,
            0
        );
        snap.poolAssets = 1_000_000e6;
        snap.poolCashAssets = snap.poolAssets;
        snap.executionFeeBps = 10;
        snap.riskParams.minBountyAssets = 1e6;
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
        return planner.planClose(snap, order, price);
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
        assertEq(d.actionChargeAssessedAssets, FEE);
        assertEq(d.actionChargeCollectedAssets, collected);
        assertEq(d.actionChargeWaivedAssets, waived);
        assertEq(d.safeMarginReleaseAssets, pledge);
        assertEq(d.actionChargeFromReleasedMarginAssets, collected > reserve ? collected - reserve : 0);
        assertEq(d.netReleasedMarginAssets, pledge - d.actionChargeFromReleasedMarginAssets);
        assertEq(d.posMarginAfter, 0);
        assertEq(d.priceLossWrittenOffAssets, 0);
    }

    function test_FullClose_SurplusPrecedesCommittedMarginAndProtectsBounty() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(3e6, 2e6, 1e6, 100e6, 21e6);
        snap.protectedExecutionBountyAssets = 20e6;
        CfdEnginePlanTypes.CloseDelta memory d = _plan(snap, PRICE, SIZE);
        assertTrue(d.valid);
        assertEq(d.actionReserveConsumedAssets, 1e6);
        assertEq(d.actionCommittedMarginConsumedAssets, 3e6);
        assertEq(d.actionChargeCollectedAssets, FEE);
        assertEq(d.actionChargeWaivedAssets, 0);
    }

    function test_Close_NearFullCannotUseLiquidationReserveOrCommittedMargin() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2e6, 10e6, 0, 100e6, 0);
        CfdEnginePlanTypes.CloseDelta memory partialClose = _plan(snap, PRICE, SIZE - CfdTypes.SIZE_QUANTUM);
        assertFalse(partialClose.valid);
        assertEq(
            uint8(partialClose.revertCode),
            uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE)
        );
        assertGt(partialClose.unlockMarginAssets, 0);
        assertEq(partialClose.actionCommittedMarginConsumedAssets, 0);
        CfdEnginePlanTypes.CloseDelta memory full = _plan(snap, PRICE, SIZE);
        assertTrue(full.valid);
        assertEq(full.actionChargeWaivedAssets, 0);
        assertEq(full.actionCommittedMarginConsumedAssets, 0);
    }

    function test_FullClose_PriceLossCapCannotReachLiquidationReserve() public view {
        CfdEnginePlanTypes.CloseDelta memory d = _plan(_snapshot(1e6, 100e6, 0, 0, 0), 101_000_000, SIZE);
        assertTrue(d.valid);
        assertEq(d.priceLossAssets, 100e6);
        assertEq(d.pricePnlPledgeConsumedAssets, 1e6);
        assertEq(d.priceLossWrittenOffAssets, 99e6);
        assertEq(d.actionChargeCollectedAssets, d.actionChargeAssessedAssets);
        assertEq(d.unlockMarginAssets, 0);
    }

    function test_FullClose_CarryPrecedesSurplusAndDoesNotSpendClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(20e6, 8e6, 5e6, 0, 2e6);
        snap.protectedExecutionBountyAssets = 2e6;
        snap.unsettledCarryAssets = 30e6;
        snap.traderClaimBalanceForAccount = 1000e6;
        snap.totalTraderClaimBalanceAssets = 1000e6;
        CfdEnginePlanTypes.CloseDelta memory d = _plan(snap, PRICE, SIZE);
        assertTrue(d.valid);
        assertEq(d.realizedCarryAssets, 25e6);
        assertEq(d.unlockMarginAssets, 0);
        assertEq(d.actionChargeAssessedAssets, FEE + 5e6);
        assertEq(d.actionChargeCollectedAssets, 8e6);
        assertEq(d.actionChargeWaivedAssets, 7e6);
        assertEq(d.actionReserveConsumedAssets, 0);
        assertEq(d.existingTraderClaimConsumedAssets, 0);
        assertEq(d.existingTraderClaimRemainingAssets, 1000e6);
    }

    function test_FullClose_VpiClawbackAndReleasedBackingAreNotDoubleCounted() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(20e6, 2e6, 0, 0, 7e6);
        snap.position.vpiAccrued = -5e6;
        snap.vpiRebateReserveAssets = 5e6;
        snap.protectedExecutionBountyAssets = 2e6;
        CfdEnginePlanTypes.CloseDelta memory flat = _plan(snap, PRICE, SIZE);
        assertEq(flat.vpiRebateReserveConsumedAssets, 5e6);
        assertEq(flat.actionChargeCollectedAssets, FEE + 5e6);
        assertEq(flat.actionReserveConsumedAssets, 0);
        assertEq(flat.actionChargeWaivedAssets, 0);
        // A $6 price gain withholds the entire clawback, releasing its backing into free settlement.
        CfdEnginePlanTypes.CloseDelta memory gain = _plan(snap, 99_940_000, SIZE);
        assertEq(gain.actionChargeWithheldAssets, 6e6);
        assertEq(gain.vpiRebateReserveConsumedAssets, 0);
        assertEq(gain.vpiRebateReserveAfterAssets, 0);
        assertEq(gain.actionChargeWithheldAssets + gain.actionChargeCollectedAssets, gain.actionChargeAssessedAssets);
        assertEq(gain.actionChargeWaivedAssets, 0);
        assertEq(gain.actionProtocolFeeCreditedAssets + gain.protocolFeeTopUpAssets, gain.executionFeeAssets);
    }

    function test_FullClose_PositiveAndNegativeVpiUseSurplusAfterNetting() public view {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(100e6, 10e6, 0, 0, 0);
        snap.riskParams.vpiFactor = 0.1e18;
        snap.position.vpiAccrued = 100e6;
        CfdEnginePlanTypes.CloseDelta memory reducing = _plan(snap, PRICE, SIZE);
        assertTrue(reducing.valid);
        assertLt(reducing.closeState.vpiDeltaAssets, 0);
        assertGt(reducing.actionChargeAssessedAssets, 0);
        assertLt(reducing.actionChargeAssessedAssets, FEE);
        assertEq(reducing.actionChargeCollectedAssets, reducing.actionChargeAssessedAssets);
        assertEq(reducing.actionChargeWaivedAssets, 0);
        // Closing the long now worsens net short skew instead of reducing net long skew.
        snap.shortSide.openInterest = 2 * SIZE;
        snap.shortSide.entryNotional = 2 * snap.longSide.entryNotional;
        snap.shortSide.maxProfitAssets = 20_000e6;
        CfdEnginePlanTypes.CloseDelta memory increasing = _plan(snap, PRICE, SIZE);
        assertTrue(increasing.valid);
        assertGt(increasing.closeState.vpiDeltaAssets, 0);
        assertGt(increasing.actionChargeAssessedAssets, FEE);
        assertEq(increasing.actionChargeCollectedAssets, increasing.actionChargeAssessedAssets);
        assertEq(increasing.actionChargeWaivedAssets, 0);
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
        assertEq(locked.pricePnlPledgeConsumedAssets, free.pricePnlPledgeConsumedAssets);
        assertEq(locked.actionChargeCollectedAssets, free.actionChargeCollectedAssets);
        assertEq(locked.actionChargeWaivedAssets, 0);
        assertEq(free.actionChargeWaivedAssets, 0);
        assertEq(locked.freshTraderPayoutAssets, free.freshTraderPayoutAssets);
        assertEq(locked.solvency.effectiveAssetsAfterAssets, free.solvency.effectiveAssetsAfterAssets);
    }

}
