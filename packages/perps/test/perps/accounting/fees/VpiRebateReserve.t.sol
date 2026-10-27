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
        return CfdEnginePlanLib.planLiquidation(snap, price);
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
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _positionSnapshot(
        uint256 vpiReserveAssets,
        uint256 protectedBountyAssets,
        uint256 pendingCarryAssets
    ) internal pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 size = 1000e18;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostAssetAtoms = lots * ENTRY_PRICE;
        uint256 marginAssets = 20e6;
        uint256 liquidationReserveAssets = 1e6;
        uint256 actionReserveAssets = vpiReserveAssets + protectedBountyAssets;
        uint256 settlementBalanceAssets = marginAssets + liquidationReserveAssets + actionReserveAssets;
        uint256 maxProfitAssets =
            CfdMath.calculateExactMaxProfit(lots, entryCostAssetAtoms, CfdTypes.Side.LONG, CAP_PRICE);

        snap.account = address(0xBEEF);
        snap.position = CfdTypes.Position({
            size: size,
            margin: marginAssets,
            entryPrice: ENTRY_PRICE,
            maxProfitAssets: maxProfitAssets,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 1,
            lastCarryTimestamp: 1,
            vpiAccrued: -10e6
        });
        snap.positionEntryCostAssetAtoms = entryCostAssetAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = ENTRY_PRICE;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: maxProfitAssets,
            openInterest: size,
            entryNotional: entryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE,
            totalMargin: marginAssets,
            borrowBaseAssets: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: 0, openInterest: 0, entryNotional: 0, totalMargin: 0, borrowBaseAssets: 0, carryIndex: 0
        });
        snap.poolAssets = 1_000_000e6;
        snap.poolCashAssets = 1_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: settlementBalanceAssets,
            totalLockedMarginAssets: settlementBalanceAssets,
            activePositionMarginAssets: marginAssets,
            otherLockedMarginAssets: liquidationReserveAssets + actionReserveAssets,
            freeSettlementAssets: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginAssets: marginAssets,
            committedOrderMarginAssets: 0,
            reservedSettlementAssets: actionReserveAssets,
            totalLockedMarginAssets: settlementBalanceAssets
        });
        snap.liquidationReserveAssets = liquidationReserveAssets;
        snap.actionReserveAssets = actionReserveAssets;
        snap.vpiRebateReserveAssets = vpiReserveAssets;
        snap.protectedExecutionBountyAssets = protectedBountyAssets;
        snap.unsettledCarryAssets = pendingCarryAssets;
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
            CfdEnginePlanLib.planClose(snap, _closeOrder(snap.account, 500e18), ENTRY_PRICE);

        assertTrue(delta.valid);
        assertEq(delta.vpiRebateReserveBeforeAssets, 10e6);
        assertEq(delta.vpiRebateReserveAfterAssets, 5e6);
        assertEq(delta.vpiRebateReserveConsumedAssets, 5e6);
        assertEq(delta.actionChargeAssessedAssets, 5e6);
        assertEq(delta.actionChargeCollectedAssets, 5e6);
        assertEq(delta.actionChargeWaivedAssets, 0);
        assertEq(snap.position.vpiAccrued - delta.posVpiAccruedReduction, -5e6);
    }

    function test_PriceGainWithholdingHasPriorityAndReleasesUnusedReserve() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.CloseDelta memory delta =
            CfdEnginePlanLib.planClose(snap, _closeOrder(snap.account, snap.position.size), 99_000_000);

        assertTrue(delta.valid);
        assertEq(delta.priceGainAssets, 10e6);
        assertEq(delta.actionChargeWithheldAssets, 10e6);
        assertEq(delta.vpiRebateReserveConsumedAssets, 0);
        assertEq(delta.vpiRebateReserveAfterAssets, 0);
        assertEq(delta.actionChargeCollectedAssets, 0);
        assertEq(delta.pricePayoutAssets, 0);
    }

    function test_PositiveVpiOpenReleasesBackingBeforeCharging() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 size = 100_000e18;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostAssetAtoms = lots * ENTRY_PRICE;
        uint256 marginAssets = 20_000e6;
        uint256 orderMarginAssets = 5000e6;
        uint256 liquidationReserveAssets = 100e6;
        uint256 vpiReserveAssets = 10e6;
        uint256 totalLockedAssets = marginAssets + liquidationReserveAssets + vpiReserveAssets;
        uint256 settlementBalanceAssets = totalLockedAssets + orderMarginAssets;
        uint256 maxProfitAssets =
            CfdMath.calculateExactMaxProfit(lots, entryCostAssetAtoms, CfdTypes.Side.LONG, CAP_PRICE);

        snap.account = address(0xCAFE);
        snap.position = CfdTypes.Position({
            size: size,
            margin: marginAssets,
            entryPrice: ENTRY_PRICE,
            maxProfitAssets: maxProfitAssets,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 1,
            lastCarryTimestamp: 1,
            vpiAccrued: -10e6
        });
        snap.positionEntryCostAssetAtoms = entryCostAssetAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = ENTRY_PRICE;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: maxProfitAssets,
            openInterest: size,
            entryNotional: entryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE,
            totalMargin: marginAssets,
            borrowBaseAssets: 0,
            carryIndex: 0
        });
        snap.poolAssets = 1_000_000e6;
        snap.poolCashAssets = 1_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: settlementBalanceAssets,
            totalLockedMarginAssets: totalLockedAssets,
            activePositionMarginAssets: marginAssets,
            otherLockedMarginAssets: liquidationReserveAssets + vpiReserveAssets,
            freeSettlementAssets: orderMarginAssets
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginAssets: marginAssets,
            committedOrderMarginAssets: 0,
            reservedSettlementAssets: vpiReserveAssets,
            totalLockedMarginAssets: totalLockedAssets
        });
        snap.liquidationReserveAssets = liquidationReserveAssets;
        snap.actionReserveAssets = vpiReserveAssets;
        snap.vpiRebateReserveAssets = vpiReserveAssets;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams(0.005e18);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: snap.account,
            sizeDelta: 10_000e18,
            marginDelta: orderMarginAssets,
            targetPrice: ENTRY_PRICE,
            commitTime: 1,
            commitBlock: 1,
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, ENTRY_PRICE);

        assertTrue(delta.valid);
        assertEq(delta.openState.vpiAssets, 5_250_000);
        assertEq(delta.tradeCostAssets, 5_250_000);
        assertEq(delta.vpiRebateReserveBeforeAssets, 10e6);
        assertEq(delta.vpiRebateReserveAfterAssets, 4_750_000);
        assertEq(delta.vpiRebateReserveFromPledgeAssets, 0);
        assertEq(delta.positionMarginAfterOpen, 24_984_750_000);
    }

    function test_GrossRebateBackingIncludesFeeOffset() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        // Leave one micro-settlement token above initial margin after funding the rebate and liquidation reserves.
        uint256 marginAssets = 4920e6 + 1;
        snap.account = address(0xD00D);
        snap.position.side = CfdTypes.Side.SHORT;
        snap.longSide.openInterest = 300_000e18;
        snap.longSide.entryNotional = 300_000e6 * CfdMath.ASSETS_TO_TOKEN_SCALE;
        snap.poolAssets = 2_000_000e6;
        snap.poolCashAssets = 2_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: marginAssets,
            totalLockedMarginAssets: 0,
            activePositionMarginAssets: 0,
            otherLockedMarginAssets: 0,
            freeSettlementAssets: marginAssets
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams(0.05e18);
        snap.executionFeeBps = 4;

        CfdTypes.Order memory order = CfdTypes.Order({
            account: snap.account,
            sizeDelta: 300_000e18,
            marginDelta: marginAssets,
            targetPrice: ENTRY_PRICE,
            commitTime: 1,
            commitBlock: 1,
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, ENTRY_PRICE);

        assertTrue(delta.valid);
        assertEq(delta.openState.vpiAssets, -int256(1125e6));
        assertEq(delta.executionFeeAssets, 120e6);
        assertEq(delta.poolRebatePayoutAssets, 1005e6);
        assertEq(delta.vpiRebateReserveAfterAssets, 1125e6);
        assertEq(delta.vpiRebateReserveFromPledgeAssets, 120e6);
        assertEq(delta.positionMarginAfterOpen, 4500e6 + 1);
    }

    function test_LiquidationCancelsFundedVpiOnceAndProtectsBounty() public pure {
        CfdEnginePlanTypes.RawSnapshot memory baseline = _positionSnapshot(0, 0, 0);
        baseline.position.vpiAccrued = 0;
        baseline.actionReserveAssets = 0;
        baseline.accountBuckets.settlementBalanceAssets = 21e6;
        baseline.accountBuckets.otherLockedMarginAssets = 1e6;
        baseline.accountBuckets.totalLockedMarginAssets = 21e6;
        baseline.lockedBuckets.reservedSettlementAssets = 0;
        baseline.lockedBuckets.totalLockedMarginAssets = 21e6;

        CfdEnginePlanTypes.LiquidationDelta memory baselineDelta =
            CfdEnginePlanLib.planLiquidation(baseline, ENTRY_PRICE);
        assertFalse(baselineDelta.liquidatable);
        assertEq(baselineDelta.riskState.equityAssets, 20e6);

        CfdEnginePlanTypes.RawSnapshot memory funded = _positionSnapshot(10e6, 0, 0);
        CfdEnginePlanTypes.LiquidationDelta memory fundedDelta = CfdEnginePlanLib.planLiquidation(funded, ENTRY_PRICE);
        assertFalse(fundedDelta.liquidatable);
        assertEq(
            fundedDelta.riskState.equityAssets,
            baselineDelta.riskState.equityAssets,
            "Funded reserve and matching VPI clawback must cancel exactly once"
        );

        CfdEnginePlanTypes.RawSnapshot memory withCarryAndBounty = _positionSnapshot(10e6, 3e6, 11e6);
        CfdEnginePlanTypes.LiquidationDelta memory liquidation =
            CfdEnginePlanLib.planLiquidation(withCarryAndBounty, ENTRY_PRICE);
        assertTrue(liquidation.liquidatable);
        assertEq(
            liquidation.riskState.equityAssets,
            baselineDelta.riskState.equityAssets - 11e6,
            "Margin-funded carry reduces price equity while preserving VPI and bounty reserves"
        );
        assertEq(liquidation.vpiRebateReserveConsumedAssets, 10e6);
        assertEq(liquidation.actionReserveConsumedAssets, 0, "Generic collection must not consume a queued bounty");
        assertEq(liquidation.realizedCarryAssets, 11e6);
        assertEq(liquidation.actionChargeWaivedAssets, 0);
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
            CfdEnginePlanLib.planLiquidation(exactlyFunded, 102_000_000);
        CfdEnginePlanTypes.LiquidationDelta memory overfundedDelta =
            CfdEnginePlanLib.planLiquidation(overfunded, 102_000_000);

        assertTrue(exactDelta.liquidatable, "setup must breach exact P+C price health");
        assertTrue(overfundedDelta.liquidatable, "excess VPI reserve must not cure price insolvency");
        assertEq(overfundedDelta.riskState.equityAssets, exactDelta.riskState.equityAssets);
        assertEq(overfundedDelta.riskState.maintenanceMarginAssets, exactDelta.riskState.maintenanceMarginAssets);
    }

}
