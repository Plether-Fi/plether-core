// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "../../CfdClosePreviewTestBase.sol";
import {CfdClosePreview, ICloseAdmission} from "@plether/perps/CfdClosePreview.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {Vm} from "forge-std/Vm.sol";

contract DepositFreeCloseTest is CfdClosePreviewTestBase {

    struct Balances {
        uint256 custody;
        uint256 margin;
        uint256 keeper;
        uint256 wallet;
    }

    function _request(
        CfdTypes.Side side,
        uint256 size
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("deposit-free", router.nextCommitId()));
        request.side = side;
        request.sizeDelta = size;
        request.targetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
        request.isClose = true;
        request.bounds = _bounds();
        request.bounds.submitBy = uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds());
        request.bounds.executionWindowSeconds = uint32(router.maxExecutionWindowSeconds());
        request.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
    }

    function _closeAtZeroFree(
        CfdTypes.Side side,
        uint256 size,
        address executor
    ) internal {
        _openNormally(side, 0);
        OrderV3Types.OrderRequest memory request = _request(side, size);
        Balances memory beforeState = Balances(
            clearinghouse.balanceAssets(ACCOUNT),
            clearinghouse.pnlPledgeAssets(ACCOUNT),
            clearinghouse.balanceAssets(KEEPER),
            settlementToken.balanceOf(ACCOUNT)
        );
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, executor, PRICE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(uint8(reservation.state), uint8(IMarginClearinghouse.BountyReservationState.Active));
        assertEq(reservation.freeFundedAssets, 0);
        assertEq(reservation.amountAssets, 0);
        assertEq(clearinghouse.balanceAssets(ACCOUNT), beforeState.custody, "reservation does not debit custody");
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), beforeState.margin);
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);
        OrderV3Types.ExecutionAssessment memory assessed =
            policyEvaluator.assessCommittedOrder(address(engine), id, executor, PRICE);
        assertEq(keccak256(abi.encode(preview.assessment)), keccak256(abi.encode(assessed)));
        assertEq(
            assessed.close.safeMarginReleaseAssets,
            assessed.close.actionChargeFromReleasedMarginAssets + assessed.close.netReleasedMarginAssets
        );
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.recordLogs();
        vm.prank(executor);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, assessed);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE - size);
        assertEq(clearinghouse.balanceAssets(ACCOUNT), assessed.postSettlementBalanceAssets);
        assertEq(
            clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, assessed.close.postFreeSettlementAssets
        );
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        assertEq(settlementToken.balanceOf(ACCOUNT), beforeState.wallet, "no wallet funding");
        assertEq(
            clearinghouse.balanceAssets(KEEPER) - beforeState.keeper, executor == KEEPER ? reservation.amountAssets : 0
        );
    }

    function test_StandardFullLongZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, KEEPER);
    }

    function test_StandardPartialCloseHasZeroBounty() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE / 2, KEEPER);
    }

    function test_CommitmentSidecarFailureAndMalformedReturnRollBack() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        address target = address(engine.settlementSidecar());
        bytes memory callData =
            abi.encodeCall(ICfdEngineSettlementSidecar.reserveCloseOrderExecutionBounty, (ACCOUNT, SIZE));
        bytes32 beforeBuckets = keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT)));
        bytes memory failure = hex"abcdef0123456789";
        vm.mockCallRevert(target, callData, failure);
        vm.expectRevert(failure);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        vm.clearMockedCalls();
        vm.mockCall(target, callData, new bytes(223));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        vm.clearMockedCalls();
        assertEq(beforeBuckets, keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT))));
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "reentrancy guard is restored");
    }

    function test_FailedCloseBookFailureRollsBackPaymentAndQueueRemoval() public {
        _failedCloseSettlementRollsBack(3);
    }

    function _failedCloseSettlementRollsBack(
        uint8 fault
    ) private {
        _openNormally(CfdTypes.Side.SHORT, 0);
        uint256 pledgeBeforeCommit = clearinghouse.pnlPledgeAssets(ACCOUNT);
        uint256 keeperBefore = clearinghouse.balanceAssets(KEEPER);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);

        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        bytes32 beforeState = _failedCloseState(id);
        bytes memory failure = abi.encodeWithSignature("InjectedSettlementFailure(uint8)", fault);
        vm.mockCallRevert(
            address(router.lifecycleBook()), abi.encodeWithSelector(IOrderLifecycleBook.finalize.selector), failure
        );
        vm.expectRevert(failure);
        vm.prank(KEEPER);
        router.expireOrder(id);
        assertEq(_failedCloseState(id), beforeState, "terminal item must roll back to its post-commitment state");
        vm.clearMockedCalls();
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory retried = router.expireOrder(id);
        assertEq(uint8(retried.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), pledgeBeforeCommit);
        assertEq(clearinghouse.balanceAssets(KEEPER), keeperBefore);

        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(router.nextExecuteId(), 0);
        _assertFailedBountyReceipt(id);
    }

    function _assertFailedBountyReceipt(
        uint64 id
    ) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(router.lifecycleBook()) || logs[i].topics.length != 4
                    || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
            ) {
                continue;
            }
            (,, uint64 terminalTime, OrderV3Types.OrderReceipt memory receipt) =
                abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
            assertTrue(router.lifecycleBook().verifyReceipt(receipt, terminalTime));
            assertEq(receipt.orderId, id);
            assertEq(receipt.bounty.bountyPaidAssets, 0);
            assertEq(receipt.bounty.bountyRefundedAssets, 0);
            assertEq(receipt.bounty.bountyForfeitedAssets, 0);
            assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None));
            assertEq(receipt.bountyRecipient, address(0));
            found = true;
        }
        assertTrue(found, "missing authenticated mixed-failure receipt");
    }

    function _failedCloseState(
        uint64 id
    ) private view returns (bytes32) {
        (bool ok, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSelector(ICfdEngineCore.positions.selector, ACCOUNT));
        assertTrue(ok);
        bytes32 balances = keccak256(
            abi.encode(
                clearinghouse.getAccountAssetBuckets(ACCOUNT),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id),
                clearinghouse.balanceAssets(KEEPER)
            )
        );
        bytes32 positionState = keccak256(abi.encode(position, engine.unsettledCarryAssets(ACCOUNT)));
        return keccak256(
            abi.encode(
                balances,
                positionState,
                router.lifecycleBook().pendingIntent(id),
                router.accountHeadOrderId(ACCOUNT),
                router.pendingOrderCounts(ACCOUNT),
                router.pendingCloseSize(ACCOUNT),
                router.nextExecuteId()
            )
        );
    }

    function test_StandardFullShortZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE, KEEPER);
    }

    function test_StandardPartialLongZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE / 2, KEEPER);
    }

    function test_StandardPartialShortSelfZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE / 2, ACCOUNT);
    }

    function test_ProspectiveCloseRejectsAnOpeningRequest() public {
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        request.isClose = false;
        vm.expectRevert(CfdClosePreview.CfdClosePreview__NotCloseOrder.selector);
        previewer.previewClose(address(engine), ACCOUNT, request, KEEPER, PRICE);
        ICloseAdmission admission = ICloseAdmission(router.liquidationBatchSidecar());
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NotCloseOrder.selector);
        admission.previewCloseAdmission(ACCOUNT, request);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function test_CommittedAssessmentRejectsUnknownAndExpiredOrdersWithoutCleanup() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ReservationMismatch.selector, uint64(999)
            )
        );
        policyEvaluator.assessCommittedOrder(address(engine), 999, KEEPER, PRICE);
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes32 pendingBefore = keccak256(abi.encode(router.lifecycleBook().pendingIntent(id)));
        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__CommittedPolicyChanged.selector, id
            )
        );
        policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE);
        assertEq(keccak256(abi.encode(router.lifecycleBook().pendingIntent(id))), pendingBefore);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1, "a read cannot consume the order");
        router.expireOrder(id);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function test_CommittedAssessmentRejectsChangedConfigurationAndCanBeRetried() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes32 pendingBefore = keccak256(abi.encode(router.lifecycleBook().pendingIntent(id)));
        // Synthetic configuration observation isolates this rejection from execution-window expiry.
        vm.mockCall(
            address(router.lifecycleBook()),
            abi.encodeWithSelector(IOrderLifecycleBook.currentExecutionConfigHash.selector),
            abi.encode(bytes32(uint256(request.bounds.expectedConfigHash) ^ 1))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__CommittedPolicyChanged.selector, id
            )
        );
        policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE);
        vm.clearMockedCalls();
        assertEq(keccak256(abi.encode(router.lifecycleBook().pendingIntent(id))), pendingBefore);
        OrderV3Types.ExecutionAssessment memory assessment =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE);
        assertEq(assessment.postPositionSize, 0, "the unchanged order remains assessable");
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
    }

    function test_CloseReplayAndPermissionlessExpiry() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        vm.prank(ACCOUNT);
        assertEq(router.commitOrder(request), id);
        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id).state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled)
        );
    }

    function test_AbandonedStandardZeroBountyClosesPermissionlessCleanupUnblocksFifo() public {
        _abandonedZeroBountyQueue(false);
    }

    function test_AbandonedStandardZeroBountyClosesAutoPruneUnblocksFifo() public {
        _abandonedZeroBountyQueue(true);
    }

    function _abandonedZeroBountyQueue(
        bool autoPrune
    ) private {
        _openNormally(CfdTypes.Side.LONG, 0);
        // The same position can submit another attempt after expiry. Each round must unblock another account.
        for (uint256 round; round < 3; ++round) {
            _abandonedZeroBountyRound(autoPrune, address(uint160(0xF0110 + round)));
        }
    }

    function _abandonedZeroBountyRound(
        bool autoPrune,
        address follower
    ) private {
        _fundTrader(follower, 1000e6);
        OrderV3Types.OrderRequest memory abandoned = _request(CfdTypes.Side.LONG, SIZE);
        abandoned.bounds.executionWindowSeconds = 5;
        vm.prank(ACCOUNT);
        uint64 head = router.commitOrder(abandoned);
        assertEq(router.lifecycleBook().pendingIntent(head).executionBountyAssets, 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, head).state),
            uint8(IMarginClearinghouse.BountyReservationState.Active)
        );
        uint256 custody = clearinghouse.balanceAssets(ACCOUNT);
        uint256 margin = clearinghouse.pnlPledgeAssets(ACCOUNT);
        uint256 keeperBalance = clearinghouse.balanceAssets(KEEPER);
        uint64 next;
        {
            OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
            request.isClose = false;
            request.marginDelta = 250e6;
            request.targetPrice = PRICE;
            vm.prank(follower);
            next = router.commitOrder(request);
        }
        uint256 followerBounty = router.lifecycleBook().pendingIntent(next).executionBountyAssets;
        assertGt(followerBounty, 0, "an abandoned zero-bounty head blocks a rewarded order");
        assertEq(router.nextExecuteId(), head);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        router.executeOrder(next, new bytes[](0));
        uint64 deadline = router.lifecycleBook().orderTiming(head).executionDeadline;
        vm.warp(deadline);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotExpired.selector);
        router.expireOrder(head);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        router.executeOrder(next, new bytes[](0));
        assertEq(router.nextExecuteId(), head, "deadline equality cannot skip the head");
        vm.warp(deadline + 1);

        if (!autoPrune) {
            // Explicit expiry must work even when every oracle call fails, with no update data or ETH attached.
            vm.mockCallRevert(
                address(router.pletherOracle()), new bytes(0), abi.encodeWithSignature("OracleUnavailable()")
            );
            vm.recordLogs();
            vm.prank(address(0xC1EA));
            OrderV3Types.ExecutionResult memory expired = router.expireOrder(head);
            assertEq(uint8(expired.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
            _assertZeroBountyExpiryReceipt(vm.getRecordedLogs(), head);
            vm.clearMockedCalls();
            assertEq(router.nextExecuteId(), next);
            assertEq(clearinghouse.balanceAssets(address(0xC1EA)), 0, "cleanup caller earns no reward");
            assertEq(router.pendingOrderCounts(follower), 1, "expiry does not consume the follower");
        }
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(next, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        if (autoPrune) {
            _assertZeroBountyExpiryReceipt(vm.getRecordedLogs(), head);
        }
        assertEq(clearinghouse.balanceAssets(KEEPER) - keeperBalance, followerBounty, "only follower pays a reward");
        assertEq(clearinghouse.balanceAssets(ACCOUNT), custody, "expiry does not collect more funds");
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), margin);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE, "abandoned close did not execute");
        (uint256 followerSize,,,,,,) = engine.positions(follower);
        assertEq(followerSize, SIZE);
        assertEq(router.nextExecuteId(), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, head).state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled)
        );
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotPending.selector);
        router.expireOrder(head);
        vm.prank(ACCOUNT);
        assertEq(router.commitOrder(abandoned), head, "exact replay cannot recreate an expired queue entry");
        assertEq(router.nextExecuteId(), 0);
    }

    function _assertZeroBountyExpiryReceipt(
        Vm.Log[] memory logs,
        uint64 id
    ) private view {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && uint64(uint256(logs[i].topics[1])) == id
            ) {
                (,, uint64 terminalTime, OrderV3Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertTrue(router.lifecycleBook().verifyReceipt(receipt, terminalTime));
                assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
                assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Expired));
                assertEq(receipt.bountyAssets, 0);
                assertEq(receipt.bounty.bountyEntitlementAssets, 0);
                assertEq(
                    receipt.bounty.bountyPaidAssets + receipt.bounty.bountyRefundedAssets
                        + receipt.bounty.bountyForfeitedAssets,
                    0
                );
                assertEq(receipt.bountyRecipient, address(0));
                assertEq(receipt.economics.preSettlementBalanceAssets, receipt.economics.postSettlementBalanceAssets);
                return;
            }
        }
        revert("missing zero-bounty expiry receipt");
    }

    function test_CloseExpiryUsesCommittedDeadlineAfterSubmitBy() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        uint64 reviewedAt = uint64(vm.getBlockTimestamp());
        request.bounds.submitBy = reviewedAt + 120;
        request.bounds.executionWindowSeconds = 60;
        vm.warp(reviewedAt + 110);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        uint64 deadline = router.lifecycleBook().orderTiming(id).executionDeadline;
        assertEq(deadline, reviewedAt + 170);
        vm.warp(request.bounds.submitBy + 1);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotExpired.selector);
        router.expireOrder(id);
        policyEvaluator.assessCommittedOrder(address(engine), id, ACCOUNT, PRICE);
        vm.warp(deadline);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotExpired.selector);
        router.expireOrder(id);
        vm.warp(deadline + 1);
        OrderV3Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        assertEq(router.lifecycleBook().orderTiming(id).executionDeadline, deadline);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function testFuzz_ZeroFreeReductions(
        uint8 lots,
        bool shortSide
    ) public {
        uint256 size = bound(uint256(lots), 20, 99) * 100e18;
        _closeAtZeroFree(shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG, size, KEEPER);
    }

    function _openMaxAtZeroFree(
        CfdTypes.Side side
    ) internal returns (uint256 size) {
        _fundTrader(ACCOUNT, 1000e6);
        {
            uint256 margin = 1000e6 - router.maxOpenOrderExecutionBountyAssets();
            ICfdEngineLens.MaxOpenQuote memory quote = engineLens.quoteMaxOpen(ACCOUNT, side, margin, PRICE);
            vm.prank(ACCOUNT);
            uint64 openId = router.commitOrder(side, quote.maxSizeDelta, margin, PRICE, false);
            bytes[] memory update = _mockPythUpdateData(PRICE);
            vm.prank(KEEPER);
            OrderV3Types.ExecutionResult memory result = router.executeOrder(openId, update);
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
            (size,,,,,,) = engine.positions(ACCOUNT);
            assertGt(size, 0);
            assertEq(size, quote.maxSizeDelta);
            uint256 free = clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets;
            if (free != 0) {
                vm.prank(ACCOUNT);
                clearinghouse.withdraw(ACCOUNT, free);
            }
        }
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);
    }

    function _maxOpenClose(
        CfdTypes.Side side,
        bool isPartial
    ) private {
        uint256 size = _openMaxAtZeroFree(side);
        uint256 supply = settlementToken.totalSupply();
        uint256 closeSize = isPartial ? size / 2 / CfdTypes.SIZE_QUANTUM * CfdTypes.SIZE_QUANTUM : size;
        OrderV3Types.OrderRequest memory request = _request(side, closeSize);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, size - closeSize);
        assertEq(settlementToken.totalSupply(), supply, "no assistance mint");
    }

    function test_MaxOpenOrdinaryFullLong() public {
        _maxOpenClose(CfdTypes.Side.LONG, false);
    }

    function test_MaxOpenOrdinaryFullShort() public {
        _maxOpenClose(CfdTypes.Side.SHORT, false);
    }

    function test_MaxOpenOrdinaryPartialLong() public {
        _maxOpenClose(CfdTypes.Side.LONG, true);
    }

    function test_MaxOpenOrdinaryPartialShort() public {
        _maxOpenClose(CfdTypes.Side.SHORT, true);
    }

    function test_RepeatedUnpaidExpiryLeavesPledgeUntouched() public {
        _fundTrader(ACCOUNT, 100e6);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 50e6, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory opened = router.executeOrder(openId, update);
        assertEq(uint8(opened.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        uint256 free = clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets;
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, free);
        uint256 keeperBefore = clearinghouse.balanceAssets(KEEPER);
        for (uint256 attempt; attempt < 60; ++attempt) {
            OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, 1000e18);
            request.bounds.executionWindowSeconds = 1;
            vm.prank(ACCOUNT);
            uint64 id = router.commitOrder(request);
            uint256 reservedPledge = clearinghouse.pnlPledgeAssets(ACCOUNT);
            uint256 custodyAfterCommit = clearinghouse.balanceAssets(ACCOUNT);
            IMarginClearinghouse.BountyReservation memory reservation =
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
            assertEq(reservation.freeFundedAssets, 0);
            assertEq(reservation.amountAssets, 0);
            vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
            vm.prank(KEEPER);
            OrderV3Types.ExecutionResult memory expired = router.expireOrder(id);
            assertEq(uint8(expired.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
            assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), reservedPledge, "expiry leaves the original pledge intact");
            assertEq(
                clearinghouse.balanceAssets(ACCOUNT),
                custodyAfterCommit,
                "expiry checkpoints but does not collect carry"
            );
            assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);

            assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
            assertEq(router.pendingOrderCounts(ACCOUNT), 0);
            assertEq(router.nextExecuteId(), 0);
        }
        assertEq(clearinghouse.balanceAssets(KEEPER), keeperBefore, "pledge cannot fund failed-attempt compensation");
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 1000e18);
    }

    function test_LiquidationWinsAndClearsZeroBountyReservation() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(110_000_000);
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, update);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id).state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled)
        );
    }

    function test_CloseWinsThenLiquidationHasNoPosition() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, ACCOUNT);
        bytes[] memory update = _mockPythUpdateData(110_000_000);
        vm.expectRevert();
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, update);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
    }

    function _systemValue() private view returns (uint256) {
        return clearinghouse.balanceAssets(ACCOUNT) + clearinghouse.balanceAssets(KEEPER)
            + clearinghouse.balanceAssets(engine.protocolTreasury()) + settlementToken.balanceOf(address(pool));
    }

    function testFuzz_PartialThenFullConservesSystemValue(
        uint8 lotSeed,
        bool shortSide
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _openNormally(side, 0);
        uint256 initialValue = _systemValue();
        uint256 initialSupply = settlementToken.totalSupply();
        uint256 first = bound(uint256(lotSeed), 20, 80) * CfdTypes.SIZE_QUANTUM;
        for (uint256 i; i < 2; ++i) {
            uint256 size = i == 0 ? first : SIZE - first;
            OrderV3Types.OrderRequest memory request = _request(side, size);
            vm.prank(ACCOUNT);
            uint64 id = router.commitOrder(request);
            bytes[] memory update = _mockPythUpdateData(PRICE);
            vm.prank(KEEPER);
            OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
            assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        }
        assertEq(_systemValue(), initialValue, "splitting cannot manufacture settlement or pool cash");
        assertEq(settlementToken.totalSupply(), initialSupply);
        assertEq(engine.traderClaimBalanceAssets(ACCOUNT), 0, "flat-price splitting cannot manufacture claims");
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
    }

    // Synthetic lifecycle-entitlement corruption; custody and the authentic zero-value record remain untouched.
    function _corruptEntitlement(
        uint64 id,
        uint256 amount
    ) private {
        vm.record();
        router.lifecycleBook().pendingIntent(id);
        (bytes32[] memory slots,) = vm.accesses(address(router.lifecycleBook()));
        // PendingIntent.account begins the mapping value; entitlement is its fourth storage word.
        vm.store(address(router.lifecycleBook()), bytes32(uint256(slots[0]) + 3), bytes32(amount));
        assertEq(router.lifecycleBook().pendingIntent(id).executionBountyAssets, amount);
    }

    function _mismatchedExpiry() private {
        _openNormally(CfdTypes.Side.SHORT, 0);
        uint256 margin = clearinghouse.pnlPledgeAssets(ACCOUNT);
        uint256 custody = clearinghouse.balanceAssets(ACCOUNT);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        _corruptEntitlement(id, 1);
        bytes32 beforeState = keccak256(
            abi.encode(
                clearinghouse.getAccountAssetBuckets(ACCOUNT),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)
            )
        );
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(
            beforeState,
            keccak256(
                abi.encode(
                    clearinghouse.getAccountAssetBuckets(ACCOUNT),
                    clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)
                )
            ),
            "retry rolls back every classification"
        );
        uint256 keeper = clearinghouse.balanceAssets(KEEPER);
        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        vm.prank(KEEPER);
        result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.ExpiredReservationMismatch));
        assertEq(clearinghouse.balanceAssets(KEEPER), keeper, "mismatch pays no keeper");
        assertEq(clearinghouse.balanceAssets(ACCOUNT), custody, "refund creates no custody");
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), margin, "expiry leaves the original pledge unchanged");
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotPending.selector);
        router.expireOrder(id);
    }

    function test_EntitlementAboveBackingRetryAndExpiryRefund() public {
        _mismatchedExpiry();
    }

    function test_ExpiryCanRemoveLaterOrderWithoutExecutingOutOfFifo() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE / 2);
        vm.prank(ACCOUNT);
        uint64 first = router.commitOrder(request);
        // Later unpaid close orders remain legal without free-settlement bounty funding.

        request = _request(CfdTypes.Side.LONG, SIZE / 2);
        request.bounds.executionWindowSeconds -= 1;
        vm.prank(ACCOUNT);
        uint64 second = router.commitOrder(request);
        vm.warp(router.lifecycleBook().orderTiming(second).executionDeadline + 1);
        router.expireOrder(second);
        assertEq(router.accountHeadOrderId(ACCOUNT), first);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
    }

    function test_ZeroBountyStillRequiresAnOpenPosition() public {
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoQueuedPosition.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
    }

    // Synthetic reservation corruption is deliberately separate from public-lifecycle acceptance fixtures.
    function _reservationAnomaly(
        uint8 kind
    ) private {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        vm.record();
        clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        (bytes32[] memory slots,) = vm.accesses(address(clearinghouse));
        if (kind == 0) {
            // An already-settled record; do not invent a second refund.
            vm.prank(address(router));
            clearinghouse.takeBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, id);
        } else if (kind == 1) {
            // Foreign ownership must not be overwritten by order cleanup.
            uint256 word = uint256(vm.load(address(clearinghouse), slots[0]));
            vm.store(
                address(clearinghouse),
                slots[0],
                bytes32((word & ~uint256(type(uint160).max)) | uint160(address(0xBAD)))
            );
        } else if (kind == 2) {
            // Amount and free funding disagree; cleanup cannot invent a refund.
            uint256 word = uint256(vm.load(address(clearinghouse), slots[0]));
            vm.store(address(clearinghouse), slots[0], bytes32(word + (uint256(1) << 160)));
        } else if (kind == 3) {
            // Missing record with disputed classifications left intact: no fabricated refund.
            for (uint256 i; i < 2; ++i) {
                vm.store(address(clearinghouse), bytes32(uint256(slots[0]) + i), bytes32(0));
            }
        } else if (kind == 4) {
            // Increase free funding without increasing the recorded amount.
            bytes32 fundingSlot = bytes32(uint256(slots[0]) + 1);
            uint256 word = uint256(vm.load(address(clearinghouse), fundingSlot));
            vm.store(address(clearinghouse), fundingSlot, bytes32(word + (uint256(1) << 8)));
            IMarginClearinghouse.BountyReservation memory forged =
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
            assertEq(forged.freeFundedAssets, 1);
        }
        bytes32 bucketsBefore = keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT)));
        bytes32 reservationBefore =
            keccak256(abi.encode(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)));
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory retried = router.executeOrder(id, update);
        assertEq(uint8(retried.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(retried.pendingReason), uint8(OrderV3Types.PendingReason.ReceiptFailure));
        assertEq(keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT))), bucketsBefore);
        assertEq(
            keccak256(abi.encode(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id))),
            reservationBefore
        );

        assertEq(router.accountHeadOrderId(ACCOUNT), id);
        uint256 custody = clearinghouse.balanceAssets(ACCOUNT);
        uint256 reserve = clearinghouse.actionReserveAssets(ACCOUNT);
        uint256 keeper = clearinghouse.balanceAssets(KEEPER);
        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.ExpiredReservationMismatch));
        assertEq(clearinghouse.balanceAssets(ACCOUNT), custody);
        assertEq(clearinghouse.actionReserveAssets(ACCOUNT), reserve);
        assertEq(clearinghouse.balanceAssets(KEEPER), keeper);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        IMarginClearinghouse.BountyReservation memory afterRecord =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        if (kind == 1) {
            assertEq(afterRecord.account, address(0xBAD));
        }
        if (kind == 2 || kind == 4) {
            assertEq(uint8(afterRecord.state), uint8(IMarginClearinghouse.BountyReservationState.Quarantined));
        }

        assertEq(
            clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets,
            0,
            "quarantine leaves free settlement unchanged"
        );
        assertEq(router.nextExecuteId(), 0);
    }

    function test_WrongFreeFundingRetriesThenQuarantines() public {
        _reservationAnomaly(4);
    }

    function test_SettledReservationExpiryMovesNoFunds() public {
        _reservationAnomaly(0);
    }

    function test_WrongOwnerReservationExpiryLeavesForeignRecord() public {
        _reservationAnomaly(1);
    }

    function test_AmountMismatchExpiryQuarantinesBacking() public {
        _reservationAnomaly(2);
    }

    function test_MissingReservationExpiryMovesNoFunds() public {
        _reservationAnomaly(3);
    }

}

