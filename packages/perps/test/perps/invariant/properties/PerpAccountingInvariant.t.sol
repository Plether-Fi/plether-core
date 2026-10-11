// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "../handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

contract PerpAccountingInvariantTest is BasePerpInvariantTest {

    uint256 internal constant ORDER_EXECUTION_REACHABILITY_ATTEMPT_THRESHOLD = 32;

    PerpAccountingHandler internal handler;

    struct TerminalBookTotals {
        uint256 activeCurveCount;
        uint256 totalLots;
        uint256 totalEntryCostUsdcAtoms;
        uint256 totalEffectiveCapUsdcAtoms;
    }

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

    function test_HandlerExecutesValidOrdersAndRetainsExpectedBusinessRejection() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();
        (uint256 size,,,,,,) = engine.positions(handler.actorAt(0));
        assertGt(size, 0, "valid handler order must reach a live position");
        assertEq(handler.ghostExecutedOrderCount(), 1);
        for (uint256 i; i < 6; ++i) {
            handler.commitOpenOrder(1, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        }
        assertEq(router.pendingOrderCounts(handler.actorAt(1)), 5);
        assertEq(handler.caughtRevertsBySelector(IOrderRouterErrors.OrderRouter__TooManyPendingOrders.selector), 1);
        _assertAllInvariants();
    }

    function test_UnknownCaughtRevertsFailTheHandler() public {
        _assertUnexpectedCommitRevert(hex"deadbeef");
        _assertUnexpectedCommitRevert(hex"");
        _assertUnexpectedCommitRevert(abi.encodeWithSignature("Error(string)", "injected failure"));
        _assertUnexpectedCommitRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _assertUnexpectedCommitRevert(
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, uint8(255))
        );
    }

    function _assertUnexpectedCommitRevert(
        bytes memory injected
    ) internal {
        vm.mockCallRevert(
            address(router), bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")), injected
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpAccountingHandler.UnexpectedActionRevert.selector,
                PerpAccountingHandler.RejectionDomain.Commit,
                injected
            )
        );
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        vm.clearMockedCalls();
        assertEq(handler.caughtActionReverts(), 0, "unknown failures must not count as expected business rejections");
    }

    function test_InternalExecutionFailuresFailBothSingleAndBatchHandlers() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        OrderV3Types.ExecutionResult memory single;
        single.pendingReason = OrderV3Types.PendingReason.EngineFailure;
        vm.mockCall(address(router), OrderRouter.executeOrder.selector, abi.encode(single));
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpAccountingHandler.UnexpectedPendingExecution.selector, OrderV3Types.PendingReason.EngineFailure
            )
        );
        handler.executeNextOrderModelled();
        vm.clearMockedCalls();

        OrderV3Types.BatchResult memory batch;
        batch.stopReason = OrderV3Types.PendingReason.ReceiptFailure;
        vm.mockCall(address(router), OrderRouter.executeOrderBatch.selector, abi.encode(batch));
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpAccountingHandler.UnexpectedPendingExecution.selector, OrderV3Types.PendingReason.ReceiptFailure
            )
        );
        handler.executeNextOrderBatch(1);
        vm.clearMockedCalls();
    }

    function test_LiquidatedAccountWithdrawsResidualAndReusesTwoGenerations() public {
        address actor = handler.actorAt(0);
        _openReusableActor();
        uint64 firstOrderId = router.nextCommitId() - 1;
        assertEq(handler.ghostOrderGeneration(firstOrderId), 0);
        handler.liquidate(0, 1.69e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 1, "first position must actually liquidate");
        assertEq(handler.ghost().accountGeneration(actor), 1);
        // Opening spends the entire $5,000 commitment (fee, pledge and liquidation reserve),
        // plus the capped $0.20 execution bounty. The loss exhausts the pledge but cannot take free cash.
        uint256 residual = 44_999_800_000;
        assertEq(clearinghouse.balanceUsdc(actor), residual, "independent first-generation residual");
        _assertAllInvariants();

        vm.prank(actor);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(actor, residual + 1);
        handler.withdrawCollateral(0, residual);
        assertEq(clearinghouse.balanceUsdc(actor), 0);
        assertEq(usdc.balanceOf(actor), residual, "requested residual belongs to the liquidated trader");
        vm.prank(actor);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(actor, 1);
        _assertAllInvariants();

        handler.depositCollateral(0, 50_000e6);
        _openReusableActor();
        uint64 secondOrderId = router.nextCommitId() - 1;
        assertEq(handler.ghostOrderGeneration(secondOrderId), 1);
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 17, 1000e6, 1.2e8);
        uint64 pendingOrderId = router.nextCommitId() - 1;
        assertEq(router.pendingOrderCounts(actor), 1, "new generation may legitimately own pending orders");
        assertGt(handler.accountExecutionBountyReserve(actor), 0);
        _assertAllInvariants();

        handler.liquidate(0, 1.69e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 2, "reused account must liquidate a second time");
        assertEq(handler.ghost().accountGeneration(actor), 2);
        assertEq(handler.ghostOrderGeneration(pendingOrderId), 1);
        assertEq(router.pendingOrderCounts(actor), 0);
        assertEq(_remainingCommittedMargin(pendingOrderId), 0);
        assertEq(
            clearinghouse.balanceUsdc(actor),
            44_999_600_000,
            "second generation also forfeits its pending order's capped $0.20 bounty"
        );
        assertEq(usdc.balanceOf(actor), residual, "reopening and liquidation cannot seize prior wallet entitlement");
        _assertAllInvariants();
    }

    function test_ZeroResidualLiquidationCannotWithdrawAndCanReopen() public {
        address actor = handler.actorAt(0);
        // Leave exactly $5,000 commitment plus the $0.20 opening bounty; no automatic funding is needed.
        handler.withdrawCollateral(0, 44_999_800_000);
        _openReusableActor();
        handler.liquidate(0, 1.69e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 1);
        assertEq(clearinghouse.balanceUsdc(actor), 0, "fully spent funding leaves no recoverable entitlement");
        vm.prank(actor);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(actor, 1);
        handler.depositCollateral(0, 50_000e6);
        _openReusableActor();
        _assertAllInvariants();
    }

    function test_WalletFlowCheckDetectsUnrequestedCredit() public {
        address actor = handler.actorAt(0);
        handler.withdrawCollateral(0, 100e6);
        _assertAllInvariants();
        usdc.mint(actor, 1);
        vm.expectRevert();
        this.invariant_OrderReservationsQueuesAndTerminalStateReconcile();
    }

    function test_WalletFlowCheckDetectsDuplicateWithdrawalCredit() public {
        address actor = handler.actorAt(0);
        handler.withdrawCollateral(0, 100e6);
        _assertAllInvariants();
        usdc.mint(actor, 100e6);
        vm.expectRevert();
        this.invariant_OrderReservationsQueuesAndTerminalStateReconcile();
    }

    function test_LiquidatedActorCanCreateSettleAndWithdrawNewClaims() public {
        address actor = handler.actorAt(0);
        _openReusableActor();
        handler.liquidate(0, 1.69e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 1);
        handler.createTraderClaim(0);
        // 10,000 tokens gain $0.50 each; the close withholds $2 (4 bps of $5,000 notional).
        uint256 claim = 4998e6;
        assertEq(engine.traderClaimBalanceUsdc(actor), claim, "independent new deferred claim");
        handler.fundHousePool(claim + 1000e6);
        handler.settleTraderClaim(0);
        assertEq(engine.traderClaimBalanceUsdc(actor), 0);
        assertEq(usdc.balanceOf(actor), 0, "claim settlement credits custody rather than the wallet");
        handler.restoreSolvencyAndClearDegradedMode();
        // $44,999.80 residual - $4 open fee - two $0.20 bounties + $4,998 net claim.
        uint256 settlement = 49_993_400_000;
        assertEq(clearinghouse.balanceUsdc(actor), settlement, "independent profit and claim entitlement");
        handler.withdrawCollateral(0, settlement);
        assertEq(usdc.balanceOf(actor), settlement);
        assertEq(handler.ghost().accountGeneration(actor), 1);
        _assertAllInvariants();
    }

    function test_ReusedLiquidationPreservesAndPaysRemainingClaimEntitlement() public {
        address actor = handler.actorAt(0);
        _openReusableActor();
        handler.liquidate(0, 1.69e8);
        handler.createTraderClaim(0);
        assertEq(engine.traderClaimBalanceUsdc(actor), 4998e6);
        assertEq(clearinghouse.balanceUsdc(actor), 44_995_400_000);
        // Replenish the mock pool without settling this account's outstanding claim.
        handler.restoreSolvencyAndClearDegradedMode();
        handler.setPoolAssets(1_000_000_000e6);
        handler.syncMarkNow(1.2e8);
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 1000, 500e6, 1.2e8);
        handler.executeNextOrderModelled();
        (uint256 size,,,,,,) = engine.positions(actor);
        assertEq(size, 1000 * CfdTypes.SIZE_QUANTUM);
        // A $4,200 price loss consumes only the claim, leaving $798. With $344 pledge, equity
        // is $1,142 < $1,242 maintenance. The liquidation charge is capped at the $108 reserve.
        handler.liquidate(0, 1.242e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 2);
        assertEq(engine.traderClaimBalanceUsdc(actor), 798e6, "claim remainder survives liquidation");
        assertEq(clearinghouse.balanceUsdc(actor), 44_839_200_000, "free cash plus surviving pledge entitlement");
        handler.settleTraderClaim(0);
        assertEq(engine.traderClaimBalanceUsdc(actor), 0);
        assertEq(clearinghouse.balanceUsdc(actor), 45_637_200_000);
        handler.withdrawCollateral(0, 45_637_200_000);
        assertEq(usdc.balanceOf(actor), 45_637_200_000);
        vm.prank(actor);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(actor, 1);
        _assertAllInvariants();
    }

    function test_IndependentResidualCheckRejectsInflatedProductionBalance() public {
        _openReusableActor();
        handler.liquidate(0, 1.69e8);
        this.checkFirstGenerationResidual();
        vm.mockCall(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.balanceUsdc, (handler.actorAt(0))),
            abi.encode(uint256(44_999_800_001))
        );
        vm.expectRevert();
        this.checkFirstGenerationResidual();
        vm.clearMockedCalls();
    }

    function checkFirstGenerationResidual() external view {
        assertEq(
            clearinghouse.balanceUsdc(handler.actorAt(0)),
            44_999_800_000,
            "input-derived residual must not accept an inflated production balance"
        );
    }

    function test_GenerationCleanupStillDetectsAnOldReservationAfterReopening() public {
        _openReusableActor();
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 17, 1000e6, 1.2e8);
        uint64 oldReservationId = router.nextCommitId() - 1;
        handler.liquidate(0, 1.69e8);
        assertEq(handler.ghostSuccessfulLiquidations(), 1);
        handler.depositCollateral(0, 50_000e6);
        handler.syncMarkNow(1.2e8);
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 17, 1000e6, 1.2e8);
        assertEq(router.pendingOrderCounts(handler.actorAt(0)), 1);
        _assertAllInvariants();

        IMarginClearinghouse.OrderReservation memory stale = clearinghouse.getOrderReservation(oldReservationId);
        stale.remainingAmountUsdc = 1;
        vm.mockCall(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.getOrderReservation, (oldReservationId)),
            abi.encode(stale)
        );
        vm.expectRevert();
        this.invariant_OrderReservationsQueuesAndTerminalStateReconcile();
        vm.clearMockedCalls();
        _assertAllInvariants();
    }

    function _openReusableActor() internal {
        handler.syncMarkNow(1.2e8);
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 1000, 5000e6, 1.2e8);
        handler.executeNextOrderModelled();
        (uint256 size,,,,,,) = engine.positions(handler.actorAt(0));
        assertEq(size, 1000 * CfdTypes.SIZE_QUANTUM, "reused account must execute a full new position");
    }

    function _assertInvariant_ClearinghouseReservationsMatchLiveExecutionBounties() internal view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router must not custody execution bounty reserves");
        assertEq(
            _sumReservedSettlementBuckets(),
            _sumPendingExecutionBounties(),
            "Clearinghouse reserved settlement must equal live pending execution bounty reserves"
        );
    }

    function _assertInvariant_TerminalNavBookMatchesCanonicalEngineState() internal view {
        ITerminalNavBookV2 book = engine.terminalNavBook();
        // Group loop totals in memory to keep the production via-IR assertion within the stack budget.
        TerminalBookTotals memory totals;

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

            assertEq(
                curveHash,
                _terminalCurveHash(book, account, curve),
                "Curve hash must commit to the canonical account record"
            );
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

            totals.activeCurveCount++;
            totals.totalLots += curve.lots;
            totals.totalEntryCostUsdcAtoms += curve.entryCostUsdcAtoms;
            totals.totalEffectiveCapUsdcAtoms += curve.effectiveCapUsdcAtoms;
        }

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.capPrice, engine.CAP_PRICE(), "Terminal book and Engine price caps must match");
        assertEq(state.activeCurveCount, totals.activeCurveCount, "Book active curve count must match actor records");
        assertEq(state.totalLots, totals.totalLots, "Book total lots must match actor records");
        assertEq(
            state.totalEntryCostUsdcAtoms,
            totals.totalEntryCostUsdcAtoms,
            "Book total entry cost must match actor records"
        );
        assertEq(
            state.totalEffectiveCapUsdcAtoms,
            totals.totalEffectiveCapUsdcAtoms,
            "Book total effective cap must match actor records"
        );
    }

    function _assertInvariant_LiquidatedGenerationsHaveNoLiveOrdersOrReserves() internal view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            (uint256 pending, uint256 liveReserves, uint256 reserved) =
                handler.liquidatedGenerationExposure(handler.actorAt(i));
            assertEq(pending, 0, "Liquidated generations must not keep pending orders");
            assertEq(liveReserves, 0, "Liquidated generations must not retain live reserves");
            assertEq(reserved, 0, "Liquidated generations must not retain reserved settlement");
        }
    }

    function _assertInvariant_WalletsMatchSubmittedFlows() internal view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actorAt(i);
            assertEq(
                usdc.balanceOf(actor),
                handler.ghost().expectedWalletFromSubmittedFlows(actor),
                "Wallet credits must equal submitted withdrawal flows"
            );
        }
    }

    function _assertInvariant_LiquidationPriceTailsRemainDiagnosticAfterReservationExhaustion() internal view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertEq(
                handler.ghost().liquidationDebtDiagnosticTotal(handler.actorAt(i)),
                0,
                "Every liquidation price tail must remain a diagnostic writeoff, never protocol debt"
            );
        }
    }

    function _assertInvariant_GhostCommittedMarginMatchesAccountReservation() internal view {
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

    function _assertInvariant_OrderReservationModuleSummariesMatchAccountReservation() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
            IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(account);

            uint256 pendingCloseSize;
            uint256 pendingBounties;
            for (uint256 j = 0; j < pending.length; j++) {
                pendingBounties += pending[j].executionBountyUsdc;
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
                pendingBounties + router.positionProtectionBook().unpaidBounties(account),
                "Canonical bounty total must equal the sum of order and protection records"
            );
            assertEq(
                router.pendingCloseSize(account),
                pendingCloseSize,
                "Pending close size mapping must match pending-order scan"
            );
        }
    }

    function _assertInvariant_GhostOrderCommittedMarginStateMachineMatchesRouter() internal view {
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

    function _assertInvariant_ReservationConservationHoldsPerOrder() internal view {
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

    function _assertInvariant_AggregateReservationParityMatchesClearinghouseTotals() internal view {
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

    function _assertInvariant_ExplicitFifoReservationConsumptionUsesSuppliedIdsInOrder() internal view {
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

    function _assertInvariant_QueueReservationAgreementIsBidirectional() internal view {
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

    function _assertInvariant_NoDoubleFinalizationAfterReservationTerminalState() internal view {
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

    function _assertInvariant_TerminalPathExactnessOnlyTouchesExplicitReservationSet() internal view {
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

    function _assertInvariant_CrossViewParityMatchesReservationSummaryAndTypedBuckets() internal view {
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

    function _assertInvariant_FifoPointersStayWithinCommittedRange() internal view {
        assertLe(router.nextExecuteId(), router.nextCommitId(), "nextExecuteId must not exceed nextCommitId");
    }

    function _assertInvariant_OrderExecutionPathRemainsReachable() internal view {
        uint256 attempts = handler.ghostOrderExecutionAttemptCount();
        uint256 executedOrders = handler.ghostExecutedOrderCount();
        if (attempts < ORDER_EXECUTION_REACHABILITY_ATTEMPT_THRESHOLD) {
            return;
        }

        assertGt(executedOrders, 0, "Order execution must become reachable after repeated valid attempts");
    }

    function _assertInvariant_PendingQueueCountsStayConsistent() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 expectedCount = router.pendingOrderCounts(account);
            uint256 ghostCount = handler.ghostPendingOrderCount(account);

            uint256 traversed;
            for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
                OrderRouterDebugLens.OrderRecord memory record = _orderRecord(orderId);
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

    function _assertInvariant_MarginQueueLinksAndMembershipStayConsistent() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint64 head = router.marginHeadOrderId(account);
            uint64 tail = router.marginTailOrderId(account);
            uint256 expectedCount = handler.ghostPendingMarginOrderCount(account);

            uint256 traversed;
            uint64 current = head;
            uint64 previous;
            while (current != 0) {
                OrderRouterDebugLens.OrderRecord memory record = _orderRecord(current);
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
            OrderRouterDebugLens.OrderRecord memory record = _orderRecord(orderId);
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

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_OrderReservationsQueuesAndTerminalStateReconcile() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_ClearinghouseReservationsMatchLiveExecutionBounties();
        _assertInvariant_TerminalNavBookMatchesCanonicalEngineState();
        _assertInvariant_LiquidatedGenerationsHaveNoLiveOrdersOrReserves();
        _assertInvariant_WalletsMatchSubmittedFlows();
        _assertInvariant_LiquidationPriceTailsRemainDiagnosticAfterReservationExhaustion();
        _assertInvariant_GhostCommittedMarginMatchesAccountReservation();
        _assertInvariant_OrderReservationModuleSummariesMatchAccountReservation();
        _assertInvariant_GhostOrderCommittedMarginStateMachineMatchesRouter();
        _assertInvariant_ReservationConservationHoldsPerOrder();
        _assertInvariant_AggregateReservationParityMatchesClearinghouseTotals();
        _assertInvariant_ExplicitFifoReservationConsumptionUsesSuppliedIdsInOrder();
        _assertInvariant_QueueReservationAgreementIsBidirectional();
        _assertInvariant_NoDoubleFinalizationAfterReservationTerminalState();
        _assertInvariant_TerminalPathExactnessOnlyTouchesExplicitReservationSet();
        _assertInvariant_CrossViewParityMatchesReservationSummaryAndTypedBuckets();
        _assertInvariant_FifoPointersStayWithinCommittedRange();
        _assertInvariant_OrderExecutionPathRemainsReachable();
        _assertInvariant_PendingQueueCountsStayConsistent();
        _assertInvariant_MarginQueueLinksAndMembershipStayConsistent();
    }

}
