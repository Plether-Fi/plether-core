// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterReservationsTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_IncreaseOrder_DoesNotUsePnlPledgeToPayTradeCost() public {
        _startRecordingLogs();
        address trader = address(0xC444);
        address account = trader;
        uint256 sizeDelta = 3400e18;
        uint256 marginDelta = 110e6;
        uint256 executionBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(sizeDelta);

        _fundTrader(trader, marginDelta + executionBountyUsdc);
        _open(account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8);

        assertEq(
            _freeSettlementUsdc(account),
            executionBountyUsdc,
            "setup must leave only the future execution bounty as free settlement"
        );

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, sizeDelta, 0, 1e8, false);

        assertLt(
            _freeSettlementUsdc(account),
            executionBountyUsdc,
            "commit should materially reduce the only free settlement while reserving the execution bounty"
        );

        uint256 keeperBefore = clearinghouse.balanceUsdc(address(this));
        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(
            size,
            sizeDelta,
            "increase should fail rather than consume existing PnL pledge when free settlement is exhausted"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            executionBountyUsdc,
            "keeper should receive the reserved execution bounty as clearinghouse credit after terminal failure"
        );
        assertEq(
            uint256(OrderRouterDebugLens.loadRawOrderRecord(vm, router, 1).status),
            uint256(IOrderRouterAccounting.OrderStatus.None),
            "terminal order should be deleted from Router storage"
        );
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 1);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(
            uint8(outcome.reason),
            uint8(OrderV3Types.TerminalReason.PlannerRejected),
            "increase without action-cost backing should finalize as a typed planner rejection"
        );
    }

    function test_MultiPendingOrders_DoNotCorruptLockedMarginOnFail() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 500 * 1e6, 2e8, false);
        vm.stopPrank();

        assertEq(
            clearinghouse.lockedMarginUsdc(account),
            1500 * 1e6 + 400_000,
            "Both committed margins and execution bounties should be locked"
        );

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (, uint256 posMargin,,,,,) = engine.positions(account);
        IMarginClearinghouse.PnlIsolationBuckets memory afterFirstOrderBuckets =
            clearinghouse.getPnlIsolationBuckets(account);
        assertEq(
            afterFirstOrderBuckets.pnlPledgeUsdc,
            posMargin,
            "Position tuple and canonical PnL-pledge bucket should agree"
        );
        assertEq(afterFirstOrderBuckets.orderMarginUsdc, 500 * 1e6, "Order 2 committed margin should remain isolated");
        assertEq(
            afterFirstOrderBuckets.actionReserveUsdc, 200_000, "Only order 2 execution bounty should remain reserved"
        );
        assertEq(
            clearinghouse.lockedMarginUsdc(account),
            posMargin + afterFirstOrderBuckets.liquidationReserveUsdc + 500 * 1e6 + 200_000,
            "Typed locks should preserve order 2 margin and the liquidation reserve"
        );
        assertEq(_remainingCommittedMargin(1), 0, "Order 1 committed margin must be cleared on success");

        vm.roll(10);
        router.executeOrder(2, empty);

        (, uint256 posMarginAfter,,,,,) = engine.positions(account);
        IMarginClearinghouse.PnlIsolationBuckets memory afterFailedOrderBuckets =
            clearinghouse.getPnlIsolationBuckets(account);
        assertEq(
            clearinghouse.lockedMarginUsdc(account),
            posMarginAfter + afterFailedOrderBuckets.liquidationReserveUsdc,
            "Failed order 2 should unlock only order margin and action reserve"
        );
        assertEq(afterFailedOrderBuckets.orderMarginUsdc, 0);
        assertEq(afterFailedOrderBuckets.actionReserveUsdc, 0);
        assertEq(_remainingCommittedMargin(2), 0, "Order 2 committed margin must be cleared on failure");
    }

    function test_AccountReservationView_TracksPendingOrders() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(
            reservation.committedMarginUsdc,
            1500 * 1e6,
            "Reservation view should sum committed margin across pending opens"
        );
        assertEq(
            reservation.executionBountyUsdc, 400_000, "Open and close orders should both reservation execution bounties"
        );
        assertEq(reservation.pendingOrderCount, 2, "Reservation view should count queued orders");
    }

    function test_GetPendingOrdersAndReservation_ReturnAggregateOrderState() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(account);
        assertEq(reservation.pendingOrderCount, 2);
        assertEq(reservation.committedMarginUsdc, 1500 * 1e6);
        assertEq(reservation.executionBountyUsdc, 400_000);
        assertEq(pending.length, 2);
        assertFalse(pending[1].isClose);
    }

    function test_CloseCommit_ReservesPrefundedKeeperBounty() public {
        _startRecordingLogs();
        address trader = address(0x333);
        address account = trader;

        _fundTrader(trader, 1001e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 1000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);

        assertEq(_executionBountyReserve(1), 200_000, "Close orders should pre-seize the flat router bounty");
    }

    function test_ReserveCloseOrderExecutionBounty_RejectsUnhealthyExposedPosition() public {
        _startRecordingLogs();
        address trader = address(0x336);
        address account = trader;
        address counterparty = address(0x337);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 50_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        engine.reserveCloseOrderExecutionBounty(account, 25_000e18, 1e6);
    }

    function test_EligibleSmallRemainderCanReserveBountyFromPledge() public {
        _startRecordingLogs();
        address trader = address(0x338);
        address account = trader;
        address counterparty = address(0x339);
        address counterpartyAccount = counterparty;

        uint256 depth = 5_000_000 * 1e6;
        _fundTrader(trader, 50_000e6);
        _fundTrader(counterparty, 500_000e6);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 500_000e18, 50_000e6, 1e8, depth);

        uint256 positionSize = 1100e18;
        uint256 partialCloseSize = 1000e18;
        _open(account, CfdTypes.Side.LONG, positionSize, 50_000e6, 1e8, depth);

        (, uint256 marginBeforeCommit,,,,,) = engine.positions(account);
        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, partialCloseSize, 0, 0, true);

        (, uint256 marginAfterCommit,,,,,) = engine.positions(account);
        assertEq(
            marginAfterCommit,
            marginBeforeCommit - router.closeOrderExecutionBountyUsdc(),
            "bounty reclassification is exact"
        );
        assertEq(router.pendingOrderCounts(account), 1, "eligible reduction enters queue");
        assertEq(router.nextCommitId(), 2, "eligible reduction consumes one ID");
    }

    function test_MarginQueue_CloseIntentBehindPendingOpenIsRejected() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 1e8, true);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        assertEq(
            router.marginHeadOrderId(account), 1, "Margin queue head should start at the first positive-margin order"
        );
        assertEq(router.marginTailOrderId(account), 2, "Margin queue tail should end at the last positive-margin order");
        assertTrue(_isInMarginQueue(1), "Positive-margin open should be linked into the margin queue");
        assertTrue(_isInMarginQueue(2), "Later positive-margin open should be linked into the margin queue");
    }

    function test_NoteCommittedMarginConsumed_PartialConsumePreservesMarginQueueMembership() public {
        _startRecordingLogs();
        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        // Exhaust free settlement so the live action charge reaches exactly the intended order margin.
        uint256 freeSettlement = clearinghouse.getFreeBuyingPowerUsdc(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlement);
        vm.prank(address(engine));
        clearinghouse.consumeActionCharge(account, 400 * 1e6, 0, 400 * 1e6, address(engine), address(0), 0);

        assertEq(_remainingCommittedMargin(1), 600 * 1e6, "Partial consumption should leave residual committed margin");
        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            600 * 1e6,
            "Reservation residual should match router-side committed margin residual"
        );
        assertEq(router.marginHeadOrderId(account), 1, "Partially consumed order should remain at margin-queue head");
        assertEq(router.marginTailOrderId(account), 1, "Single residual order should remain at margin-queue tail");
        assertTrue(_isInMarginQueue(1), "Partially consumed order should remain linked in the margin queue");
    }

    function test_NoteCommittedMarginConsumed_DrainsHeadExposureWithRejectedCloseIntent() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 1e8, true);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        // Exhaust free settlement so the live action charge reaches exactly the intended order margin.
        uint256 freeSettlement = clearinghouse.getFreeBuyingPowerUsdc(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlement);
        vm.prank(address(engine));
        clearinghouse.consumeActionCharge(account, 1000 * 1e6, 0, 1000 * 1e6, address(engine), address(0), 0);

        assertEq(_remainingCommittedMargin(1), 0, "First margin-paying order should be fully drained");
        assertEq(
            _remainingCommittedMargin(2), 250 * 1e6, "Later positive-margin order should retain its committed margin"
        );
        assertEq(
            router.marginHeadOrderId(account),
            2,
            "Account margin head should advance once zero-remaining reservations are pruned"
        );
        assertEq(
            router.marginTailOrderId(account),
            2,
            "Margin queue tail should still point at the trailing positive-margin order"
        );
        assertFalse(
            _isInMarginQueue(1), "Drained order should be pruned from the margin queue once reservations are consumed"
        );
        assertTrue(_isInMarginQueue(2), "Residual positive-margin order should remain in the margin queue");
        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            0,
            "First reservation should be fully consumed alongside router head exposure"
        );
        assertEq(
            clearinghouse.getOrderReservation(2).remainingAmountUsdc,
            250 * 1e6,
            "Later reservation should retain its committed margin"
        );
    }

    function test_ConsumePnlPledgeLoss_DoesNotConsumeCommittedOrderMargin() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = _freeSettlementUsdc(account);
        vm.prank(alice);
        clearinghouse.withdraw(account, freeSettlement);

        IMarginClearinghouse.LockedMarginBuckets memory beforeBuckets = clearinghouse.getLockedMarginBuckets(account);
        assertEq(beforeBuckets.committedOrderMarginUsdc, 500 * 1e6, "Setup must lock both committed-order buckets");

        vm.prank(address(engine));
        (uint256 seizedUsdc, uint256 shortfallUsdc) =
            clearinghouse.consumePnlPledgeLoss(account, 300 * 1e6, address(engine));

        assertEq(seizedUsdc, 0, "Price loss cannot seize committed-order margin");
        assertEq(shortfallUsdc, 300 * 1e6, "Loss without a PnL pledge should remain uncovered");
        assertEq(_remainingCommittedMargin(1), 250 * 1e6, "First order margin should remain isolated");
        assertEq(_remainingCommittedMargin(2), 250 * 1e6, "Second order margin should remain isolated");

        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);
        router.executeOrder(2, empty);

        IMarginClearinghouse.LockedMarginBuckets memory afterBuckets = clearinghouse.getLockedMarginBuckets(account);
        IMarginClearinghouse.OrderReservation memory firstReservation = clearinghouse.getOrderReservation(1);
        IMarginClearinghouse.OrderReservation memory secondReservation = clearinghouse.getOrderReservation(2);
        assertEq(
            afterBuckets.committedOrderMarginUsdc,
            0,
            "Normal order finalization should release both committed-order buckets"
        );
        assertEq(_remainingCommittedMargin(1), 0, "First order committed margin should stay zero after release");
        assertEq(_remainingCommittedMargin(2), 0, "Second order committed margin should release on finalization");
        assertEq(uint256(firstReservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(uint256(secondReservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
    }

    function test_CommitOrder_DualWritesReservationAndRouterCommittedMarginState() public {
        _startRecordingLogs();
        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 250 * 1e6, 1e8, false);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(1);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(account);

        assertEq(
            _remainingCommittedMargin(1), 250 * 1e6, "Router should still track the per-order committed margin locally"
        );
        assertEq(
            reservation.remainingAmountUsdc,
            250 * 1e6,
            "Clearinghouse reservation should mirror the router committed margin"
        );
        assertEq(
            summary.activeCommittedOrderMarginUsdc,
            250 * 1e6,
            "Reservation summary should match the live committed-order bucket"
        );
        assertEq(
            summary.activeReservationCount,
            1,
            "Exactly one active reservation should exist after a single open-order commit"
        );
    }

    function test_ReleaseCommittedMargin_NoopsWhenReservationAlreadyConsumed() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = _freeSettlementUsdc(account);
        vm.prank(alice);
        clearinghouse.withdraw(account, freeSettlement);

        vm.prank(address(engine));
        clearinghouse.consumeActionCharge(account, 300 * 1e6, 0, 300 * 1e6, address(engine), address(0), 0);
        assertEq(clearinghouse.getOrderReservation(1).remainingAmountUsdc, 0);
        assertEq(clearinghouse.getOrderReservation(2).remainingAmountUsdc, 200 * 1e6);

        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            0,
            "Consumed reservation should remain zero after execution cleanup"
        );
    }

    function test_ExecuteOrder_UnlinksMarginQueueHeadAndPreservesResidualTail() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            router.marginHeadOrderId(account),
            2,
            "Executing the margin-queue head should advance to the surviving residual order"
        );
        assertEq(
            router.marginTailOrderId(account),
            2,
            "Executing the margin-queue head should leave the residual order as tail"
        );
        assertFalse(_isInMarginQueue(1), "Executed order should be removed from the margin queue");
        assertTrue(_isInMarginQueue(2), "Residual positive-margin order should remain linked");
    }

}