contract DepositFreeCarryTest is DepositFreeCloseTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 1000;
    }

    function test_MaxOpenFullLongAfterOneHourCarryWithoutDeposit() public {
        _maxFullCloseAfterCarry(CfdTypes.Side.LONG, 1 hours);
    }

    function test_MaxOpenFullShortAfterOneHourCarryWithoutDeposit() public {
        _maxFullCloseAfterCarry(CfdTypes.Side.SHORT, 1 hours);
    }

    function test_MaxOpenFullLongAfterThreeDaysCarryWithoutDeposit() public {
        _maxFullCloseAfterCarry(CfdTypes.Side.LONG, 3 days);
    }

    function test_MaxOpenFullShortAfterThreeDaysCarryWithoutDeposit() public {
        _maxFullCloseAfterCarry(CfdTypes.Side.SHORT, 3 days);
    }

    function _maxFullCloseAfterCarry(
        CfdTypes.Side side,
        uint256 elapsed
    ) private {
        uint256 size = _openMaxAtZeroFree(side);
        Balances memory beforeState = Balances(
            clearinghouse.balanceAssets(ACCOUNT),
            clearinghouse.pnlPledgeAssets(ACCOUNT),
            clearinghouse.balanceAssets(KEEPER),
            settlementToken.balanceOf(ACCOUNT)
        );
        uint256 supply = settlementToken.totalSupply();
        // Keep price flat to isolate carry. Only time advances; no account storage or funding is injected.
        vm.warp(vm.getBlockTimestamp() + elapsed);
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);
        OrderV3Types.OrderRequest memory request = _request(side, size);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        uint256 commitmentCarry = router.lifecycleBook().pendingIntent(id).commitment.carryCollectedAssets;
        assertGt(commitmentCarry, 0, "aged position must pay carry at commitment");
        assertEq(beforeState.custody - clearinghouse.balanceAssets(ACCOUNT), commitmentCarry);
        uint256 bounty = 0;
        {
            IMarginClearinghouse.BountyReservation memory reservation =
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
            assertEq(reservation.freeFundedAssets, 0);
            assertEq(reservation.amountAssets, bounty);
        }
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), beforeState.margin - commitmentCarry - bounty);
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);

        // Carry also accrues between commitment and execution, inside the order's execution window.
        vm.warp(vm.getBlockTimestamp() + 10);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        OrderV3Types.ExecutionAssessment memory assessed =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE);
        assertGt(assessed.carryAssets, commitmentCarry, "execution must collect additional carry");
        assertEq(assessed.close.actionChargeWaivedAssets, 0, "ordinary close pays all charges");
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertAccruedCarryReceipt(id, assessed, commitmentCarry);

        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), 0);
        assertEq(engine.unsettledCarryAssets(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        assertEq(clearinghouse.balanceAssets(KEEPER) - beforeState.keeper, bounty);
        assertEq(
            beforeState.custody - clearinghouse.balanceAssets(ACCOUNT),
            assessed.carryAssets + _engineExecutionFeeAssets(size, PRICE) + bounty,
            "custody pays carry and execution fee; zero close bounty moves no cash"
        );
        assertEq(
            clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, assessed.close.postFreeSettlementAssets
        );
        assertEq(settlementToken.balanceOf(ACCOUNT), beforeState.wallet, "no additional wallet funding");
        assertEq(settlementToken.totalSupply(), supply, "no assistance mint");
    }

    function _assertAccruedCarryReceipt(
        uint64 id,
        OrderV3Types.ExecutionAssessment memory assessed,
        uint256 commitmentCarry
    ) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertReceipt(logs, id, assessed);
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && uint64(uint256(logs[i].topics[1])) == id
            ) {
                (,, uint64 terminalTime, OrderV3Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertTrue(router.lifecycleBook().verifyReceipt(receipt, terminalTime));
                assertEq(receipt.commitment.carryCollectedAssets, commitmentCarry);
                assertEq(receipt.economics.carryAssets, int256(assessed.carryAssets));
                return;
            }
        }
        fail("missing authenticated carry receipt");
    }

    function test_CommitmentCarryIncludedOnceAndBoundedBeforeAdmission() public {
        _openNormally(CfdTypes.Side.SHORT, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, KEEPER, PRICE);
        assertGt(preview.commitment.carryCollectedAssets, 0);
        assertEq(preview.assessment.carryAssets, preview.commitment.carryCollectedAssets);
        uint256 custody = clearinghouse.balanceAssets(ACCOUNT);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        assertEq(custody - clearinghouse.balanceAssets(ACCOUNT), preview.commitment.carryCollectedAssets);
        OrderV3Types.ExecutionAssessment memory actual =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE);
        assertEq(actual.grossAccountDebitAssets, preview.assessment.grossAccountDebitAssets);
        assertEq(actual.actionChargeAssessedAssets, preview.assessment.actionChargeAssessedAssets);
    }

    function test_CommitmentGrossAndActionBoundsRollBackCarryAndReservation() public {
        _openNormally(CfdTypes.Side.SHORT, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, KEEPER, PRICE);
        uint256 carry = preview.commitment.carryCollectedAssets;
        assertGt(carry, 0);
        bytes32 buckets = keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT)));
        uint64 nextId = router.nextCommitId();
        for (uint256 i; i < 2; ++i) {
            request.bounds.maxGrossAccountDebitAssets = i == 0 ? carry - 1 : type(uint256).max;
            request.bounds.maxActionChargeAssets = i == 1 ? carry - 1 : type(uint256).max;
            vm.expectPartialRevert(IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector);
            vm.prank(ACCOUNT);
            router.commitOrder(request);
            assertEq(keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ACCOUNT))), buckets);
            assertEq(router.nextCommitId(), nextId);
            assertEq(router.pendingOrderCounts(ACCOUNT), 0);
            assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), 0);
        }
    }

}
