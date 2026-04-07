// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {AccountLensViewTypes} from "../../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpAccountingInvariantTest is BasePerpInvariantTest {

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
            bountyBps: 9
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.claimDeferredClearerBounty.selector;
        selectors[7] = handler.setRouterPayoutFailureMode.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_RouterCustodyMatchesLiveExecutionBounties() public view {
        assertEq(
            usdc.balanceOf(address(router)),
            _sumPendingExecutionBounties(),
            "Router custody must equal live pending execution bounty reserves"
        );
    }

    function invariant_LiquidatedActorsHaveNoPendingOrders() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(router.pendingOrderCounts(accountId), 0, "Liquidated accounts must not keep pending orders");
        }
    }

    function invariant_LiquidatedActorsHaveNoLiveReserves() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(
                handler.accountRouterEscrow(accountId), 0, "Liquidated accounts must not retain router-held escrow"
            );
            assertEq(handler.accountLiveReserveCount(accountId), 0, "Liquidated accounts must not retain live reserves");
        }
    }

    function invariant_LiquidatedActorsCannotRecoverWalletUsdc() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            bytes32 accountId = _accountId(actor);
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertLe(usdc.balanceOf(actor), snapshot.walletUsdc, "Liquidated actors must not recover wallet USDC later");
        }
    }

    function invariant_BadDebtOnlyAppearsAfterAccountEscrowExhaustion() public view {
        uint256 currentBadDebt = engine.accumulatedBadDebtUsdc();
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated || currentBadDebt <= snapshot.badDebtUsdc) {
                continue;
            }

            assertEq(
                handler.accountRouterEscrow(accountId),
                0,
                "Bad debt growth cannot coexist with same-account router escrow"
            );
        }
    }

    function invariant_GhostCommittedMarginMatchesAccountEscrow() public view {
        uint256 ghostTotalCommittedMargin;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostCommittedMargin = handler.committedMarginSnapshot(accountId);
            uint256 liveCommittedMargin = router.getAccountEscrow(accountId).committedMarginUsdc;
            uint256 reservationCommittedMargin = handler.accountActiveReservationCommittedMargin(accountId);

            assertEq(ghostCommittedMargin, liveCommittedMargin, "Ghost committed margin must match account escrow");
            assertEq(
                liveCommittedMargin,
                reservationCommittedMargin,
                "Router account escrow must match clearinghouse reservation summary"
            );
            ghostTotalCommittedMargin += ghostCommittedMargin;
        }

        assertEq(
            handler.totalCommittedMarginSnapshot(),
            ghostTotalCommittedMargin,
            "Ghost committed margin total must match tracked account sum"
        );
    }

    function invariant_OrderEscrowModuleSummariesMatchAccountEscrow() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
            IOrderRouterAccounting.AccountOrderSummary memory summary = router.getAccountOrderSummary(accountId);

            assertEq(
                summary.pendingOrderCount, escrow.pendingOrderCount, "Escrow summary count must match account escrow"
            );
            assertEq(
                summary.committedMarginUsdc,
                escrow.committedMarginUsdc,
                "Escrow summary committed margin must match account escrow"
            );
            assertEq(
                summary.executionBountyUsdc,
                escrow.executionBountyUsdc,
                "Escrow summary execution bounty must match account escrow"
            );
            assertEq(
                router.pendingCloseSize(accountId),
                summary.pendingCloseSize,
                "Pending close size mapping must match escrow summary"
            );
        }
    }

    function invariant_GhostDeferredClearerBountyMatchesEngine() public view {
        uint256 ghostDeferredBounty = handler.deferredClearerBountySnapshot();
        uint256 liveDeferredBounty = engine.deferredClearerBountyUsdc(address(handler));

        assertEq(ghostDeferredBounty, liveDeferredBounty, "Ghost deferred clearer bounty must match engine storage");
        assertEq(
            handler.totalDeferredClearerBountySnapshot(),
            ghostDeferredBounty,
            "Ghost deferred clearer bounty total must match tracked clearer balance"
        );
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
            bytes32 accountId = _accountId(handler.actorAt(i));
            assertEq(
                handler.accountReservationRemainingSum(accountId),
                handler.accountActiveReservationCommittedMargin(accountId),
                "Committed reservation remaining sum must match clearinghouse account summary"
            );
            assertEq(
                handler.accountReservationRemainingSum(accountId),
                router.getAccountOrderSummary(accountId).committedMarginUsdc,
                "Order summary committed margin must derive from the same clearinghouse reservation source"
            );
        }
    }

    function invariant_ExplicitFifoReservationConsumptionUsesSuppliedIdsInOrder() public view {
        (
            bytes32 accountId,
            uint256 count,
            uint256 activeCountBefore,
            uint64[5] memory ids,
            uint256[5] memory remainingBefore
        ) = handler.lastTerminalReservationInfo();
        if (accountId == bytes32(0)) {
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
                accountId,
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
        (bytes32 accountId, uint256 count,, uint64[5] memory ids,) = handler.lastTerminalReservationInfo();
        if (accountId == bytes32(0)) {
            return;
        }

        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            if (handler.reservationAccount(orderId) != accountId) {
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
            bytes32 accountId = _accountId(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(accountId);
            IMarginClearinghouse.AccountReservationSummary memory summary =
                clearinghouse.getAccountReservationSummary(accountId);
            IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(accountId);

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

    function invariant_PendingQueueCountsStayConsistent() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 expectedCount = router.pendingOrderCounts(accountId);
            uint256 ghostCount = handler.ghostPendingOrderCount(accountId);

            uint256 traversed;
            for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
                OrderRouter.OrderRecord memory record = _orderRecord(orderId);
                if (
                    record.core.accountId == accountId
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
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint64 head = router.marginHeadOrderId(accountId);
            uint64 tail = router.marginTailOrderId(accountId);
            uint256 expectedCount = handler.ghostPendingMarginOrderCount(accountId);

            uint256 traversed;
            uint64 current = head;
            uint64 previous;
            while (current != 0) {
                OrderRouter.OrderRecord memory record = _orderRecord(current);
                assertEq(record.core.accountId, accountId, "Margin queue owner must match traversed account");
                assertEq(
                    uint256(record.status),
                    uint256(IOrderRouterAccounting.OrderStatus.Pending),
                    "Margin queue may only contain pending orders"
                );
                assertTrue(record.inMarginQueue, "Margin queue traversal must only include in-queue orders");
                assertGt(_remainingCommittedMargin(current), 0, "Margin queue orders must retain committed margin");
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
            if (record.core.accountId == bytes32(0) || record.core.sizeDelta == 0) {
                continue;
            }
            totalBounties += record.executionBountyUsdc;
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

}
