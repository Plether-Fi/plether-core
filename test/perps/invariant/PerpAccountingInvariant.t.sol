// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpAccountingInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

            assertEq(handler.accountRouterEscrow(accountId), 0, "Liquidated accounts must not retain router-held escrow");
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

            assertEq(handler.accountRouterEscrow(accountId), 0, "Bad debt growth cannot coexist with same-account router escrow");
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
            assertEq(liveCommittedMargin, reservationCommittedMargin, "Router account escrow must match clearinghouse reservation summary");
            ghostTotalCommittedMargin += ghostCommittedMargin;
        }

        assertEq(
            handler.totalCommittedMarginSnapshot(),
            ghostTotalCommittedMargin,
            "Ghost committed margin total must match tracked account sum"
        );
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
            uint256 liveRemaining = router.committedMargins(orderId);
            uint256 reservationRemaining = handler.reservationRemainingCommittedMargin(orderId);

            if (ghostState == 1) {
                assertEq(liveRemaining, ghostRemaining, "Pending ghost order margin must match router remaining margin");
                assertEq(liveRemaining, reservationRemaining, "Pending order reservation remaining must match router remaining margin");
                if (ghostRemaining > 0) {
                    assertTrue(router.isInMarginQueue(orderId), "Pending ghost order with margin must stay in margin queue");
                }
            } else {
                assertEq(ghostRemaining, 0, "Terminal ghost orders must have zero remaining committed margin");
                assertEq(liveRemaining, 0, "Terminal ghost orders must have zero router committed margin");
                assertEq(reservationRemaining, 0, "Terminal orders must have zero reservation remaining margin");
                assertFalse(router.isInMarginQueue(orderId), "Terminal ghost orders must not stay in margin queue");
            }
        }
    }

    function invariant_FifoPointersStayWithinCommittedRange() public view {
        assertLe(router.nextExecuteId(), router.nextCommitId(), "nextExecuteId must not exceed nextCommitId");
    }

    function invariant_PendingQueueLinksAndCountsStayConsistent() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint64 head = router.pendingHeadOrderId(accountId);
            uint64 tail = router.pendingTailOrderId(accountId);
            uint256 expectedCount = router.pendingOrderCounts(accountId);
            uint256 ghostCount = handler.ghostPendingOrderCount(accountId);

            uint256 traversed;
            uint64 current = head;
            uint64 previous;
            while (current != 0) {
                OrderRouter.OrderRecord memory record = router.getOrderRecord(current);
                assertEq(record.core.accountId, accountId, "Pending queue owner must match traversed account");
                assertEq(
                    uint256(record.status), uint256(OrderRouter.OrderStatus.Pending), "Pending queue may only contain pending orders"
                );
                assertEq(record.prevPendingOrderId, previous, "Pending prev pointer must match traversal");
                if (previous != 0) {
                    assertGt(current, previous, "Pending queue must preserve FIFO commit order");
                }
                previous = current;
                current = record.nextPendingOrderId;
                traversed++;
                assertLe(traversed, expectedCount == 0 ? 1 : expectedCount, "Pending queue traversal exceeded tracked count");
            }

            assertEq(traversed, expectedCount, "Pending queue traversal count must match pendingOrderCounts");
            assertEq(traversed, ghostCount, "Pending queue traversal count must match ghost pending count");
            if (traversed == 0) {
                assertEq(head, 0, "Empty pending queue must have zero head");
                assertEq(tail, 0, "Empty pending queue must have zero tail");
            } else {
                assertEq(previous, tail, "Pending queue tail must equal last traversed order");
                assertEq(router.getOrderRecord(head).prevPendingOrderId, 0, "Pending head must have zero prev pointer");
                assertEq(router.getOrderRecord(tail).nextPendingOrderId, 0, "Pending tail must have zero next pointer");
            }
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
                OrderRouter.OrderRecord memory record = router.getOrderRecord(current);
                assertEq(record.core.accountId, accountId, "Margin queue owner must match traversed account");
                assertEq(
                    uint256(record.status), uint256(OrderRouter.OrderStatus.Pending), "Margin queue may only contain pending orders"
                );
                assertTrue(record.inMarginQueue, "Margin queue traversal must only include in-queue orders");
                assertGt(router.committedMargins(current), 0, "Margin queue orders must retain committed margin");
                assertEq(record.prevMarginOrderId, previous, "Margin prev pointer must match traversal");
                if (previous != 0) {
                    assertGt(current, previous, "Margin queue must preserve FIFO commit order");
                }
                previous = current;
                current = record.nextMarginOrderId;
                traversed++;
                assertLe(traversed, expectedCount == 0 ? 1 : expectedCount, "Margin queue traversal exceeded ghost count");
            }

            assertEq(traversed, expectedCount, "Margin queue traversal count must match ghost margin count");
            if (traversed == 0) {
                assertEq(head, 0, "Empty margin queue must have zero head");
                assertEq(tail, 0, "Empty margin queue must have zero tail");
            } else {
                assertEq(previous, tail, "Margin queue tail must equal last traversed order");
                assertEq(router.getOrderRecord(head).prevMarginOrderId, 0, "Margin head must have zero prev pointer");
                assertEq(router.getOrderRecord(tail).nextMarginOrderId, 0, "Margin tail must have zero next pointer");
            }
        }
    }

    function _sumPendingExecutionBounties() internal view returns (uint256 totalBounties) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 accountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (accountId == bytes32(0) || sizeDelta == 0) {
                continue;
            }
            totalBounties += router.executionBountyReserves(orderId);
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }
}
