// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {PendingOrderReferenceLedger} from "../ghost/PendingOrderReferenceLedger.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

contract PerpMixedPendingOrdersTest is BasePerpTest {

    PerpMixedAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.005e18;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();
        handler = new PerpMixedAccountingHandler(
            settlementToken,
            baseMockPyth,
            engine,
            clearinghouse,
            pool,
            juniorVault,
            seniorVault,
            OrderRouter(address(router)),
            address(this)
        );
    }

    function test_TwentyLiveOrdersReplayBoundedBatchExpiryAndRiskOff() public {
        handler.exercisePendingHistories();
        assertEq(handler.maximumLiveOrders(), 20);
        assertEq(handler.rejectedSixthOrders(), 4);
        assertGt(handler.pendingSameBlockResults(), 0);
        assertGt(handler.pendingMevRejections(), 0);
        assertGe(handler.completedBatches(), 2);
        assertGt(handler.expiredOrders(), 0);
        assertGt(handler.slippageFailures(), 0);
        assertGt(handler.riskOffOrders(), 0);
        handler.assertModel();
    }

    function test_IndependentMixedRefundPreservesLaterFreeFundedOrder() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.exerciseUnpaidCloseOverlapHistory();
        assertEq(handler.unpaidFailureTransitions(), 2);
        assertEq(handler.closesBehindPendingOrders(), 1);
        assertEq(handler.closeOpenCloseHistories(), 1);
        handler.assertModel();
    }

    function test_IndependentRestoredSolvencyPreservesPledgedOrder() public {
        handler.exercisePendingCloseSolvencyHistory();
        assertEq(handler.pendingCloseHealthyRejections(), 1);
        assertEq(handler.unpaidCloseLiquidations(), 1);
        handler.assertModel();
    }

    function test_IndependentLpEpochSpansPledgeReservationAndRefund() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.requestJuniorDeposit(0, 1000e6);
        handler.commitZeroFreeClose(0, true);
        assertGt(handler.zeroFreeCloseOrders(), 0);
        handler.refreshMark(140_000_002);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpEpochsWithPendingCloses(), 1);
        handler.expirePending(0);
        handler.claimJuniorDeposit(0);
        assertEq(handler.unpaidFailedCloses(), 1);
        handler.assertModel();
    }

    function test_PendingQueuesSurviveCollateralAndCarryActions() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.openOrIncrease(1, 117, 120_000_002);
        handler.commitOpen(0, 51, 110_000_002);
        handler.commitClose(1, 17, false);
        handler.addCollateral(0, 13e6);
        handler.addCollateral(1, 17e6);
        assertEq(handler.orders().liveCount(), 2);
        handler.executeHead(true);
        handler.executeHead(false);
        handler.assertModel();
    }

    function test_CloseOpenCloseProjectsQueuedResidualAndCreatesNewPositionEpoch() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.commitClose(0, 100, true);
        handler.commitOpen(0, 17, 80_000_002);
        handler.commitClose(0, 17, true);
        assertEq(handler.orders().count(0), 3);
        handler.executeBatch(3);
        assertEq(handler.traderState(0).lots, 0);
        assertEq(handler.positionEpochs(0), 2);
        handler.replayPending(0, false);
        handler.assertModel();
    }

    function test_PledgeBountyProvenancePersistsThroughExpiryAndSelfExecution() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.commitZeroFreeClose(0, false);
        uint64 id = handler.orders().head();
        PendingOrderReferenceLedger.Order memory expected = handler.orders().order(id);
        assertEq(expected.bountyPledge, 0);
        assertEq(expected.sourceGeneration, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        handler.expirePending(0);
        handler.commitZeroFreeClose(0, true);
        handler.executeHead(true);
        assertEq(handler.traderState(0).lots, 0);
        assertGe(handler.zeroFreeCloseOrders(), 2);
        handler.assertModel();
    }

    function test_ReservedCashCannotBeWithdrawnWhileFlatOpenPending() public {
        handler.commitOpen(2, 117, 120_000_002);
        handler.rejectReservedWithdrawal(2);
        handler.withdrawFreeCollateral(2, type(uint256).max);
        assertGt(handler.orders().margin(2), 0);
        handler.executeHead(false);
        handler.assertModel();
    }

    function test_ExpiredNonHeadRemovalPreservesBothQueueNeighbors() public {
        handler.commitOpen(0, 17, 80_000_002);
        handler.commitOpen(1, 17, 80_000_002);
        handler.commitOpen(2, 17, 80_000_002);
        vm.warp(vm.getBlockTimestamp() + 61);
        handler.expirePending(1);
        assertEq(handler.orders().liveCount(), 2);
        handler.executeBatch(2);
        assertEq(handler.orders().liveCount(), 0);
    }

    function test_FirstAuthoredTickPricesExecutionAfterLaterMark() public {
        handler.openOrIncrease(0, 100, 80_000_002);
        handler.commitOpen(0, 17, 90_000_002);
        uint64 id = handler.orders().head();
        vm.warp(vm.getBlockTimestamp() + 1);
        handler.refreshMark(100_000_002);
        vm.warp(vm.getBlockTimestamp() + 1);
        handler.refreshMark(120_000_002);
        handler.executeHead(false);
        assertEq(handler.expectedExecutionPrices(id), 100_000_002);
        assertEq(handler.currentPrice(), 120_000_002);
        assertEq(handler.traderState(0).basis, 100 * 80_000_002 + 17 * 100_000_002);
        assertEq(engine.lastMarkPrice(), 120_000_002);
        handler.assertModel();
    }

    function test_MissingFirstTickStaysPendingUntilExplicitExpiry() public {
        handler.commitOpen(0, 17, 80_000_002);
        uint64 id = handler.orders().head();
        vm.warp(vm.getBlockTimestamp() + 16);
        handler.executeHead(false);
        assertEq(handler.orders().head(), id);
        handler.executeBatch(1);
        assertEq(handler.orders().head(), id);
        assertEq(handler.historicalPriceRejections(), 2);
        assertEq(handler.stoppedBatches(), 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        handler.expirePending(0);
        assertEq(handler.orders().liveCount(), 0);
        handler.assertModel();
    }

    function test_BatchRetainsSuccessfulPrefixBeforeMissingHistoricalTick() public {
        handler.commitOpen(0, 17, 80_000_002);
        vm.warp(vm.getBlockTimestamp() + 1);
        handler.refreshMark(90_000_002);
        handler.commitOpen(1, 17, 90_000_002);
        uint64 pendingId = handler.orders().tail();
        vm.warp(vm.getBlockTimestamp() + 16);
        handler.executeBatch(2);
        assertEq(handler.traderState(0).lots, 17);
        assertEq(handler.traderState(1).lots, 0);
        assertEq(handler.orders().head(), pendingId);
        assertEq(handler.orders().liveCount(), 1);
        assertEq(handler.stoppedBatches(), 1);
        handler.assertModel();
    }

    function test_PausedOpenRefundPrecedesExpiryDuringNormalExecution() public {
        handler.commitOpen(0, 17, 80_000_002);
        handler.pausePending();
        vm.warp(vm.getBlockTimestamp() + 61);
        handler.executeHead(false);
        assertEq(handler.riskOffOrders(), 1);
        assertEq(handler.expiredOrders(), 0);
        assertEq(handler.expectedKeeper(), 0);
        handler.unpausePending();
        handler.assertModel();
    }

    function test_HistoricalFullCloseOffsetsUnpaidCarryWithHealingVpi() public {
        handler.openOrIncrease(0, 100, 120_000_002);
        handler.createDeferredClaimHistory();
        handler.exerciseUnpaidCarryVpiOffsetClose();
        assertGt(handler.carry().totalVpiOffset(), 0);
        handler.assertModel();
    }

    function test_FullCloseConsumesQueuedMarginsInFifoAndLaterOrdersFailExactly() public {
        handler.exerciseQueuedMarginFullClose();
        assertGt(handler.pendingMarginConsumed(), 1e6);
        assertEq(handler.orders().liveCount(), 0);
        handler.assertModel();
    }

    function test_FaultControlNormalCheckerRejectsMissingOrderMargin() public {
        handler.commitOpen(0, 117, 120_000_002);
        uint64 id = handler.orders().head();
        IMarginClearinghouse.OrderReservation memory corrupt = clearinghouse.getOrderReservation(id);
        corrupt.remainingAmountAssets -= 1;
        vm.mockCall(
            address(clearinghouse),
            abi.encodeWithSelector(clearinghouse.getOrderReservation.selector, id),
            abi.encode(corrupt)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

    function test_FaultControlNormalCheckerRejectsLostQueueHead() public {
        handler.commitOpen(0, 117, 120_000_002);
        vm.mockCall(address(router), abi.encodeWithSelector(router.nextExecuteId.selector), abi.encode(uint64(0)));
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

}
