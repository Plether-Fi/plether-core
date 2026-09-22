// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterV3ExecutionSidecar} from "@plether/perps/OrderRouterV3ExecutionSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterV3ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV3ExecutionHost.sol";

/// @notice Fault injection at the production Router's self-call boundary must preserve the signed intent,
///         reservations and original deadline, so a corrected dependency can retry the same order.
contract OrderRouterV3FailureRecoveryTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant KEEPER = address(0xBEEF);
    uint256 internal constant PRICE = 1e8;
    IOrderLifecycleBook internal book;
    uint64 internal orderId;
    bytes32 internal pendingHash;
    uint256 internal freeSettlement;
    uint256 internal keeperSettlement;

    function setUp() public override {
        super.setUp();
        book = IOrderLifecycleBook(address(router.lifecycleBook()));
        _fundTrader(ALICE, 50_000e6);
        OrderV3Types.OrderRequest memory request;
        request.clientOrderId = bytes32("recoverable-v3");
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = 10_000e18;
        request.marginDelta = 1000e6;
        request.targetPrice = 1;
        request.bounds.submitBy = uint64(block.timestamp + 120);
        request.bounds.executionWindowSeconds = 60;
        request.bounds.allowedExecutionModes = 7;
        request.bounds.expectedConfigHash = book.currentExecutionConfigHash();
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;
        vm.prank(ALICE);
        orderId = router.commitOrder(request);
        pendingHash = keccak256(abi.encode(book.pendingIntent(orderId)));
        freeSettlement = _freeSettlementUsdc(ALICE);
        keeperSettlement = _settlementBalance(KEEPER);
    }

    function test_MalformedAssessmentPreservesIntentAndCanRetry() public {
        vm.mockCall(address(policyEvaluator), abi.encodeWithSelector(policyEvaluator.assessOrder.selector), hex"01");
        _assertPendingThenRecover(OrderV3Types.PendingReason.EngineFailure);
    }

    function test_AssessmentStateMismatchRollsBackEngineAndBountyThenRetries() public {
        // Correct ABI and execution mode, but fabricated settlement/position values.
        // The real Engine executes before the post-state consistency check rejects this assessment.
        OrderV3Types.ExecutionAssessment memory assessment;
        assessment.mode = OrderV3Types.ExecutionMode.Live;
        vm.mockCall(
            address(policyEvaluator),
            abi.encodeWithSelector(policyEvaluator.assessOrder.selector),
            abi.encode(assessment)
        );
        _assertPendingThenRecover(OrderV3Types.PendingReason.EngineFailure);
    }

    function test_BountyMismatchRollsBackEngineAndCanRetry() public {
        IOrderRouterV3ExecutionHost.BountySettlement memory settlement;
        vm.mockCall(
            address(router), abi.encodeWithSelector(router.settleV3OrderFromSidecar.selector), abi.encode(settlement)
        );
        _assertPendingThenRecover(OrderV3Types.PendingReason.ReceiptFailure);
    }

    function test_ReceiptFailureRollsBackEngineAndBountyThenRetries() public {
        vm.mockCallRevert(address(book), abi.encodeWithSelector(book.finalize.selector), hex"12345678");
        _assertPendingThenRecover(OrderV3Types.PendingReason.ReceiptFailure);
    }

    function test_InvalidItemActionsCannotBypassPendingOrderPolicy() public {
        IOrderRouterV3ExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.action = IOrderRouterV3ExecutionHost.ItemAction.Expire;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__InvalidItemAction.selector, orderId
            )
        );
        vm.prank(address(router));
        router.executeV3OrderItemFromSidecar(request);
        request.action = IOrderRouterV3ExecutionHost.ItemAction.RiskOff;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        vm.prank(address(router));
        router.executeV3OrderItemFromSidecar(request);
        _assertPreserved();
    }

    function test_HistoricalBoundaryAndCloseOnlyRemainRetryable() public {
        IOrderRouterV3ExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.openExecutionCloseOnly = true;
        vm.prank(address(router));
        OrderV3Types.ExecutionResult memory result = router.executeV3OrderItemFromSidecar(request);
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.CloseOnly));
        request.openExecutionCloseOnly = false;
        request.oraclePublishTime = book.orderTiming(orderId).commitTimestamp;
        vm.roll(block.number + 1);
        vm.prank(address(router));
        result = router.executeV3OrderItemFromSidecar(request);
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.MevBoundary));
        _assertPreserved();
    }

    function test_SettledReceiptRejectsUnrelatedReasonOrBounty() public {
        IOrderRouterV3ExecutionHost.SettledTerminalInput memory input = _riskOffInput();
        input.reason = OrderV3Types.TerminalReason.Expired;
        _expectInvalidReceipt(input);
        input = _riskOffInput();
        input.bountyUsdc++;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__OrderIdentityMismatch.selector, orderId
            )
        );
        vm.prank(address(router));
        router.recordSettledTerminal(input);
        _assertPreserved();
    }

    function test_SettledReceiptRejectsFabricatedFailureEvidence() public {
        // Each field must be empty; a trusted callback cannot manufacture a user-policy failure.
        for (uint256 field; field < 7; ++field) {
            IOrderRouterV3ExecutionHost.SettledTerminalInput memory input = _riskOffInput();
            if (field == 0) {
                input.failure.selector = bytes4(0x12345678);
            }
            if (field == 1) {
                input.failure.category = 1;
            }
            if (field == 2) {
                input.failure.code = 1;
            }
            if (field == 3) {
                input.failure.constraint = OrderV3Types.ConstraintKind.PostPositionEquity;
            }
            if (field == 4) {
                input.failure.actual = 1;
            }
            if (field == 5) {
                input.failure.limit = 1;
            }
            if (field == 6) {
                input.failure.revertDataHash = bytes32(uint256(1));
            }
            _expectInvalidReceipt(input);
        }
        _assertPreserved();
    }

    function test_RiskOffReceiptRejectsWrongBountyRecipientOrDisposition() public {
        IOrderRouterV3ExecutionHost.SettledTerminalInput memory input = _riskOffInput();
        input.bountyRecipient = KEEPER;
        _expectInvalidReceipt(input);
        input = _riskOffInput();
        input.bountyDisposition = OrderV3Types.BountyDisposition.Forfeited;
        _expectInvalidReceipt(input);
        _assertPreserved();
    }

    function test_RiskOffReceiptRejectsFabricatedExecutionEvidence() public {
        for (uint256 field; field < 5; ++field) {
            IOrderRouterV3ExecutionHost.SettledTerminalInput memory input = _riskOffInput();
            if (field == 0) {
                input.executionMode = OrderV3Types.ExecutionMode.Live;
            }
            if (field == 1) {
                input.priceSource = OrderV3Types.PriceSource.Liquidation;
            }
            if (field == 2) {
                input.executionPrice = PRICE;
            }
            if (field == 3) {
                input.oraclePublishTime = uint64(block.timestamp);
            }
            if (field == 4) {
                input.priceReachedEngine = true;
            }
            _expectInvalidReceipt(input);
        }
        _assertPreserved();
        // Failed evidence must not prevent the real risk-off path from refunding and finalizing.
        routerAdmin.pause();
        vm.prank(KEEPER);
        router.clearRiskOffOrder(orderId);
        assertEq(uint8(book.outcome(orderId).reason), uint8(OrderV3Types.TerminalReason.RiskOff));
        assertEq(book.outcome(orderId).bountyRecipient, ALICE);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_LiquidationReceiptRejectsWrongBountyAndPriceEvidence() public {
        IOrderRouterV3ExecutionHost.SettledTerminalInput memory input = _riskOffInput();
        input.reason = OrderV3Types.TerminalReason.AccountLiquidated;
        _expectInvalidReceipt(input);
        input.bountyDisposition = OrderV3Types.BountyDisposition.Forfeited;
        input.bountyRecipient = PROTOCOL_TREASURY_ACCOUNT;
        _expectInvalidReceipt(input); // No liquidation price source.
        input.priceSource = OrderV3Types.PriceSource.Liquidation;
        input.priceReachedEngine = true;
        _expectInvalidReceipt(input);
        _assertPreserved();
    }

    function _riskOffInput() internal view returns (IOrderRouterV3ExecutionHost.SettledTerminalInput memory input) {
        input.orderId = orderId;
        input.executor = KEEPER;
        input.reason = OrderV3Types.TerminalReason.RiskOff;
        input.bountyUsdc = book.pendingIntent(orderId).executionBountyUsdc;
        input.bountyDisposition = OrderV3Types.BountyDisposition.RefundedToAccount;
        input.bountyRecipient = ALICE;
    }

    function _expectInvalidReceipt(
        IOrderRouterV3ExecutionHost.SettledTerminalInput memory input
    ) internal {
        vm.expectRevert(OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__InvalidSettledReason.selector);
        vm.prank(address(router));
        router.recordSettledTerminal(input);
    }

    function _assertPreserved() internal view {
        assertEq(keccak256(abi.encode(book.pendingIntent(orderId))), pendingHash, "intent and timing must survive");
        assertEq(uint8(book.lifecycleStatus(orderId)), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(book.outcome(orderId).receiptHash, bytes32(0), "no false terminal evidence");
        assertEq(_remainingCommittedMargin(orderId), 1000e6);
        assertEq(_freeSettlementUsdc(ALICE), freeSettlement);
        assertEq(_settlementBalance(KEEPER), keeperSettlement, "no failed-attempt bounty");
        assertEq(router.pendingOrderCounts(ALICE), 1);
        assertEq(router.nextExecuteId(), orderId);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0, "engine effects must roll back");
    }

    function _assertPendingThenRecover(
        OrderV3Types.PendingReason reason
    ) internal {
        uint64 deadline = book.orderTiming(orderId).executionDeadline;
        bytes[] memory updates = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updates);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(reason));
        assertEq(result.receiptHash, bytes32(0));
        _assertPreserved();
        vm.clearMockedCalls();
        updates = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        result = router.executeOrder(orderId, updates);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(book.outcome(orderId).timing.executionDeadline, deadline, "recovery must not restart the clock");
        assertEq(router.nextExecuteId(), 0);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 10_000e18);
    }

}
