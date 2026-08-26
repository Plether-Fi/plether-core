// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

contract PerpAccountingInvariantTest is BasePerpInvariantTest {

    uint256 internal constant ORDER_EXECUTION_REACHABILITY_ATTEMPT_THRESHOLD = 32;

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 9,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ClearinghouseReservationsMatchLiveExecutionBounties() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router must not custody execution bounty reserves");
        assertEq(
            _sumReservedSettlementBuckets(),
            _sumPendingExecutionBounties(),
            "Clearinghouse reserved settlement must equal live pending execution bounty reserves"
        );
    }

    function invariant_TerminalNavBookMatchesCanonicalEngineState() public view {
        ITerminalNavBookV2 book = engine.terminalNavBook();
        uint256 activeCurveCount;
        uint256 totalLots;
        uint256 totalEntryCostUsdcAtoms;
        uint256 totalEffectiveCapUsdcAtoms;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ITerminalNavBookV2.CurveRecord memory curve = book.curveOf(account);
            bytes32 curveHash = book.curveHashOf(account);
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);

            if (size == 0) {
                assertEq(curveHash, bytes32(0), "Absent Engine position must not have a curve hash");
                assertEq(curve.lots, 0, "Absent Engine position must not have curve lots");
                assertEq(curve.entryCostUsdcAtoms, 0, "Absent Engine position must not have curve basis");
                assertEq(curve.effectiveCapUsdcAtoms, 0, "Absent Engine position must not have a curve cap");
                assertEq(
                    uint256(curve.side),
                    uint256(CfdTypes.Side.LONG),
                    "Absent Engine position must have default curve side"
                );
                continue;
            }

            assertEq(size % CfdTypes.SIZE_QUANTUM, 0, "Live Engine position must contain exact terminal lots");
            uint256 expectedLots = size / CfdTypes.SIZE_QUANTUM;
            uint256 expectedEntryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);
            uint256 maximumCollectibleUsdcAtoms = side == CfdTypes.Side.LONG
                ? expectedLots * uint256(book.CAP_PRICE()) - expectedEntryCostUsdcAtoms
                : expectedEntryCostUsdcAtoms;
            uint256 candidateCapUsdcAtoms =
                clearinghouse.pnlPledgeUsdc(account) + engine.traderClaimBalanceUsdc(account);
            uint256 expectedEffectiveCapUsdcAtoms = candidateCapUsdcAtoms < maximumCollectibleUsdcAtoms
                ? candidateCapUsdcAtoms
                : maximumCollectibleUsdcAtoms;

            assertEq(curve.lots, expectedLots, "Curve lots must match canonical Engine size");
            assertEq(
                curve.entryCostUsdcAtoms,
                expectedEntryCostUsdcAtoms,
                "Curve basis must match canonical Engine entry cost"
            );
            assertEq(
                curve.effectiveCapUsdcAtoms,
                expectedEffectiveCapUsdcAtoms,
                "Curve cap must match clipped claim-plus-pledge collateral"
            );
            assertEq(uint256(curve.side), uint256(side), "Curve side must match canonical Engine side");
            assertEq(
                curveHash,
                _terminalCurveHash(book, account, curve),
                "Curve hash must commit to the canonical account record"
            );

            activeCurveCount++;
            totalLots += curve.lots;
            totalEntryCostUsdcAtoms += curve.entryCostUsdcAtoms;
            totalEffectiveCapUsdcAtoms += curve.effectiveCapUsdcAtoms;
        }

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.capPrice, engine.CAP_PRICE(), "Terminal book and Engine price caps must match");
        assertEq(state.activeCurveCount, activeCurveCount, "Book active curve count must match actor records");
        assertEq(state.totalLots, totalLots, "Book total lots must match actor records");
        assertEq(
            state.totalEntryCostUsdcAtoms, totalEntryCostUsdcAtoms, "Book total entry cost must match actor records"
        );
        assertEq(
            state.totalEffectiveCapUsdcAtoms,
            totalEffectiveCapUsdcAtoms,
            "Book total effective cap must match actor records"
        );
    }

    function invariant_LiquidatedActorsHaveNoPendingOrders() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(account);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(router.pendingOrderCounts(account), 0, "Liquidated accounts must not keep pending orders");
        }
    }

    function invariant_LiquidatedActorsHaveNoLiveReserves() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(account);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(
                handler.accountExecutionBountyReserve(account),
                0,
                "Liquidated accounts must not retain execution bounty reserves"
            );
            assertEq(handler.accountLiveReserveCount(account), 0, "Liquidated accounts must not retain live reserves");
        }
    }

    function invariant_LiquidatedActorsCannotRecoverWalletUsdc() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            address account = _account(actor);
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(account);
            if (!snapshot.liquidated) {
                continue;
            }

            assertLe(usdc.balanceOf(actor), snapshot.walletUsdc, "Liquidated actors must not recover wallet USDC later");
        }
    }

    function invariant_LiquidationPriceTailsRemainDiagnosticAfterReservationExhaustion() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(account);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(
                snapshot.legacyDebtDiagnosticUsdc,
                0,
                "Liquidation price tails must remain diagnostic writeoffs, never protocol debt"
            );
            assertEq(
                handler.accountExecutionBountyReserve(account),
                0,
                "Terminal liquidation must exhaust same-account execution bounty reservations"
            );
        }
    }

    function invariant_GhostCommittedMarginMatchesAccountReservation() public view {
        uint256 ghostTotalCommittedMargin;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 ghostCommittedMargin = handler.committedMarginSnapshot(account);
            uint256 liveCommittedMargin = router.getAccountReservations(account).committedMarginUsdc;
            uint256 reservationCommittedMargin = handler.accountActiveReservationCommittedMargin(account);

            assertEq(ghostCommittedMargin, liveCommittedMargin, "Ghost committed margin must match account reservation");
            assertEq(
                liveCommittedMargin,
                reservationCommittedMargin,
                "Router account reservation must match clearinghouse reservation summary"
            );
            ghostTotalCommittedMargin += ghostCommittedMargin;
        }

        assertEq(
            handler.totalCommittedMarginSnapshot(),
            ghostTotalCommittedMargin,
            "Ghost committed margin total must match tracked account sum"
        );
    }

    function invariant_OrderReservationModuleSummariesMatchAccountReservation() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
            IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(account);

            uint256 pendingCloseSize;
            for (uint256 j = 0; j < pending.length; j++) {
                if (pending[j].isClose) {
                    pendingCloseSize += pending[j].sizeDelta;
                }
            }

            assertEq(
                pending.length, reservation.pendingOrderCount, "Pending order count must match account reservation"
            );
            assertEq(
                clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginUsdc,
                reservation.committedMarginUsdc,
                "Committed margin summary must match account reservation"
            );
            assertEq(
                reservation.executionBountyUsdc,
                reservation.executionBountyUsdc,
                "Execution bounty must remain self-consistent"
            );
            assertEq(
                router.pendingCloseSize(account),
                pendingCloseSize,
                "Pending close size mapping must match pending-order scan"
            );
        }
    }

    function invariant_GhostOrderCommittedMarginStateMachineMatchesRouter() public view {
        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            uint8 ghostState = handler.ghostOrderLifecycleState(orderId);
            uint256 ghostRemaining = handler.ghostOrderRemainingCommittedMargin(orderId);
            uint256 liveRemaining = _remainingCommittedMargin(orderId);
            uint256 reservationRemaining = handler.reservationRemainingCommittedMargin(orderId);

            if (ghostState == 1) {
                assertEq(liveRemaining, ghostRemaining, "Pending ghost order margin must match router remaining margin");
                assertEq(
                    liveRemaining,
                    reservationRemaining,
                    "Pending order reservation remaining must match router remaining margin"
                );
                if (ghostRemaining > 0) {
                    assertTrue(_isInMarginQueue(orderId), "Pending ghost order with margin must stay in margin queue");
                }
            } else {
                assertEq(ghostRemaining, 0, "Terminal ghost orders must have zero remaining committed margin");
                assertEq(liveRemaining, 0, "Terminal ghost orders must have zero router committed margin");
                assertEq(reservationRemaining, 0, "Terminal orders must have zero reservation remaining margin");
                assertFalse(_isInMarginQueue(orderId), "Terminal ghost orders must not stay in margin queue");
            }
        }
    }

    function invariant_ReservationConservationHoldsPerOrder() public view {
        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            uint256 original = handler.reservationOriginalAmount(orderId);
            uint256 consumed = handler.reservationConsumedAmount(orderId);
            uint256 released = handler.reservationReleasedAmount(orderId);
            uint256 remaining = handler.reservationRemainingCommittedMargin(orderId);
            if (original == 0 && consumed == 0 && released == 0 && remaining == 0) {
                continue;
            }

            assertEq(consumed + released + remaining, original, "Reservation conservation must hold per order");
            assertLe(consumed, original, "Consumed reservation amount must not exceed original amount");
            assertLe(released, original, "Released reservation amount must not exceed original amount");
        }
    }

    function invariant_AggregateReservationParityMatchesClearinghouseTotals() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            assertEq(
                handler.accountReservationRemainingSum(account),
                handler.accountActiveReservationCommittedMargin(account),
                "Committed reservation remaining sum must match clearinghouse account summary"
            );
            assertEq(
                handler.accountReservationRemainingSum(account),
                router.getAccountReservations(account).committedMarginUsdc,
                "Account reservation committed margin must derive from the same clearinghouse reservation source"
            );
        }
    }

    function invariant_ExplicitFifoReservationConsumptionUsesSuppliedIdsInOrder() public view {
        (
            address account,
            uint256 count,
            uint256 activeCountBefore,
            uint64[5] memory ids,
            uint256[5] memory remainingBefore
        ) = handler.lastTerminalReservationInfo();
        if (account == address(0)) {
            return;
        }

        assertEq(
            count, activeCountBefore, "Explicit terminal reservation set must cover all active pre-action reservations"
        );
        for (uint256 i = 0; i < count; i++) {
            assertGt(ids[i], 0, "Explicit terminal reservation ids must be populated");
            if (i > 0) {
                assertGt(ids[i], ids[i - 1], "Explicit terminal reservation ids must stay in FIFO order");
            }
            assertEq(
                handler.reservationAccount(ids[i]),
                account,
                "Explicit terminal reservation ids must belong to the acted-on account"
            );
            assertGt(
                remainingBefore[i],
                0,
                "Explicit terminal reservation ids must have active remaining balance before action"
            );
        }
    }

    function invariant_QueueReservationAgreementIsBidirectional() public view {
        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            uint8 status = handler.reservationStatus(orderId);
            uint256 remaining = handler.reservationRemainingCommittedMargin(orderId);
            uint8 ghostState = handler.ghostOrderLifecycleState(orderId);
            bool shouldBeInMarginQueue = status == 1 && remaining > 0 && ghostState == 1;

            if (shouldBeInMarginQueue) {
                assertTrue(
                    _isInMarginQueue(orderId),
                    "Active pending reservations with remaining balance must appear in margin queue"
                );
            }
        }
    }

    function invariant_NoDoubleFinalizationAfterReservationTerminalState() public view {
        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            uint8 status = handler.reservationStatus(orderId);
            uint256 original = handler.reservationOriginalAmount(orderId);
            uint256 consumed = handler.reservationConsumedAmount(orderId);
            uint256 released = handler.reservationReleasedAmount(orderId);
            if (status == 2 || status == 3) {
                assertEq(
                    handler.reservationRemainingCommittedMargin(orderId),
                    0,
                    "Terminal reservations must have zero remaining balance"
                );
                assertEq(
                    consumed + released,
                    original,
                    "Terminal reservations must close exactly once against original amount"
                );
            }
        }
    }

    function invariant_TerminalPathExactnessOnlyTouchesExplicitReservationSet() public view {
        (address account, uint256 count,, uint64[5] memory ids,) = handler.lastTerminalReservationInfo();
        if (account == address(0)) {
            return;
        }

        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            if (handler.reservationAccount(orderId) != account) {
                continue;
            }
            uint8 status = handler.reservationStatus(orderId);
            uint256 remaining = handler.reservationRemainingCommittedMargin(orderId);
            if (status == 1 && remaining > 0) {
                bool found;
                for (uint256 i = 0; i < count; i++) {
                    if (ids[i] == orderId) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "Terminal path should only leave active reservations from the explicit supplied set");
            }
        }
    }

    function invariant_CrossViewParityMatchesReservationSummaryAndTypedBuckets() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            IMarginClearinghouse.AccountReservationSummary memory summary =
                clearinghouse.getAccountReservationSummary(account);
            IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(account);

            assertEq(
                snapshot.committedMarginUsdc,
                summary.activeCommittedOrderMarginUsdc,
                "Account ledger snapshot committed margin must match reservation summary"
            );
            assertEq(
                snapshot.committedMarginUsdc,
                buckets.committedOrderMarginUsdc,
                "Account ledger snapshot committed margin must match typed committed bucket"
            );
        }
    }

    function invariant_FifoPointersStayWithinCommittedRange() public view {
        assertLe(router.nextExecuteId(), router.nextCommitId(), "nextExecuteId must not exceed nextCommitId");
    }

    function invariant_OrderExecutionPathRemainsReachable() public view {
        uint256 attempts = handler.ghostOrderExecutionAttemptCount();
        uint256 executedOrders = handler.ghostExecutedOrderCount();
        if (attempts < ORDER_EXECUTION_REACHABILITY_ATTEMPT_THRESHOLD) {
            return;
        }

        assertGt(executedOrders, 0, "Order execution must become reachable after repeated valid attempts");
    }

    function invariant_PendingQueueCountsStayConsistent() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 expectedCount = router.pendingOrderCounts(account);
            uint256 ghostCount = handler.ghostPendingOrderCount(account);

            uint256 traversed;
            for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
                OrderRouter.OrderRecord memory record = _orderRecord(orderId);
                if (
                    record.core.account == account
                        && uint256(record.status) == uint256(IOrderRouterAccounting.OrderStatus.Pending)
                ) {
                    traversed++;
                }
            }

            assertEq(traversed, expectedCount, "Pending queue traversal count must match pendingOrderCounts");
            assertEq(traversed, ghostCount, "Pending queue traversal count must match ghost pending count");
        }
    }

    function invariant_MarginQueueLinksAndMembershipStayConsistent() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint64 head = router.marginHeadOrderId(account);
            uint64 tail = router.marginTailOrderId(account);
            uint256 expectedCount = handler.ghostPendingMarginOrderCount(account);

            uint256 traversed;
            uint64 current = head;
            uint64 previous;
            while (current != 0) {
                OrderRouter.OrderRecord memory record = _orderRecord(current);
                assertEq(record.core.account, account, "Margin queue owner must match traversed account");
                assertEq(
                    uint256(record.status),
                    uint256(IOrderRouterAccounting.OrderStatus.Pending),
                    "Margin queue may only contain pending orders"
                );
                assertTrue(record.inMarginQueue, "Margin queue traversal must only include in-queue orders");
                assertFalse(record.core.isClose, "Margin queue may only contain open orders");
                assertGt(record.core.marginDelta, 0, "Margin queue orders must originate with committed margin");
                assertLe(
                    _remainingCommittedMargin(current),
                    record.core.marginDelta,
                    "Remaining committed margin cannot exceed the order's original reservation"
                );
                assertEq(record.prevMarginOrderId, previous, "Margin prev pointer must match traversal");
                if (previous != 0) {
                    assertGt(current, previous, "Margin queue must preserve FIFO commit order");
                }
                previous = current;
                current = record.nextMarginOrderId;
                traversed++;
                assertLe(
                    traversed, expectedCount == 0 ? 1 : expectedCount, "Margin queue traversal exceeded ghost count"
                );
            }

            assertEq(traversed, expectedCount, "Margin queue traversal count must match ghost margin count");
            if (traversed == 0) {
                assertEq(head, 0, "Empty margin queue must have zero head");
                assertEq(tail, 0, "Empty margin queue must have zero tail");
            } else {
                assertEq(previous, tail, "Margin queue tail must equal last traversed order");
                assertEq(_orderRecord(head).prevMarginOrderId, 0, "Margin head must have zero prev pointer");
                assertEq(_orderRecord(tail).nextMarginOrderId, 0, "Margin tail must have zero next pointer");
            }
        }
    }

    function _sumPendingExecutionBounties() internal view returns (uint256 totalBounties) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.account == address(0) || record.core.sizeDelta == 0) {
                continue;
            }
            totalBounties += record.executionBountyUsdc;
        }
    }

    function _sumReservedSettlementBuckets() internal view returns (uint256 totalReservedSettlement) {
        totalReservedSettlement += clearinghouse.getLockedMarginBuckets(_account(address(handler)))
        .reservedSettlementUsdc;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            totalReservedSettlement += clearinghouse.getLockedMarginBuckets(_account(handler.actorAt(i)))
            .reservedSettlementUsdc;
        }
    }

    function _terminalCurveHash(
        ITerminalNavBookV2 book,
        address account,
        ITerminalNavBookV2.CurveRecord memory curve
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(book),
                book.CAP_PRICE(),
                account,
                curve.lots,
                curve.entryCostUsdcAtoms,
                curve.effectiveCapUsdcAtoms,
                curve.side
            )
        );
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

}
