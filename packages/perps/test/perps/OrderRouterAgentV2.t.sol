// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Production-stack integration coverage for the agent-facing V2 order lifecycle.
contract OrderRouterAgentV2Test is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant KEEPER = address(0xE0EC);

    uint256 internal constant EXECUTION_PRICE = 1e8;
    uint256 internal constant OPEN_SIZE = 100_000e18;
    uint256 internal constant OPEN_MARGIN_USDC = 10_000e6;
    uint256 internal constant OPEN_NOTIONAL_USDC = 100_000e6;

    IOrderLifecycleBook internal book;

    function setUp() public override {
        super.setUp();
        book = IOrderLifecycleBook(address(router.lifecycleBook()));
        _fundTrader(ALICE, 50_000e6);
        _fundTrader(BOB, 50_000e6);
    }

    function test_TransientContainmentDoesNotChangeExecutionConfigHash() public {
        bytes32 expectedHash = book.currentExecutionConfigHash();

        pool.pause();
        assertEq(book.currentExecutionConfigHash(), expectedHash, "LP-entry pause is runtime containment");
        pool.unpause();
        assertEq(book.currentExecutionConfigHash(), expectedHash, "LP-entry recovery must not change policy identity");

        pool.pauseLpEpochSettlement();
        assertTrue(pool.lpEpochSettlementPaused());
        assertEq(book.currentExecutionConfigHash(), expectedHash, "LP settlement hold is not order policy");
        pool.unpauseLpEpochSettlement();
        assertEq(book.currentExecutionConfigHash(), expectedHash, "LP settlement recovery must preserve order policy");

        routerAdmin.pause();
        assertEq(book.currentExecutionConfigHash(), expectedHash, "Router pause is runtime containment");
        routerAdmin.unpause();
        assertEq(book.currentExecutionConfigHash(), expectedHash, "Router recovery must preserve order policy");
    }

    function test_FreshCommitAndExactReplayHaveNoSecondSideEffect() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("pending-replay"));

        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);

        uint64 nextCommitIdBefore = router.nextCommitId();
        uint64 nextExecuteIdBefore = router.nextExecuteId();
        uint64 globalTailBefore = router.globalTailOrderId();
        uint64 accountHeadBefore = router.accountHeadOrderId(ALICE);
        uint256 pendingCountBefore = router.pendingOrderCounts(ALICE);
        uint256 freeSettlementBefore = _freeSettlementUsdc(ALICE);
        uint256 marginBefore = _remainingCommittedMargin(orderId);
        uint256 bountyBefore = book.pendingIntent(orderId).executionBountyUsdc;
        bytes32 pendingHashBefore = keccak256(abi.encode(book.pendingIntent(orderId)));

        vm.recordLogs();
        vm.prank(ALICE);
        uint64 replayedOrderId = router.commitOrder(request);
        Vm.Log[] memory replayLogs = vm.getRecordedLogs();

        assertEq(replayedOrderId, orderId, "exact replay must return the permanent order id");
        assertEq(replayLogs.length, 0, "exact replay must emit no second commit event");
        assertEq(router.nextCommitId(), nextCommitIdBefore, "exact replay must not consume an order id");
        assertEq(router.nextExecuteId(), nextExecuteIdBefore, "exact replay must not change the global head");
        assertEq(router.globalTailOrderId(), globalTailBefore, "exact replay must not change the global tail");
        assertEq(router.accountHeadOrderId(ALICE), accountHeadBefore, "exact replay must not relink the account");
        assertEq(router.pendingOrderCounts(ALICE), pendingCountBefore, "exact replay must not add a live order");
        assertEq(_freeSettlementUsdc(ALICE), freeSettlementBefore, "exact replay must not reserve twice");
        assertEq(_remainingCommittedMargin(orderId), marginBefore, "exact replay must not reserve margin twice");
        assertEq(book.pendingIntent(orderId).executionBountyUsdc, bountyBefore, "bounty must remain single-reserved");
        assertEq(
            keccak256(abi.encode(book.pendingIntent(orderId))), pendingHashBefore, "pending policy must be immutable"
        );
        assertEq(uint8(book.lifecycleStatus(orderId)), uint8(OrderV2Types.LifecycleStatus.Pending));
    }

    function test_ClientIdConflictRevertsWithoutChangingOriginalIntent() public {
        OrderV2Types.OrderRequest memory original = _openRequest(bytes32("conflict"));
        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(original);

        OrderV2Types.ClientIntent memory beforeIntent = book.clientIntent(ALICE, original.clientOrderId);
        OrderV2Types.OrderRequest memory conflicting = original;
        conflicting.bounds.maxExplicitFeesUsdc -= 1;
        bytes32 conflictingHash = book.hashOrderRequest(ALICE, conflicting);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
                ALICE,
                original.clientOrderId,
                beforeIntent.intentHash,
                conflictingHash
            )
        );
        router.commitOrder(conflicting);

        OrderV2Types.ClientIntent memory afterIntent = book.clientIntent(ALICE, original.clientOrderId);
        assertEq(afterIntent.orderId, orderId);
        assertEq(afterIntent.intentHash, beforeIntent.intentHash);
        assertEq(router.nextCommitId(), orderId + 1);
        assertEq(router.pendingOrderCounts(ALICE), 1);
    }

    function test_ClientIdIsNamespacedByAccount() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("shared-id"));

        vm.prank(ALICE);
        uint64 aliceOrderId = router.commitOrder(request);
        vm.prank(BOB);
        uint64 bobOrderId = router.commitOrder(request);

        OrderV2Types.ClientIntent memory aliceIntent = book.clientIntent(ALICE, request.clientOrderId);
        OrderV2Types.ClientIntent memory bobIntent = book.clientIntent(BOB, request.clientOrderId);
        assertEq(aliceIntent.orderId, aliceOrderId);
        assertEq(bobIntent.orderId, bobOrderId);
        assertTrue(aliceIntent.intentHash != bobIntent.intentHash, "the account is part of the intent domain");
        assertEq(router.pendingOrderCounts(ALICE), 1);
        assertEq(router.pendingOrderCounts(BOB), 1);
    }

    function test_RevertedFirstAttemptDoesNotConsumeClientIdOrReservation() public {
        uint256 quotedBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(OPEN_SIZE);
        _fundTrader(CAROL, quotedBountyUsdc);
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("retry-after-revert"));

        vm.prank(CAROL);
        vm.expectRevert();
        router.commitOrder(request);

        assertEq(book.clientIntent(CAROL, request.clientOrderId).orderId, 0, "revert must roll back id binding");
        assertEq(book.pendingIntent(1).account, address(0), "revert must roll back pending policy");
        assertEq(router.nextCommitId(), 1, "revert must not consume the proposed order id");
        assertEq(router.pendingOrderCounts(CAROL), 0, "revert must not leave a queue node");
        assertEq(_remainingCommittedMargin(1), 0, "revert must not leave committed margin");
        assertEq(_freeSettlementUsdc(CAROL), quotedBountyUsdc, "bounty lock must roll back with margin failure");

        _fundTrader(CAROL, OPEN_MARGIN_USDC + 1000e6);
        vm.prank(CAROL);
        uint64 orderId = router.commitOrder(request);

        assertEq(orderId, 1);
        assertEq(book.clientIntent(CAROL, request.clientOrderId).orderId, orderId);
        assertEq(uint8(book.lifecycleStatus(orderId)), uint8(OrderV2Types.LifecycleStatus.Pending));
    }

    function test_ExecutionNotionalEqualityAndDeadlineEqualityExecuteWithCanonicalReceipt() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("inclusive-equality"));
        request.bounds.maxExecutionNotionalUsdc = OPEN_NOTIONAL_USDC;
        request.bounds.validUntil = uint64(block.timestamp + 1);

        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        uint256 keeperBefore = _settlementBalance(KEEPER);

        bytes[] memory updateData = _mockPythUpdateData(EXECUTION_PRICE);
        assertEq(block.timestamp, request.bounds.validUntil, "setup must execute exactly at the inclusive deadline");
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.Executed));
        assertEq(uint8(result.pendingReason), uint8(OrderV2Types.PendingReason.None));
        assertTrue(result.receiptHash != bytes32(0));
        assertEq(_positionSize(ALICE), OPEN_SIZE, "equality at the notional bound must execute");
        assertEq(_settlementBalance(KEEPER) - keeperBefore, pending.executionBountyUsdc);
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(router.nextExecuteId(), 0);
        assertEq(_remainingCommittedMargin(orderId), 0);
        assertEq(book.pendingIntent(orderId).account, address(0));

        OrderV2Types.CompactOutcome memory outcome = book.outcome(orderId);
        assertEq(outcome.account, ALICE);
        assertEq(outcome.clientOrderId, request.clientOrderId);
        assertEq(outcome.intentHash, pending.intentHash);
        assertEq(uint8(outcome.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.Executed));
        assertEq(uint8(outcome.executionMode), uint8(OrderV2Types.ExecutionMode.Live));
        assertEq(uint8(outcome.priceSource), uint8(OrderV2Types.PriceSource.OracleExecution));
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid));
        assertEq(outcome.executor, KEEPER);
        assertEq(outcome.bountyRecipient, KEEPER);
        assertEq(outcome.executionPrice, EXECUTION_PRICE);
        assertEq(outcome.bountyUsdc, pending.executionBountyUsdc);
        assertEq(outcome.receiptHash, result.receiptHash);

        (
            bytes32 eventReceiptHash,
            uint64 terminalBlock,
            uint64 terminalTime,
            OrderV2Types.OrderReceipt memory receipt
        ) = _findFinalizedReceipt(logs, orderId);
        assertEq(eventReceiptHash, result.receiptHash);
        assertEq(receipt.orderId, orderId);
        assertEq(receipt.account, ALICE);
        assertEq(receipt.clientOrderId, request.clientOrderId);
        assertEq(receipt.intentHash, pending.intentHash);
        assertEq(receipt.economics.executionNotionalUsdc, OPEN_NOTIONAL_USDC);
        assertEq(receipt.economics.postPositionSize, OPEN_SIZE);
        assertEq(receipt.economics.postSettlementBalanceUsdc, _settlementBalance(ALICE));
        assertEq(
            eventReceiptHash,
            keccak256(
                abi.encode(
                    book.RECEIPT_TYPEHASH(),
                    block.chainid,
                    address(book),
                    address(router),
                    terminalBlock,
                    terminalTime,
                    receipt
                )
            ),
            "event receipt must use the canonical domain-separated hash"
        );
    }

    function test_ExecutionNotionalOneAtomOverBoundFailsWithoutApplyingPosition() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("notional-one-atom"));
        request.bounds.maxExecutionNotionalUsdc = OPEN_NOTIONAL_USDC - 1;

        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        uint256 aliceBefore = _settlementBalance(ALICE);
        uint256 keeperBefore = _settlementBalance(KEEPER);

        bytes[] memory updateData = _mockPythUpdateData(EXECUTION_PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.ConstraintViolation));
        assertEq(_positionSize(ALICE), 0, "constraint failure must not apply the planned position");
        assertEq(aliceBefore - _settlementBalance(ALICE), pending.executionBountyUsdc, "only bounty may leave account");
        assertEq(_settlementBalance(KEEPER) - keeperBefore, pending.executionBountyUsdc);
        assertEq(_remainingCommittedMargin(orderId), 0);
        assertEq(router.pendingOrderCounts(ALICE), 0);

        OrderV2Types.CompactOutcome memory outcome = book.outcome(orderId);
        assertEq(uint8(outcome.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.ConstraintViolation));
        assertEq(uint8(outcome.failedConstraint), uint8(OrderV2Types.ConstraintKind.ExecutionNotional));
        assertEq(
            outcome.failureSelector, ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector
        );
        assertEq(outcome.executor, KEEPER);
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid));
        assertEq(outcome.receiptHash, result.receiptHash);
    }

    function test_OneSecondPastDeadlineExpiresBeforeOracleWork() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("expired"));
        request.bounds.validUntil = uint64(block.timestamp + 1);

        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        uint256 pythUpdatesBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 uniqueParsesBefore = baseMockPyth.parseUniqueCallCount();
        vm.warp(uint256(request.bounds.validUntil) + 1);

        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, new bytes[](0));

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.Expired));
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), pythUpdatesBefore, "expiry must precede Pyth update");
        assertEq(baseMockPyth.parseUniqueCallCount(), uniqueParsesBefore, "expiry must precede historical parsing");
        assertEq(_positionSize(ALICE), 0);
        assertEq(_remainingCommittedMargin(orderId), 0);

        OrderV2Types.CompactOutcome memory outcome = book.outcome(orderId);
        assertEq(uint8(outcome.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.Expired));
        assertEq(uint8(outcome.priceSource), uint8(OrderV2Types.PriceSource.None));
        assertEq(outcome.executionPrice, 0);
        assertEq(outcome.oraclePublishTime, 0);
        assertEq(outcome.executor, KEEPER);
        assertEq(outcome.bountyUsdc, pending.executionBountyUsdc);
    }

    function test_FinalizedConfigDriftInvalidatesBeforeOracleWork() public {
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        engineAdmin.proposeCalendarConfig(config);
        uint256 activationTime = engineAdmin.calendarConfigActivationTime();
        vm.warp(activationTime - 1);

        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("config-drift"));
        bytes32 expectedConfigHash = request.bounds.expectedConfigHash;
        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        uint256 pythUpdatesBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 uniqueParsesBefore = baseMockPyth.parseUniqueCallCount();

        vm.warp(activationTime);
        engineAdmin.finalizeCalendarConfig();
        bytes32 observedConfigHash = book.currentExecutionConfigHash();
        assertTrue(observedConfigHash != expectedConfigHash, "finalized version must change the digest");

        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, new bytes[](0));

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.ConfigMismatch));
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), pythUpdatesBefore, "config mismatch must precede Pyth");
        assertEq(baseMockPyth.parseUniqueCallCount(), uniqueParsesBefore, "config mismatch must precede history");
        assertEq(_positionSize(ALICE), 0);

        OrderV2Types.CompactOutcome memory outcome = book.outcome(orderId);
        assertEq(outcome.expectedConfigHash, expectedConfigHash);
        assertEq(outcome.observedConfigHash, observedConfigHash);
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.ConfigMismatch));
        assertEq(uint8(outcome.priceSource), uint8(OrderV2Types.PriceSource.None));
        assertEq(outcome.executionPrice, 0);
        assertEq(outcome.executor, KEEPER);
    }

    function test_UnknownEngineFailureIsRetryableAndPreservesReservations() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("unknown-engine"));
        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);

        OrderV2Types.PendingIntent memory pendingBefore = book.pendingIntent(orderId);
        uint256 marginBefore = _remainingCommittedMargin(orderId);
        uint256 freeSettlementBefore = _freeSettlementUsdc(ALICE);
        uint256 keeperBefore = _settlementBalance(KEEPER);
        vm.mockCallRevert(
            address(engine),
            abi.encodeWithSelector(engine.processOrderTyped.selector),
            abi.encodeWithSignature("Unknown(uint256)", 7)
        );

        bytes[] memory updateData = _mockPythUpdateData(EXECUTION_PRICE);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.clearMockedCalls();

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV2Types.PendingReason.EngineFailure));
        assertEq(result.receiptHash, bytes32(0));
        assertEq(uint8(book.lifecycleStatus(orderId)), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(book.outcome(orderId).receiptHash, bytes32(0));
        assertEq(keccak256(abi.encode(book.pendingIntent(orderId))), keccak256(abi.encode(pendingBefore)));
        assertEq(_remainingCommittedMargin(orderId), marginBefore, "item rollback must restore committed margin");
        assertEq(_freeSettlementUsdc(ALICE), freeSettlementBefore, "item rollback must restore bucket classification");
        assertEq(_settlementBalance(KEEPER), keeperBefore, "retryable failure must pay no bounty");
        assertEq(router.pendingOrderCounts(ALICE), 1);
        assertEq(router.nextExecuteId(), orderId);
        assertEq(_positionSize(ALICE), 0);
        assertEq(_countFinalizedReceipts(logs), 0, "retryable dependency failure must emit no terminal receipt");
    }

    function test_MalformedEngineSuccessIsRetryableAndPreservesPendingOrder() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("malformed-engine"));
        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        uint256 marginBefore = _remainingCommittedMargin(orderId);
        uint256 bountyBefore = book.pendingIntent(orderId).executionBountyUsdc;

        vm.mockCall(address(engine), abi.encodeWithSelector(engine.processOrderTyped.selector), abi.encode(uint256(1)));
        bytes[] memory updateData = _mockPythUpdateData(EXECUTION_PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        vm.clearMockedCalls();

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV2Types.PendingReason.EngineFailure));
        assertEq(uint8(book.lifecycleStatus(orderId)), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(book.pendingIntent(orderId).executionBountyUsdc, bountyBefore);
        assertEq(_remainingCommittedMargin(orderId), marginBefore);
        assertEq(router.pendingOrderCounts(ALICE), 1);
        assertEq(_positionSize(ALICE), 0);
    }

    function test_ZeroBountyMaximumMeansZeroAllowance() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("zero-bounty-cap"));
        request.bounds.maxExecutionBountyUsdc = 0;
        uint256 quotedBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(OPEN_SIZE);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound.selector, quotedBountyUsdc, 0
            )
        );
        router.commitOrder(request);

        assertEq(book.clientIntent(ALICE, request.clientOrderId).orderId, 0);
        assertEq(router.nextCommitId(), 1);
        assertEq(router.pendingOrderCounts(ALICE), 0);
    }

    function test_RiskOffReceiptAttributesExternalCleanerAndRefundsBountyToAccount() public {
        OrderV2Types.OrderRequest memory request = _openRequest(bytes32("risk-off-receipt"));
        vm.prank(ALICE);
        uint64 orderId = router.commitOrder(request);
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        uint256 keeperBefore = _settlementBalance(KEEPER);

        routerAdmin.pause();
        vm.prank(KEEPER);
        router.clearRiskOffOrder(orderId);

        OrderV2Types.CompactOutcome memory outcome = book.outcome(orderId);
        assertEq(uint8(outcome.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.RiskOff));
        assertEq(outcome.executor, KEEPER, "receipt must retain the external cleaner");
        assertEq(outcome.bountyUsdc, pending.executionBountyUsdc);
        assertEq(outcome.bountyRecipient, ALICE);
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.RefundedToAccount));
        assertEq(uint8(outcome.priceSource), uint8(OrderV2Types.PriceSource.None));
        assertEq(outcome.executionPrice, 0);
        assertEq(_settlementBalance(KEEPER), keeperBefore, "risk-off cleaner must not receive the order bounty");
        assertEq(book.pendingIntent(orderId).account, address(0));
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(_remainingCommittedMargin(orderId), 0);
    }

    function _openRequest(
        bytes32 clientOrderId
    ) internal view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = clientOrderId;
        request.side = CfdTypes.Side.BULL;
        request.sizeDelta = OPEN_SIZE;
        request.marginDelta = OPEN_MARGIN_USDC;
        request.targetPrice = 1;
        request.isClose = false;
        request.bounds = OrderV2Types.ExecutionBounds({
            validUntil: uint64(block.timestamp + router.maxOrderAge()),
            allowedExecutionModes: 7,
            expectedConfigHash: book.currentExecutionConfigHash(),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _findFinalizedReceipt(
        Vm.Log[] memory logs,
        uint64 orderId
    )
        internal
        returns (
            bytes32 receiptHash,
            uint64 terminalBlock,
            uint64 terminalTime,
            OrderV2Types.OrderReceipt memory receipt
        )
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(book) && logs[i].topics.length == 4
                    && uint64(uint256(logs[i].topics[1])) == orderId
            ) {
                return abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV2Types.OrderReceipt));
            }
        }
        fail("missing canonical OrderFinalized receipt");
    }

    function _countFinalizedReceipts(
        Vm.Log[] memory logs
    ) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics.length == 4) {
                ++count;
            }
        }
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

}
