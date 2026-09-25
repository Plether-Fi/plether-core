// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "./CfdClosePreviewTestBase.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Current-source equivalents of the handoff's bucket-allocation patterns, not historical transaction replays.
contract FullCloseActionChargeTest is CfdClosePreviewTestBase {

    bytes32 private constant ACTION_SETTLED = keccak256("ActionChargeSettled(address,uint256,uint256,uint256)");

    function test_FullClose_ProfitSmallerThanChargeUsesReleasedSurplus() public {
        _routerClose(99_990_000);
    }

    function test_FullClose_LossUsesReleasedSurplus() public {
        _routerClose(101_000_000);
    }

    function test_FullClose_FlatUsesReleasedSurplus() public {
        _routerClose(PRICE);
    }

    function test_RouterFullClose_PreservesPendingOpenMarginAndItsBounty() public {
        _openNormally(CfdTypes.Side.LONG, 200e6);
        CfdTypes.Order memory order = _order(CfdTypes.Side.LONG, SIZE);
        vm.startPrank(ACCOUNT);
        uint64 closeId = router.commitOrder(order.side, order.sizeDelta, 0, order.targetPrice, true);
        uint64 pendingId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, PRICE, false);
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc);
        vm.stopPrank();
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        uint256 protectedBefore = clearinghouse.totalBountyReservationsUsdc(ACCOUNT);
        OrderV2Types.ExecutionAssessment memory assessment = policyEvaluator.assessOrder(
            address(engine), order, KEEPER, PRICE, pool.totalAssets(), uint64(block.timestamp), _bounds(), bounty
        );
        assertEq(assessment.actionChargeCollectedUsdc, assessment.actionChargeAssessedUsdc);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(closeId, update);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        _assertReceipt(logs, closeId, assessment);
        _assertChargeEvent(logs, assessment.actionChargeAssessedUsdc, assessment.actionChargeAssessedUsdc, 0);
        assertEq(clearinghouse.getOrderReservation(pendingId).remainingAmountUsdc, 100e6);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc, 100e6);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), protectedBefore - bounty);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
    }

    function test_FullClose_PendingOrderMarginIsPreservedWhenSurplusSuffices() public {
        _pendingOrderMargin(false);
    }

    function test_FullClose_OnlyResidualChargeConsumesPendingOrdersInFifoOrder() public {
        _pendingOrderMargin(true);
    }

    function _pendingOrderMargin(
        bool exhaustPledge
    ) private {
        _openNormally(CfdTypes.Side.LONG, 200e6);
        vm.startPrank(ACCOUNT);
        uint64 firstId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 20e6, PRICE, false);
        uint64 secondId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, PRICE, false);
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc);
        vm.stopPrank();
        uint256 protectedBounties = clearinghouse.totalBountyReservationsUsdc(ACCOUNT);
        assertGt(protectedBounties, 0);
        uint256 price = exhaustPledge ? 102_500_000 : PRICE;
        if (exhaustPledge) {
            vm.warp(1_709_985_600);
            assertTrue(engine.isOracleFrozen());
        }
        CfdEnginePlanTypes.CloseDelta memory d = _closePlan(price);
        assertTrue(d.valid);
        if (exhaustPledge) {
            assertEq(d.unlockMarginUsdc, 0);
            assertGt(d.actionCommittedMarginConsumedUsdc, 20e6);
            assertLt(d.actionCommittedMarginConsumedUsdc, 120e6);
            assertEq(d.actionCommittedMarginConsumedUsdc, d.actionChargeAssessedUsdc - d.liquidationReserveReleaseUsdc);
        } else {
            assertEq(d.actionCommittedMarginConsumedUsdc, 0);
        }
        // Execute at the engine boundary so the two unrelated router orders stay pending.
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, price);
        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(firstId);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(secondId);
        assertEq(first.remainingAmountUsdc, exhaustPledge ? 0 : 20e6);
        assertEq(second.remainingAmountUsdc, exhaustPledge ? 120e6 - d.actionCommittedMarginConsumedUsdc : 100e6);
        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc,
            120e6 - d.actionCommittedMarginConsumedUsdc
        );
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), protectedBounties);
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), protectedBounties);
        assertEq(d.actionChargeWaivedUsdc, 0);
    }

    function testFuzz_FullClose_WaiverImpliesNoEligibleCashAtEngineBoundary(
        uint32 priceSeed,
        uint64 freeSeed,
        bool frozen
    ) public {
        uint256 price = bound(priceSeed, 99_900_000, 110_000_000);
        _openNormally(CfdTypes.Side.LONG, 200_000 + bound(freeSeed, 0, 20e6));
        vm.prank(ACCOUNT);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 0, type(uint256).max, true);
        uint256 protectedBounty = clearinghouse.totalBountyReservationsUsdc(ACCOUNT);
        if (frozen) {
            vm.warp(1_709_985_600);
        }
        CfdEnginePlanTypes.CloseDelta memory d = _closePlan(price);
        assertTrue(d.valid);
        uint256 balanceBefore = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 poolBefore = pool.totalAssets();
        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.recordLogs();
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, price);
        _assertChargeEvent(
            vm.getRecordedLogs(),
            d.actionChargeAssessedUsdc,
            d.actionChargeWithheldUsdc + d.actionChargeCollectedUsdc,
            d.actionChargeWaivedUsdc
        );
        assertEq(
            d.actionChargeAssessedUsdc,
            d.actionChargeWithheldUsdc + d.actionChargeCollectedUsdc + d.actionChargeWaivedUsdc
        );
        IMarginClearinghouse.AccountUsdcBuckets memory afterBuckets = clearinghouse.getAccountUsdcBuckets(ACCOUNT);
        if (d.actionChargeWaivedUsdc > 0) {
            assertEq(
                afterBuckets.freeSettlementUsdc, 0, "A waiver must exhaust released and pre-existing free settlement"
            );
            assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc, 0);
        }
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), protectedBounty);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), protectedBounty);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(ACCOUNT), 0);
        assertEq(
            afterBuckets.settlementBalanceUsdc,
            balanceBefore - d.realizedCarryUsdc - d.pricePnlPledgeConsumedUsdc - d.actionChargeCollectedUsdc
                + (d.pricePayoutIsImmediate ? d.pricePayoutUsdc : 0) + d.actionRebatePaidUsdc
        );
        uint256 treasuryDelta = clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore;
        assertEq(treasuryDelta, d.actionProtocolFeeCreditedUsdc + d.protocolFeeTopUpUsdc);
        assertEq(pool.totalAssets() + treasuryDelta + afterBuckets.settlementBalanceUsdc, poolBefore + balanceBefore);
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().effectiveSolvencyAssetsUsdc,
            d.solvency.effectiveAssetsAfterUsdc
        );
        assertEq(terminalNavBook.curveHashOf(ACCOUNT), bytes32(0));
    }

    function _closePlan(
        uint256 price
    ) private returns (CfdEnginePlanTypes.CloseDelta memory) {
        address sidecar = address(engine.settlementSidecar());
        uint256 depth = pool.totalAssets();
        vm.prank(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ICfdEngineSettlementSidecar(sidecar).buildRawSnapshot(ACCOUNT, depth);
        // Match the engine's actual frozen-market policy; the raw snapshot already includes current carry.
        return engine.planner().planClose(snap, _order(CfdTypes.Side.LONG, SIZE), price, uint64(block.timestamp));
    }

    function _routerClose(
        uint256 price
    ) private {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        uint256 beforeBalance = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 beforePool = pool.totalAssets();
        uint256 beforeTreasury = clearinghouse.balanceUsdc(engine.protocolTreasury());
        (uint64 id, CfdClosePreview.ClosePreview memory p) =
            _commitParity(_order(CfdTypes.Side.LONG, SIZE), price, KEEPER);
        assertGt(p.assessment.actionChargeCollectedUsdc, 0, "Released surplus must pay residual action charges");
        uint256 assessed = p.assessment.actionChargeAssessedUsdc;
        uint256 gain = p.assessment.realizedPnlUsdc > 0 ? uint256(p.assessment.realizedPnlUsdc) : 0;
        uint256 withheld = gain < assessed ? gain : assessed;
        assertEq(p.assessment.actionChargeCollectedUsdc, assessed - withheld);
        bytes[] memory update = _mockPythUpdateData(price);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        _assertReceipt(logs, id, p.assessment);
        _assertChargeEvent(logs, assessed, assessed, 0);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), p.assessment.postSettlementBalanceUsdc);
        assertEq(
            int256(clearinghouse.balanceUsdc(ACCOUNT)),
            int256(beforeBalance) + p.assessment.realizedPnlUsdc - int256(assessed + p.executionBountyUsdc)
        );
        uint256 treasuryIncrease = clearinghouse.balanceUsdc(engine.protocolTreasury()) - beforeTreasury;
        assertEq(treasuryIncrease, p.assessment.executionFeeUsdc);
        assertEq(
            int256(pool.totalAssets()) - int256(beforePool),
            int256(assessed - treasuryIncrease) - p.assessment.realizedPnlUsdc
        );
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(terminalNavBook.curveHashOf(ACCOUNT), bytes32(0));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 0);
    }

    function _assertChargeEvent(
        Vm.Log[] memory logs,
        uint256 assessed,
        uint256 recovered,
        uint256 waived
    ) private view {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(engine.settlementSidecar()) && logs[i].topics.length == 2
                    && logs[i].topics[0] == ACTION_SETTLED && logs[i].topics[1] == bytes32(uint256(uint160(ACCOUNT)))
            ) {
                (uint256 actualAssessed, uint256 actualRecovered, uint256 actualWaived) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(actualAssessed, assessed);
                assertEq(actualRecovered, recovered);
                assertEq(actualWaived, waived);
                return;
            }
        }
        revert("Missing action charge event");
    }

}
