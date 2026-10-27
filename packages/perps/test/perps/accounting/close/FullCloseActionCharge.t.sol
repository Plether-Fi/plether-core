// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "../../CfdClosePreviewTestBase.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
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
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets);
        vm.stopPrank();
        uint256 bounty = 0;
        uint256 protectedBefore = clearinghouse.totalBountyReservationsAssets(ACCOUNT);
        OrderV3Types.ExecutionAssessment memory assessment =
            policyEvaluator.assessCommittedOrder(address(engine), closeId, KEEPER, PRICE);
        assertEq(assessment.actionChargeCollectedAssets, assessment.actionChargeAssessedAssets);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(closeId, update);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(logs, closeId, assessment);
        _assertChargeEvent(logs, assessment.actionChargeAssessedAssets, assessment.actionChargeAssessedAssets, 0);
        assertEq(clearinghouse.getOrderReservation(pendingId).remainingAmountAssets, 100e6);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginAssets, 100e6);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), protectedBefore - bounty);
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
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets);
        vm.stopPrank();
        uint256 protectedBounties = clearinghouse.totalBountyReservationsAssets(ACCOUNT);
        assertGt(protectedBounties, 0);
        uint256 price = exhaustPledge ? 102_500_000 : PRICE;
        if (exhaustPledge) {
            vm.warp(1_709_985_600);
            assertTrue(engine.isOracleFrozen());
        }
        CfdEnginePlanTypes.CloseDelta memory d = _closePlan(price);
        assertTrue(d.valid);
        if (exhaustPledge) {
            assertEq(d.unlockMarginAssets, 0);
            assertGt(d.actionCommittedMarginConsumedAssets, 20e6);
            assertLt(d.actionCommittedMarginConsumedAssets, 120e6);
            assertEq(
                d.actionCommittedMarginConsumedAssets, d.actionChargeAssessedAssets - d.liquidationReserveReleaseAssets
            );
        } else {
            assertEq(d.actionCommittedMarginConsumedAssets, 0);
        }
        // Execute at the engine boundary so the two unrelated router orders stay pending.
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, price);
        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(firstId);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(secondId);
        assertEq(first.remainingAmountAssets, exhaustPledge ? 0 : 20e6);
        assertEq(second.remainingAmountAssets, exhaustPledge ? 120e6 - d.actionCommittedMarginConsumedAssets : 100e6);
        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginAssets,
            120e6 - d.actionCommittedMarginConsumedAssets
        );
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), protectedBounties);
        assertEq(clearinghouse.actionReserveAssets(ACCOUNT), protectedBounties);
        assertEq(d.actionChargeWaivedAssets, 0);
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
        uint256 protectedBounty = clearinghouse.totalBountyReservationsAssets(ACCOUNT);
        if (frozen) {
            vm.warp(1_709_985_600);
        }
        CfdEnginePlanTypes.CloseDelta memory d = _closePlan(price);
        assertTrue(d.valid);
        uint256 balanceBefore = clearinghouse.balanceAssets(ACCOUNT);
        uint256 poolBefore = pool.totalAssets();
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        vm.recordLogs();
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, price);
        _assertChargeEvent(
            vm.getRecordedLogs(),
            d.actionChargeAssessedAssets,
            d.actionChargeWithheldAssets + d.actionChargeCollectedAssets,
            d.actionChargeWaivedAssets
        );
        assertEq(
            d.actionChargeAssessedAssets,
            d.actionChargeWithheldAssets + d.actionChargeCollectedAssets + d.actionChargeWaivedAssets
        );
        IMarginClearinghouse.AccountAssetBuckets memory afterBuckets = clearinghouse.getAccountAssetBuckets(ACCOUNT);
        if (d.actionChargeWaivedAssets > 0) {
            assertEq(
                afterBuckets.freeSettlementAssets, 0, "A waiver must exhaust released and pre-existing free settlement"
            );
            assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginAssets, 0);
        }
        assertEq(clearinghouse.actionReserveAssets(ACCOUNT), protectedBounty);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), protectedBounty);
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveAssets(ACCOUNT), 0);
        assertEq(
            afterBuckets.settlementBalanceAssets,
            balanceBefore - d.realizedCarryAssets - d.pricePnlPledgeConsumedAssets - d.actionChargeCollectedAssets
                + (d.pricePayoutIsImmediate ? d.pricePayoutAssets : 0) + d.actionRebatePaidAssets
        );
        uint256 treasuryDelta = clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore;
        assertEq(treasuryDelta, d.actionProtocolFeeCreditedAssets + d.protocolFeeTopUpAssets);
        assertEq(pool.totalAssets() + treasuryDelta + afterBuckets.settlementBalanceAssets, poolBefore + balanceBefore);
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().effectiveSolvencyAssets,
            d.solvency.effectiveAssetsAfterAssets
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
        return engine.planner().planClose(snap, _order(CfdTypes.Side.LONG, SIZE), price);
    }

    function _routerClose(
        uint256 price
    ) private {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        uint256 beforeBalance = clearinghouse.balanceAssets(ACCOUNT);
        uint256 beforePool = pool.totalAssets();
        uint256 beforeTreasury = clearinghouse.balanceAssets(engine.protocolTreasury());
        (uint64 id, CfdClosePreview.ClosePreview memory p) =
            _commitParity(_order(CfdTypes.Side.LONG, SIZE), price, KEEPER);
        assertGt(p.assessment.actionChargeCollectedAssets, 0, "Released surplus must pay residual action charges");
        uint256 assessed = p.assessment.actionChargeAssessedAssets;
        uint256 gain = p.assessment.realizedPnlAssets > 0 ? uint256(p.assessment.realizedPnlAssets) : 0;
        uint256 withheld = gain < assessed ? gain : assessed;
        assertEq(p.assessment.actionChargeCollectedAssets, assessed - withheld);
        bytes[] memory update = _mockPythUpdateData(price);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(logs, id, p.assessment);
        _assertChargeEvent(logs, assessed, assessed, 0);
        assertEq(clearinghouse.balanceAssets(ACCOUNT), p.assessment.postSettlementBalanceAssets);
        assertEq(
            int256(clearinghouse.balanceAssets(ACCOUNT)),
            int256(beforeBalance) + p.assessment.realizedPnlAssets - int256(assessed)
        );
        uint256 treasuryIncrease = clearinghouse.balanceAssets(engine.protocolTreasury()) - beforeTreasury;
        assertEq(treasuryIncrease, p.assessment.executionFeeAssets);
        assertEq(
            int256(pool.totalAssets()) - int256(beforePool),
            int256(assessed - treasuryIncrease) - p.assessment.realizedPnlAssets
        );
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveAssets(ACCOUNT), 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
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
