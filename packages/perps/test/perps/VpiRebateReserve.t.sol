// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";

contract VpiRebateReserveTest is Test {

    uint256 internal constant ENTRY_PRICE = 100_000_000;
    uint256 internal constant CAP_PRICE = 200_000_000;

    function planLiquidationExternal(
        CfdEnginePlanTypes.RawSnapshot calldata snap,
        uint256 price
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        return CfdEnginePlanLib.planLiquidation(snap, price, 1);
    }

    function _riskParams(
        uint256 vpiFactor
    ) internal pure returns (CfdTypes.RiskParams memory params) {
        params = CfdTypes.RiskParams({
            vpiFactor: vpiFactor,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 0,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _positionSnapshot(
        uint256 vpiReserveUsdc,
        uint256 protectedBountyUsdc,
        uint256 pendingCarryUsdc
    ) internal pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 size = 1000e18;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostUsdcAtoms = lots * ENTRY_PRICE;
        uint256 marginUsdc = 20e6;
        uint256 liquidationReserveUsdc = 1e6;
        uint256 actionReserveUsdc = vpiReserveUsdc + protectedBountyUsdc;
        uint256 settlementBalanceUsdc = marginUsdc + liquidationReserveUsdc + actionReserveUsdc;
        uint256 maxProfitUsdc = CfdMath.calculateExactMaxProfit(lots, entryCostUsdcAtoms, CfdTypes.Side.LONG, CAP_PRICE);

        snap.account = address(0xBEEF);
        snap.position = CfdTypes.Position({
            size: size,
            margin: marginUsdc,
            entryPrice: ENTRY_PRICE,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 1,
            lastCarryTimestamp: 1,
            vpiAccrued: -10e6
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = ENTRY_PRICE;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: maxProfitUsdc,
            openInterest: size,
            entryNotional: entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE,
            totalMargin: marginUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 0, openInterest: 0, entryNotional: 0, totalMargin: 0, borrowBaseUsdc: 0, carryIndex: 0
        });
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementBalanceUsdc,
            totalLockedMarginUsdc: settlementBalanceUsdc,
            activePositionMarginUsdc: marginUsdc,
            otherLockedMarginUsdc: liquidationReserveUsdc + actionReserveUsdc,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: marginUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: actionReserveUsdc,
            totalLockedMarginUsdc: settlementBalanceUsdc
        });
        snap.liquidationReserveUsdc = liquidationReserveUsdc;
        snap.actionReserveUsdc = actionReserveUsdc;
        snap.vpiRebateReserveUsdc = vpiReserveUsdc;
        snap.protectedExecutionBountyUsdc = protectedBountyUsdc;
        snap.unsettledCarryUsdc = pendingCarryUsdc;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams(0);
    }

    function _closeOrder(
        address account,
        uint256 sizeDelta
    ) internal pure returns (CfdTypes.Order memory order) {
        order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 1,
            commitBlock: 1,
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
    }

    function test_PartialCloseKeepsExactRemainingReserveTarget() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.CloseDelta memory delta =
            CfdEnginePlanLib.planClose(snap, _closeOrder(snap.account, 500e18), ENTRY_PRICE, 1);

        assertTrue(delta.valid);
        assertEq(delta.vpiRebateReserveBeforeUsdc, 10e6);
        assertEq(delta.vpiRebateReserveAfterUsdc, 5e6);
        assertEq(delta.vpiRebateReserveConsumedUsdc, 5e6);
        assertEq(delta.actionChargeAssessedUsdc, 5e6);
        assertEq(delta.actionChargeCollectedUsdc, 5e6);
        assertEq(delta.actionChargeWaivedUsdc, 0);
        assertEq(snap.position.vpiAccrued - delta.posVpiAccruedReduction, -5e6);
    }

    function test_PriceGainWithholdingHasPriorityAndReleasesUnusedReserve() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.CloseDelta memory delta =
            CfdEnginePlanLib.planClose(snap, _closeOrder(snap.account, snap.position.size), 99_000_000, 1);

        assertTrue(delta.valid);
        assertEq(delta.priceGainUsdc, 10e6);
        assertEq(delta.actionChargeWithheldUsdc, 10e6);
        assertEq(delta.vpiRebateReserveConsumedUsdc, 0);
        assertEq(delta.vpiRebateReserveAfterUsdc, 0);
        assertEq(delta.actionChargeCollectedUsdc, 0);
        assertEq(delta.pricePayoutUsdc, 0);
    }

    function test_PositiveVpiOpenReleasesBackingBeforeCharging() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 size = 100_000e18;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostUsdcAtoms = lots * ENTRY_PRICE;
        uint256 marginUsdc = 20_000e6;
        uint256 orderMarginUsdc = 5000e6;
        uint256 liquidationReserveUsdc = 100e6;
        uint256 vpiReserveUsdc = 10e6;
        uint256 totalLockedUsdc = marginUsdc + liquidationReserveUsdc + vpiReserveUsdc;
        uint256 settlementBalanceUsdc = totalLockedUsdc + orderMarginUsdc;
        uint256 maxProfitUsdc = CfdMath.calculateExactMaxProfit(lots, entryCostUsdcAtoms, CfdTypes.Side.LONG, CAP_PRICE);

        snap.account = address(0xCAFE);
        snap.position = CfdTypes.Position({
            size: size,
            margin: marginUsdc,
            entryPrice: ENTRY_PRICE,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 1,
            lastCarryTimestamp: 1,
            vpiAccrued: -10e6
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = ENTRY_PRICE;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: maxProfitUsdc,
            openInterest: size,
            entryNotional: entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE,
            totalMargin: marginUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementBalanceUsdc,
            totalLockedMarginUsdc: totalLockedUsdc,
            activePositionMarginUsdc: marginUsdc,
            otherLockedMarginUsdc: liquidationReserveUsdc + vpiReserveUsdc,
            freeSettlementUsdc: orderMarginUsdc
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: marginUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: vpiReserveUsdc,
            totalLockedMarginUsdc: totalLockedUsdc
        });
        snap.liquidationReserveUsdc = liquidationReserveUsdc;
        snap.actionReserveUsdc = vpiReserveUsdc;
        snap.vpiRebateReserveUsdc = vpiReserveUsdc;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams(0.005e18);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: snap.account,
            sizeDelta: 10_000e18,
            marginDelta: orderMarginUsdc,
            targetPrice: ENTRY_PRICE,
            commitTime: 1,
            commitBlock: 1,
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, ENTRY_PRICE, 1);

        assertTrue(delta.valid);
        assertEq(delta.openState.vpiUsdc, 5_250_000);
        assertEq(delta.tradeCostUsdc, 5_250_000);
        assertEq(delta.vpiRebateReserveBeforeUsdc, 10e6);
        assertEq(delta.vpiRebateReserveAfterUsdc, 4_750_000);
        assertEq(delta.vpiRebateReserveFromPledgeUsdc, 0);
        assertEq(delta.positionMarginAfterOpen, 24_984_750_000);
    }

    function test_GrossRebateBackingIncludesFeeOffset() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = address(0xD00D);
        snap.position.side = CfdTypes.Side.SHORT;
        snap.longSide.openInterest = 300_000e18;
        snap.longSide.entryNotional = 300_000e6 * CfdMath.USDC_TO_TOKEN_SCALE;
        snap.poolAssetsUsdc = 2_000_000e6;
        snap.poolCashUsdc = 2_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 4920e6,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 4920e6
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams(0.05e18);
        snap.executionFeeBps = 4;

        CfdTypes.Order memory order = CfdTypes.Order({
            account: snap.account,
            sizeDelta: 300_000e18,
            marginDelta: 4920e6,
            targetPrice: ENTRY_PRICE,
            commitTime: 1,
            commitBlock: 1,
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, ENTRY_PRICE, 1);

        assertTrue(delta.valid);
        assertEq(delta.openState.vpiUsdc, -int256(1125e6));
        assertEq(delta.executionFeeUsdc, 120e6);
        assertEq(delta.poolRebatePayoutUsdc, 1005e6);
        assertEq(delta.vpiRebateReserveAfterUsdc, 1125e6);
        assertEq(delta.vpiRebateReserveFromPledgeUsdc, 120e6);
        assertEq(delta.positionMarginAfterOpen, 4500e6);
    }

    function test_LiquidationCancelsFundedVpiOnceAndProtectsBounty() public pure {
        CfdEnginePlanTypes.RawSnapshot memory baseline = _positionSnapshot(0, 0, 0);
        baseline.position.vpiAccrued = 0;
        baseline.actionReserveUsdc = 0;
        baseline.accountBuckets.settlementBalanceUsdc = 21e6;
        baseline.accountBuckets.otherLockedMarginUsdc = 1e6;
        baseline.accountBuckets.totalLockedMarginUsdc = 21e6;
        baseline.lockedBuckets.reservedSettlementUsdc = 0;
        baseline.lockedBuckets.totalLockedMarginUsdc = 21e6;

        CfdEnginePlanTypes.LiquidationDelta memory baselineDelta =
            CfdEnginePlanLib.planLiquidation(baseline, ENTRY_PRICE, 1);
        assertFalse(baselineDelta.liquidatable);
        assertEq(baselineDelta.riskState.equityUsdc, 20e6);

        CfdEnginePlanTypes.RawSnapshot memory funded = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.LiquidationDelta memory fundedDelta =
            CfdEnginePlanLib.planLiquidation(funded, ENTRY_PRICE, 1);
        assertFalse(fundedDelta.liquidatable);
        assertEq(
            fundedDelta.riskState.equityUsdc,
            baselineDelta.riskState.equityUsdc,
            "Funded reserve and matching VPI clawback must cancel exactly once"
        );

        CfdEnginePlanTypes.RawSnapshot memory withCarryAndBounty = _positionSnapshot(10e6, 3e6, 11e6);
        CfdEnginePlanTypes.LiquidationDelta memory liquidation =
            CfdEnginePlanLib.planLiquidation(withCarryAndBounty, ENTRY_PRICE, 1);
        assertTrue(liquidation.liquidatable);
        assertEq(
            liquidation.riskState.equityUsdc,
            baselineDelta.riskState.equityUsdc,
            "Unfunded carry is an independent delinquency and must not alter exact P+C price equity"
        );
        assertEq(liquidation.vpiRebateReserveConsumedUsdc, 10e6);
        assertEq(liquidation.actionReserveConsumedUsdc, 0, "Generic collection must not consume a queued bounty");
        assertEq(liquidation.actionChargeWaivedUsdc, 11e6);
    }

    function test_LiquidationRejectsUnderfundedVpiReserve() public {
        CfdEnginePlanTypes.RawSnapshot memory snap = _positionSnapshot(9e6, 0, 11e6);
        vm.expectRevert(CfdEnginePlanLib.CfdEnginePlanLib__VpiRebateReserveUnderfunded.selector);
        this.planLiquidationExternal(snap, ENTRY_PRICE);
    }

    function test_OverfundedVpiReserveDoesNotImproveExactPriceHealth() public pure {
        CfdEnginePlanTypes.RawSnapshot memory exactlyFunded = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.RawSnapshot memory overfunded = _positionSnapshot(100e6, 0, 0);

        CfdEnginePlanTypes.LiquidationDelta memory exactDelta =
            CfdEnginePlanLib.planLiquidation(exactlyFunded, 102_000_000, 1);
        CfdEnginePlanTypes.LiquidationDelta memory overfundedDelta =
            CfdEnginePlanLib.planLiquidation(overfunded, 102_000_000, 1);

        assertTrue(exactDelta.liquidatable, "setup must breach exact P+C price health");
        assertTrue(overfundedDelta.liquidatable, "excess VPI reserve must not cure price insolvency");
        assertEq(overfundedDelta.riskState.equityUsdc, exactDelta.riskState.equityUsdc);
        assertEq(overfundedDelta.riskState.maintenanceMarginUsdc, exactDelta.riskState.maintenanceMarginUsdc);
    }

}
