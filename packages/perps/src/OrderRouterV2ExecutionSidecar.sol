// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterV2ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV2ExecutionHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";

/// @title OrderRouterV2ExecutionSidecar
/// @notice Stateless delegate module for V2 order oracle orchestration, bounded execution, and receipts.
/// @dev This contract declares no mutable storage. It must be deployed independently and supplied to a fresh Router;
///      calling a stateful entrypoint on the sidecar address itself is rejected. Router self-calls isolate each batch
///      item, so an unknown Engine or receipt failure cannot roll back already completed items.
/// @custom:security-contact contact@plether.com
contract OrderRouterV2ExecutionSidecar is IOrderRouterErrors {

    /// @notice A stateful entrypoint was called directly rather than through delegatecall.
    error OrderRouterV2ExecutionSidecar__OnlyDelegateCall();
    /// @notice An item-only entrypoint was not reached through the Router's external self-call boundary.
    error OrderRouterV2ExecutionSidecar__OnlyRouterSelf();
    /// @notice Router queue data and lifecycle-book identity disagree.
    error OrderRouterV2ExecutionSidecar__OrderIdentityMismatch(uint64 orderId);
    /// @notice A Router-supplied item action is not currently applicable.
    error OrderRouterV2ExecutionSidecar__InvalidItemAction(uint64 orderId);
    /// @notice A trusted stateless dependency returned a malformed successful payload.
    error OrderRouterV2ExecutionSidecar__MalformedSuccess(address target, uint256 returndataLength);
    /// @notice An unrecognized, malformed, empty, or panic external failure must leave the order pending.
    error OrderRouterV2ExecutionSidecar__RetryableFailure(address target, bytes4 selector, uint256 returndataLength);
    /// @notice Router settlement did not consume exactly the lifecycle-book bounty.
    error OrderRouterV2ExecutionSidecar__BountyMismatch(uint256 expectedUsdc, uint256 actualUsdc);
    /// @notice A receipt-only helper was supplied a reason outside its risk-off/liquidation domain.
    error OrderRouterV2ExecutionSidecar__InvalidSettledReason();
    /// @notice Evaluator output disagreed with the actual pre- or post-settlement protocol state.
    error OrderRouterV2ExecutionSidecar__AssessmentStateMismatch(uint8 field, uint256 expected, uint256 actual);

    uint256 internal constant MAX_RISK_OFF_REFUNDS_PER_CALL = 64;
    uint256 internal constant POST_ENGINE_GAS_RESERVE = 1_000_000;
    uint256 internal constant EVALUATOR_RETURN_GAS_RESERVE = 250_000;
    uint256 internal constant EXECUTION_ASSESSMENT_ABI_LENGTH = 19 * 32;

    /// @notice The separately deployed sidecar address used only to distinguish direct calls from delegatecalls.
    address public immutable SELF;

    struct AccountState {
        uint256 settlementBalanceUsdc;
        uint256 traderClaimUsdc;
        uint256 positionSize;
        uint256 positionMarginUsdc;
    }

    struct TerminalClassification {
        bool terminal;
        bool plannerFailure;
        bool plannerIsClose;
        OrderV2Types.TerminalReason reason;
        OrderV2Types.FailureDetails failure;
    }

    struct OracleResult {
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint64 publishTime;
        uint256 fee;
        OrderV2Types.ExecutionMode mode;
        bool oracleFrozen;
        bool closeOnly;
    }

    struct BatchExecutionState {
        address executor;
        uint64 riskOffCutoff;
        uint256 riskOffRefunds;
        uint256 terminalPrunes;
        uint256 pythFeeTotal;
        IPletherOracle.BatchOrderPriceCache oracleCache;
    }

    struct PreparedExecutionContext {
        IOrderRouterV2ExecutionHost host;
        IOrderLifecycleBook book;
        CfdTypes.Order order;
        OrderV2Types.PendingIntent pending;
        bytes32 observedConfigHash;
        uint256 minimumEngineGas;
    }

    constructor() {
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        _requireDelegateCall();
        _;
    }

    modifier onlyRouterSelf() {
        _requireRouterSelf();
        _;
    }

    function _requireDelegateCall() private view {
        if (address(this) == SELF) {
            revert OrderRouterV2ExecutionSidecar__OnlyDelegateCall();
        }
    }

    function _requireRouterSelf() private view {
        _requireDelegateCall();
        if (msg.sender != address(this)) {
            revert OrderRouterV2ExecutionSidecar__OnlyRouterSelf();
        }
    }

    /// @notice Executes one queue target after bounded oracle-independent head cleanup.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable onlyDelegateCall returns (OrderV2Types.ExecutionResult memory result) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        uint64 head = host.nextExecuteId();
        if (head == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }

        address executor = msg.sender;
        uint64 riskOffCutoff = _riskOffCutoff(host);
        uint256 riskOffRefunds = 0;
        uint256 terminalPrunes = 0;
        bool madeProgress;

        // Every full-value refund in this loop is immediately followed by a return, so one call cannot refund twice.
        // slither-disable-start msg-value-loop
        while (head != 0 && head <= orderId) {
            IOrderRouterV2ExecutionHost.OrderView memory orderView = host.getV2OrderForSidecar(head);
            _requireOrderView(head, orderView);
            (IOrderRouterV2ExecutionHost.ItemAction action, bool terminalBeforeOracle) =
                _preOracleAction(host, orderView.order, head, riskOffCutoff);
            if (!terminalBeforeOracle) {
                break;
            }
            if (action == IOrderRouterV2ExecutionHost.ItemAction.RiskOff) {
                if (riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL) {
                    result = _pendingResult(head, OrderV2Types.PendingReason.CleanupLimit);
                    _refundEth(host, executor, msg.value);
                    return result;
                }
                ++riskOffRefunds;
            } else {
                if (terminalPrunes == host.maxPruneOrdersPerCall()) {
                    result = _pendingResult(head, OrderV2Types.PendingReason.CleanupLimit);
                    _refundEth(host, executor, msg.value);
                    return result;
                }
                ++terminalPrunes;
            }

            IOrderRouterV2ExecutionHost.ItemRequest memory request = _preOracleItem(host, head, action, executor);
            uint256 itemGas = _itemCallGas();
            if (itemGas == 0) {
                result = _pendingResult(head, OrderV2Types.PendingReason.InsufficientGas);
                _refundEth(host, executor, msg.value);
                return result;
            }
            try host.executeV2OrderItemFromSidecar{gas: itemGas}(request) returns (
                OrderV2Types.ExecutionResult memory itemResult
            ) {
                result = itemResult;
                madeProgress = true;
            } catch (bytes memory revertData) {
                result = _pendingResult(head, _pendingReasonForRevert(revertData));
                _refundEth(host, executor, msg.value);
                return result;
            }
            if (head == orderId) {
                _refundEth(host, executor, msg.value);
                return result;
            }
            head = host.nextExecuteId();
        }
        // slither-disable-end msg-value-loop

        head = host.nextExecuteId();
        if (head == 0) {
            _refundEth(host, executor, msg.value);
            return result;
        }
        if (head != orderId) {
            if (madeProgress) {
                _refundEth(host, executor, msg.value);
                return result;
            }
            revert OrderRouter__OrderNotQueueHead();
        }

        IOrderRouterV2ExecutionHost.OrderView memory target = host.getV2OrderForSidecar(head);
        _requireOrderView(head, target);
        OracleResult memory oracleResult = _prepareSingleOracle(host, target.order, executor, pythUpdateData);
        IOrderRouterV2ExecutionHost.ItemRequest memory executionRequest =
            _executionItem(host, target.order, oracleResult, executor);
        uint256 executionGas = _itemCallGas();
        if (executionGas == 0) {
            result = _pendingResult(head, OrderV2Types.PendingReason.InsufficientGas);
        } else {
            try host.executeV2OrderItemFromSidecar{gas: executionGas}(executionRequest) returns (
                OrderV2Types.ExecutionResult memory executionResult
            ) {
                result = executionResult;
            } catch (bytes memory revertData) {
                result = _pendingResult(head, _pendingReasonForRevert(revertData));
            }
        }
        _refundEth(host, executor, msg.value - oracleResult.fee);
    }

    /// @notice Executes consecutive FIFO orders through a bound with prepared-item rollback isolation.
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable onlyDelegateCall returns (OrderV2Types.BatchResult memory batchResult) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        _validateBatchBounds(host, maxOrderId);

        BatchExecutionState memory state;
        state.executor = msg.sender;
        state.riskOffCutoff = _riskOffCutoff(host);

        while (host.nextExecuteId() != 0 && host.nextExecuteId() <= maxOrderId) {
            uint64 orderId = host.nextExecuteId();
            IOrderRouterV2ExecutionHost.OrderView memory orderView = host.getV2OrderForSidecar(orderId);
            _requireOrderView(orderId, orderView);

            (IOrderRouterV2ExecutionHost.ItemAction action, bool terminalBeforeOracle) =
                _preOracleAction(host, orderView.order, orderId, state.riskOffCutoff);
            if (terminalBeforeOracle) {
                if (action == IOrderRouterV2ExecutionHost.ItemAction.RiskOff) {
                    if (state.riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL) {
                        batchResult.stopReason = OrderV2Types.PendingReason.CleanupLimit;
                        break;
                    }
                    unchecked {
                        ++state.riskOffRefunds;
                    }
                } else {
                    if (state.terminalPrunes == host.maxPruneOrdersPerCall()) {
                        batchResult.stopReason = OrderV2Types.PendingReason.CleanupLimit;
                        break;
                    }
                    unchecked {
                        ++state.terminalPrunes;
                    }
                }

                IOrderRouterV2ExecutionHost.ItemRequest memory cleanup =
                    _preOracleItem(host, orderId, action, state.executor);
                uint256 cleanupGas = _itemCallGas();
                if (cleanupGas == 0) {
                    batchResult.stopReason = OrderV2Types.PendingReason.InsufficientGas;
                    break;
                }
                try host.executeV2OrderItemFromSidecar{gas: cleanupGas}(cleanup) returns (
                    OrderV2Types.ExecutionResult memory cleanupResult
                ) {
                    if (cleanupResult.status != OrderV2Types.LifecycleStatus.Pending) {
                        ++batchResult.terminalCount;
                    }
                    continue;
                } catch (bytes memory revertData) {
                    batchResult.stopReason = _pendingReasonForRevert(revertData);
                    break;
                }
            }

            (
                bool oracleResolved,
                OracleResult memory oracleResult,
                IPletherOracle.BatchOrderPriceCache memory nextCache
            ) = _prepareBatchOracle(host, orderView.order, pythUpdateData, state);
            state.oracleCache = nextCache;
            state.pythFeeTotal += oracleResult.fee;
            if (!oracleResolved) {
                batchResult.stopReason = OrderV2Types.PendingReason.HistoricalPriceUnavailable;
                break;
            }

            IOrderRouterV2ExecutionHost.ItemRequest memory executionRequest =
                _executionItem(host, orderView.order, oracleResult, state.executor);
            uint256 executionGas = _itemCallGas();
            if (executionGas == 0) {
                batchResult.stopReason = OrderV2Types.PendingReason.InsufficientGas;
                break;
            }
            try host.executeV2OrderItemFromSidecar{gas: executionGas}(executionRequest) returns (
                OrderV2Types.ExecutionResult memory executionResult
            ) {
                if (executionResult.status == OrderV2Types.LifecycleStatus.Pending) {
                    batchResult.stopReason = executionResult.pendingReason;
                    break;
                }
                ++batchResult.terminalCount;
            } catch (bytes memory revertData) {
                batchResult.stopReason = _pendingReasonForRevert(revertData);
                break;
            }
        }

        batchResult.nextOrderId = host.nextExecuteId();
        _refundEth(host, state.executor, msg.value - state.pythFeeTotal);
    }

    /// @notice Executes or terminally settles one order inside a Router self-call rollback frame.
    /// @dev The Router callback bearing this selector must delegate the exact calldata back to this sidecar.
    function executeV2OrderItemFromSidecar(
        IOrderRouterV2ExecutionHost.ItemRequest calldata request
    ) external onlyRouterSelf returns (OrderV2Types.ExecutionResult memory result) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        IOrderRouterV2ExecutionHost.OrderView memory orderView = host.getV2OrderForSidecar(request.orderId);
        _requireOrderView(request.orderId, orderView);
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(request.orderId);
        if (pending.account == address(0) || pending.account != orderView.order.account) {
            revert OrderRouterV2ExecutionSidecar__OrderIdentityMismatch(request.orderId);
        }

        uint64 riskOffCutoff = _riskOffCutoff(host);
        if (_isRiskOffOpen(request.orderId, orderView.order.isClose, riskOffCutoff)) {
            return _settleRiskOff(host, book, orderView.order, pending, request, riskOffCutoff);
        }
        if (request.action == IOrderRouterV2ExecutionHost.ItemAction.RiskOff) {
            revert OrderRouter__OrderNotRiskOff();
        }

        if (block.timestamp > pending.bounds.validUntil) {
            return _settleNonEngine(
                host,
                book,
                orderView.order,
                pending,
                request,
                OrderV2Types.TerminalReason.Expired,
                OrderV2Types.FailureDetails(bytes4(0), 0, 0, OrderV2Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }

        bytes32 observedConfigHash = book.currentExecutionConfigHash();
        bytes32 expectedConfigHash = pending.bounds.expectedConfigHash;
        // Zero is reserved for Router-created protected orders whose child intent is deliberately unpinned.
        if (expectedConfigHash != bytes32(0) && observedConfigHash != expectedConfigHash) {
            IOrderRouterV2ExecutionHost.ItemRequest memory configRequest = request;
            configRequest.observedConfigHash = observedConfigHash;
            return _settleNonEngine(
                host,
                book,
                orderView.order,
                pending,
                configRequest,
                OrderV2Types.TerminalReason.ConfigMismatch,
                OrderV2Types.FailureDetails(bytes4(0), 0, 0, OrderV2Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }

        if (request.action != IOrderRouterV2ExecutionHost.ItemAction.Execute) {
            revert OrderRouterV2ExecutionSidecar__InvalidItemAction(request.orderId);
        }
        return _executePrepared(host, book, orderView.order, pending, request, observedConfigHash);
    }

    /// @notice Records a receipt after a Router risk-off or liquidation path already settled the order.
    /// @dev Book finalization is deliberately last and is not caught; any failure rolls back the enclosing item frame.
    function recordSettledTerminal(
        IOrderRouterV2ExecutionHost.SettledTerminalInput calldata input
    ) external onlyRouterSelf returns (OrderV2Types.ExecutionResult memory result) {
        if (
            input.reason != OrderV2Types.TerminalReason.RiskOff
                && input.reason != OrderV2Types.TerminalReason.AccountLiquidated
        ) {
            revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
        }
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(input.orderId);
        if (pending.account == address(0) || input.bountyUsdc != pending.executionBountyUsdc) {
            revert OrderRouterV2ExecutionSidecar__OrderIdentityMismatch(input.orderId);
        }
        _validateSettledTerminalInput(host, pending, input);

        AccountState memory state = _accountState(ICfdEngineCore(host.engine()), pending.account);
        OrderV2Types.OrderReceipt memory receipt = _settledTerminalBaseReceipt(pending, input);
        receipt.bountyUsdc = input.bountyUsdc;
        receipt.bountyRecipient = input.bountyRecipient;
        receipt.bountyDisposition = input.bountyDisposition;
        receipt.failure = input.failure;
        receipt.economics = _stateOnlyEconomics(state, state);
        return _finalizeReceipt(book, receipt);
    }

    function _executePrepared(
        IOrderRouterV2ExecutionHost host,
        IOrderLifecycleBook book,
        CfdTypes.Order memory order,
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        bytes32 observedConfigHash
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        if (!order.isClose && request.openExecutionCloseOnly) {
            return _pendingResult(order.orderId, OrderV2Types.PendingReason.CloseOnly);
        }
        // Exact block equality is the intended same-block MEV boundary, not a balance or price comparison.
        // slither-disable-next-line incorrect-equality
        if (!request.oracleFrozen && block.number == order.commitBlock) {
            return _pendingResult(order.orderId, OrderV2Types.PendingReason.SameBlock);
        }
        if (!request.oracleFrozen && request.oraclePublishTime <= order.commitTime) {
            return _pendingResult(order.orderId, OrderV2Types.PendingReason.MevBoundary);
        }
        if (!OrderValidationLib.checkSlippage(order, request.executionPrice)) {
            return _settleNonEngine(
                host,
                book,
                order,
                pending,
                request,
                OrderV2Types.TerminalReason.Slippage,
                OrderV2Types.FailureDetails(bytes4(0), 0, 0, OrderV2Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }
        uint256 minimumEngineGas = host.minEngineGas();
        if (!_hasExecutionEnvelope(minimumEngineGas)) {
            return _pendingResult(order.orderId, OrderV2Types.PendingReason.InsufficientGas);
        }

        PreparedExecutionContext memory context;
        context.host = host;
        context.book = book;
        context.order = order;
        context.pending = pending;
        context.observedConfigHash = observedConfigHash;
        context.minimumEngineGas = minimumEngineGas;
        return _executeAssessed(context, request);
    }

    function _executeAssessed(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        ICfdEngineCore engine_ = ICfdEngineCore(context.host.engine());
        AccountState memory preState = _accountState(engine_, context.order.account);

        // Classification-only release is inside this independently revertible item frame. Unknown failures below
        // therefore restore the reservation, while successful assessment sees the same free-settlement state as Engine.
        IMarginClearinghouse(engine_.clearinghouse()).releaseOrderReservationForTerminalCleanup(context.order.orderId);

        (address evaluator, bool assessed, bytes memory assessmentData) =
            _callPolicyEvaluator(context, request, address(engine_));
        if (!assessed) {
            return _settleAssessmentFailure(context, request, preState, evaluator, assessmentData);
        }
        OrderV2Types.ExecutionAssessment memory assessment = _decodeAssessment(evaluator, assessmentData);

        (bool engineSucceeded, bytes memory engineData) = _callEngine(context, request, address(engine_));
        if (!engineSucceeded) {
            return _settleEngineFailure(context, request, preState, address(engine_), engineData);
        }
        if (engineData.length != 0) {
            revert OrderRouterV2ExecutionSidecar__MalformedSuccess(address(engine_), engineData.length);
        }

        uint256 bountyUsdc = _settleExecutedOrder(context, request);
        return _finalizeExecutedOrder(context, request, assessment, preState, bountyUsdc);
    }

    function _finalizeExecutedOrder(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        OrderV2Types.ExecutionAssessment memory assessment,
        AccountState memory preState,
        uint256 bountyUsdc
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        AccountState memory postState = _accountState(ICfdEngineCore(context.host.engine()), context.order.account);
        _assertAssessmentState(assessment, request.executionMode, preState, postState);
        OrderV2Types.OrderReceipt memory receipt =
            _preparedBaseReceipt(context, request, OrderV2Types.TerminalReason.Executed, assessment.mode, true);
        receipt.status = OrderV2Types.LifecycleStatus.Executed;
        _setPaidBounty(receipt, bountyUsdc, request.executor);
        receipt.economics = _assessmentEconomics(assessment, preState, postState);
        return _finalizeReceipt(context.book, receipt);
    }

    function _settleExecutedOrder(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request
    ) private returns (uint256 bountyUsdc) {
        bountyUsdc = context.host
            .settleV2OrderFromSidecar(
                context.order.orderId,
                true,
                request.executor,
                request.executionPrice,
                request.bountyAccountingPrice,
                request.bountyAccountingPublishTime
            );
        _requireBounty(context.pending.executionBountyUsdc, bountyUsdc);
    }

    function _callPolicyEvaluator(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        address engineAddress
    ) private view returns (address evaluator, bool assessed, bytes memory assessmentData) {
        evaluator = context.host.policyEvaluator();
        uint256 evaluatorGas = _evaluatorCallGas(engineAddress, context.minimumEngineGas);
        (assessed, assessmentData) = evaluator.staticcall{gas: evaluatorGas}(
            _assessmentCallData(engineAddress, context.order, request, context.pending)
        );
    }

    function _settleAssessmentFailure(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        address evaluator,
        bytes memory assessmentData
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        TerminalClassification memory classification = _classifyTypedFailure(assessmentData);
        if (!classification.terminal || !_plannerFailureMatches(classification, context.order.isClose)) {
            _revertRetryable(evaluator, assessmentData);
        }
        return _settleTypedFailure(context, request, preState, classification, false);
    }

    function _decodeAssessment(
        address evaluator,
        bytes memory assessmentData
    ) private pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        uint256 assessedMode = assessmentData.length >= 32 ? _word(assessmentData, 0) : 0;
        if (
            assessmentData.length != EXECUTION_ASSESSMENT_ABI_LENGTH || assessedMode == 0
                || assessedMode > uint256(OrderV2Types.ExecutionMode.Frozen)
        ) {
            revert OrderRouterV2ExecutionSidecar__MalformedSuccess(evaluator, assessmentData.length);
        }
        return abi.decode(assessmentData, (OrderV2Types.ExecutionAssessment));
    }

    function _callEngine(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        address engineAddress
    ) private returns (bool engineSucceeded, bytes memory engineData) {
        bytes memory engineCall = abi.encodeCall(
            ICfdEngineCore.processOrderTyped,
            (context.order, request.executionPrice, request.poolDepthUsdc, request.oraclePublishTime)
        );
        uint256 callGas = _engineCallGas(engineAddress, context.minimumEngineGas);
        return engineAddress.call{gas: callGas}(engineCall);
    }

    function _settleEngineFailure(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        address engineAddress,
        bytes memory engineData
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        TerminalClassification memory classification = _classifyTypedFailure(engineData);
        if (!classification.terminal || !_plannerFailureMatches(classification, context.order.isClose)) {
            _revertRetryable(engineAddress, engineData);
        }
        return _settleTypedFailure(context, request, preState, classification, true);
    }

    function _assessmentCallData(
        address engineAddress,
        CfdTypes.Order memory order,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        OrderV2Types.PendingIntent memory pending
    ) private pure returns (bytes memory) {
        return abi.encodeCall(
            ICfdOrderPolicyEvaluator.assessOrder,
            (
                engineAddress,
                order,
                request.executor,
                request.executionPrice,
                request.poolDepthUsdc,
                request.oraclePublishTime,
                pending.bounds,
                pending.executionBountyUsdc
            )
        );
    }

    function _settleTypedFailure(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        TerminalClassification memory classification,
        bool priceReachedEngine
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        uint256 bountyUsdc = context.host
            .settleV2OrderFromSidecar(
                context.order.orderId,
                false,
                request.executor,
                request.executionPrice,
                request.bountyAccountingPrice,
                request.bountyAccountingPublishTime
            );
        _requireBounty(context.pending.executionBountyUsdc, bountyUsdc);
        AccountState memory postState = _accountState(ICfdEngineCore(context.host.engine()), context.order.account);
        OrderV2Types.OrderReceipt memory receipt =
            _preparedBaseReceipt(context, request, classification.reason, request.executionMode, priceReachedEngine);
        _setPaidBounty(receipt, bountyUsdc, request.executor);
        receipt.failure = classification.failure;
        receipt.economics = _stateOnlyEconomics(preState, postState);
        return _finalizeReceipt(context.book, receipt);
    }

    function _settleNonEngine(
        IOrderRouterV2ExecutionHost host,
        IOrderLifecycleBook book,
        CfdTypes.Order memory order,
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.ItemRequest memory request,
        OrderV2Types.TerminalReason reason,
        OrderV2Types.FailureDetails memory failure
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
        AccountState memory preState = _accountState(engine_, order.account);
        IMarginClearinghouse(engine_.clearinghouse()).releaseOrderReservationForTerminalCleanup(order.orderId);
        uint256 bountyUsdc = host.settleV2OrderFromSidecar(
            order.orderId,
            false,
            request.executor,
            request.executionPrice,
            request.bountyAccountingPrice,
            request.bountyAccountingPublishTime
        );
        _requireBounty(pending.executionBountyUsdc, bountyUsdc);
        AccountState memory postState = _accountState(engine_, order.account);

        OrderV2Types.OrderReceipt memory receipt = _memoryRequestBaseReceipt(order.orderId, pending, request, reason);
        _setPaidBounty(receipt, bountyUsdc, request.executor);
        receipt.failure = failure;
        receipt.economics = _stateOnlyEconomics(preState, postState);
        return _finalizeReceipt(book, receipt);
    }

    function _settleRiskOff(
        IOrderRouterV2ExecutionHost host,
        IOrderLifecycleBook book,
        CfdTypes.Order memory order,
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        uint64 riskOffCutoff
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        uint256 bountyUsdc = host.refundRiskOffOrderFromSidecar(order.orderId, riskOffCutoff);
        _requireBounty(pending.executionBountyUsdc, bountyUsdc);
        // Risk-off only releases reservation classifications: settlement balance, trader claim, and position state
        // cannot change. Read the normalized receipt state once after cleanup instead of duplicating four external
        // reads for every order in the bounded emergency batch.
        AccountState memory state = _accountState(ICfdEngineCore(host.engine()), order.account);

        OrderV2Types.OrderReceipt memory receipt = _baseReceipt(
            order.orderId,
            pending,
            request.executor,
            request.observedConfigHash,
            OrderV2Types.TerminalReason.RiskOff,
            OrderV2Types.ExecutionMode.None,
            OrderV2Types.PriceSource.None,
            0,
            request.neutralMarkPrice,
            request.poolDepthUsdc,
            0,
            false
        );
        receipt.bountyUsdc = bountyUsdc;
        if (bountyUsdc != 0) {
            receipt.bountyRecipient = order.account;
            receipt.bountyDisposition = OrderV2Types.BountyDisposition.RefundedToAccount;
        }
        receipt.economics = _stateOnlyEconomics(state, state);
        return _finalizeReceipt(book, receipt);
    }

    function _baseReceipt(
        uint64 orderId,
        OrderV2Types.PendingIntent memory pending,
        address executor,
        bytes32 observedConfigHash,
        OrderV2Types.TerminalReason reason,
        OrderV2Types.ExecutionMode executionMode,
        OrderV2Types.PriceSource priceSource,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 poolDepthUsdc,
        uint64 oraclePublishTime,
        bool priceReachedEngine
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        receipt.orderId = orderId;
        receipt.account = pending.account;
        receipt.clientOrderId = pending.clientOrderId;
        receipt.intentHash = pending.intentHash;
        receipt.expectedConfigHash = pending.bounds.expectedConfigHash;
        receipt.observedConfigHash = observedConfigHash;
        receipt.status = OrderV2Types.LifecycleStatus.Failed;
        receipt.reason = reason;
        receipt.executionMode = executionMode;
        receipt.executor = executor;
        receipt.priceSource = priceSource;
        receipt.executionPrice = executionPrice;
        receipt.neutralMarkPrice = neutralMarkPrice;
        receipt.poolDepthUsdc = poolDepthUsdc;
        receipt.oraclePublishTime = oraclePublishTime;
        receipt.priceReachedEngine = priceReachedEngine;
    }

    function _settledTerminalBaseReceipt(
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.SettledTerminalInput calldata input
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        return _baseReceipt(
            input.orderId,
            pending,
            input.executor,
            input.observedConfigHash,
            input.reason,
            input.executionMode,
            input.priceSource,
            input.executionPrice,
            input.neutralMarkPrice,
            input.poolDepthUsdc,
            input.oraclePublishTime,
            input.priceReachedEngine
        );
    }

    function _memoryRequestBaseReceipt(
        uint64 orderId,
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.ItemRequest memory request,
        OrderV2Types.TerminalReason reason
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        return _baseReceipt(
            orderId,
            pending,
            request.executor,
            request.observedConfigHash,
            reason,
            request.executionMode,
            request.priceSource,
            request.executionPrice,
            request.neutralMarkPrice,
            request.poolDepthUsdc,
            request.oraclePublishTime,
            false
        );
    }

    function _preparedBaseReceipt(
        PreparedExecutionContext memory context,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        OrderV2Types.TerminalReason reason,
        OrderV2Types.ExecutionMode executionMode,
        bool priceReachedEngine
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        return _baseReceipt(
            context.order.orderId,
            context.pending,
            request.executor,
            context.observedConfigHash,
            reason,
            executionMode,
            request.priceSource,
            request.executionPrice,
            request.neutralMarkPrice,
            request.poolDepthUsdc,
            request.oraclePublishTime,
            priceReachedEngine
        );
    }

    function _finalizeReceipt(
        IOrderLifecycleBook book,
        OrderV2Types.OrderReceipt memory receipt
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        bytes32 receiptHash = book.finalize(receipt);
        result.orderId = receipt.orderId;
        result.status = receipt.status;
        result.terminalReason = receipt.reason;
        result.receiptHash = receiptHash;
    }

    function _assessmentEconomics(
        OrderV2Types.ExecutionAssessment memory assessment,
        AccountState memory preState,
        AccountState memory postState
    ) private pure returns (OrderV2Types.OrderEconomics memory economics) {
        economics.executionNotionalUsdc = assessment.executionNotionalUsdc;
        economics.realizedPnlUsdc = assessment.realizedPnlUsdc;
        economics.vpiUsdc = assessment.vpiUsdc;
        economics.carryUsdc = int256(assessment.carryUsdc);
        economics.executionFeeUsdc = assessment.executionFeeUsdc;
        economics.frozenSpreadUsdc = assessment.frozenSpreadUsdc;
        economics.actionChargeAssessedUsdc = assessment.actionChargeAssessedUsdc;
        economics.actionChargeCollectedUsdc = assessment.actionChargeCollectedUsdc;
        economics.grossAccountDebitUsdc = assessment.grossAccountDebitUsdc;
        economics.preSettlementBalanceUsdc = preState.settlementBalanceUsdc;
        economics.postSettlementBalanceUsdc = postState.settlementBalanceUsdc;
        economics.preTraderClaimBalanceUsdc = preState.traderClaimUsdc;
        economics.postTraderClaimBalanceUsdc = postState.traderClaimUsdc;
        economics.postPositionSize = postState.positionSize;
        economics.postPositionMarginUsdc = postState.positionMarginUsdc;
        economics.postPositionEquityUsdc = assessment.postPositionEquityUsdc;
        economics.postLeverageBps = assessment.postLeverageBps;
    }

    function _stateOnlyEconomics(
        AccountState memory preState,
        AccountState memory postState
    ) private pure returns (OrderV2Types.OrderEconomics memory economics) {
        economics.preSettlementBalanceUsdc = preState.settlementBalanceUsdc;
        economics.postSettlementBalanceUsdc = postState.settlementBalanceUsdc;
        economics.preTraderClaimBalanceUsdc = preState.traderClaimUsdc;
        economics.postTraderClaimBalanceUsdc = postState.traderClaimUsdc;
        economics.postPositionSize = postState.positionSize;
        economics.postPositionMarginUsdc = postState.positionMarginUsdc;
    }

    function _accountState(
        ICfdEngineCore engine_,
        address account
    ) private view returns (AccountState memory state) {
        state.settlementBalanceUsdc = IMarginClearinghouse(engine_.clearinghouse()).balanceUsdc(account);
        state.traderClaimUsdc = ICfdOrderReceiptEngineView(address(engine_)).traderClaimBalanceUsdc(account);
        (state.positionSize, state.positionMarginUsdc,,,,,) = engine_.positions(account);
    }

    function _classifyTypedFailure(
        bytes memory revertData
    ) internal pure returns (TerminalClassification memory classification) {
        if (revertData.length < 4) {
            return classification;
        }
        bytes4 selector = _selector(revertData);
        if (selector == ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector && revertData.length == 100) {
            uint256 category = _word(revertData, 4);
            uint256 code = _word(revertData, 36);
            uint256 isClose = _word(revertData, 68);
            bool knownCode = isClose == 0 ? code > 0 && code <= 10 : isClose == 1 && code > 0 && code <= 5;
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory expectedCategory =
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None;
            if (knownCode) {
                expectedCategory = isClose == 1
                    ? CfdEnginePlanLib.getExecutionFailurePolicyCategory(CfdEnginePlanTypes.CloseRevertCode(code))
                    : CfdEnginePlanLib.getExecutionFailurePolicyCategory(CfdEnginePlanTypes.OpenRevertCode(code));
            }
            if (
                knownCode && category == uint256(expectedCategory)
                    && expectedCategory != CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None
            ) {
                classification.terminal = true;
                classification.plannerFailure = true;
                classification.plannerIsClose = isClose == 1;
                classification.reason = OrderV2Types.TerminalReason.PlannerRejected;
                classification.failure.selector = selector;
                classification.failure.category = uint8(category);
                classification.failure.code = uint8(code);
                classification.failure.revertDataHash = keccak256(revertData);
            }
            return classification;
        }

        if (
            selector == ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed.selector
                && revertData.length == 68
        ) {
            uint256 mode = _word(revertData, 4);
            uint256 mask = _word(revertData, 36);
            if (mode > 0 && mode <= uint256(OrderV2Types.ExecutionMode.Frozen) && mask <= 7) {
                classification.terminal = true;
                classification.reason = OrderV2Types.TerminalReason.ExecutionModeDisallowed;
                classification.failure.selector = selector;
                classification.failure.actual = mode;
                classification.failure.limit = mask;
                classification.failure.revertDataHash = keccak256(revertData);
            }
            return classification;
        }

        if (
            selector == ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector
                && revertData.length == 100
        ) {
            uint256 constraint = _word(revertData, 4);
            if (constraint > 0 && constraint <= uint256(OrderV2Types.ConstraintKind.PostLeverage)) {
                classification.terminal = true;
                classification.reason = OrderV2Types.TerminalReason.ConstraintViolation;
                classification.failure.selector = selector;
                classification.failure.constraint = OrderV2Types.ConstraintKind(constraint);
                classification.failure.actual = _word(revertData, 36);
                classification.failure.limit = _word(revertData, 68);
                classification.failure.revertDataHash = keccak256(revertData);
            }
        }
    }

    function _preOracleAction(
        IOrderRouterV2ExecutionHost host,
        CfdTypes.Order memory order,
        uint64 orderId,
        uint64 riskOffCutoff
    ) private view returns (IOrderRouterV2ExecutionHost.ItemAction action, bool terminal) {
        if (_isRiskOffOpen(orderId, order.isClose, riskOffCutoff)) {
            return (IOrderRouterV2ExecutionHost.ItemAction.RiskOff, true);
        }
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        if (pending.account != order.account) {
            revert OrderRouterV2ExecutionSidecar__OrderIdentityMismatch(orderId);
        }
        if (block.timestamp > pending.bounds.validUntil) {
            return (IOrderRouterV2ExecutionHost.ItemAction.Expire, true);
        }
        bytes32 expectedConfigHash = pending.bounds.expectedConfigHash;
        // External V2 commits reject zero; internal protected children use it to inherit execution-time configuration.
        if (expectedConfigHash != bytes32(0) && book.currentExecutionConfigHash() != expectedConfigHash) {
            return (IOrderRouterV2ExecutionHost.ItemAction.ConfigMismatch, true);
        }
        return (IOrderRouterV2ExecutionHost.ItemAction.Execute, false);
    }

    function _preOracleItem(
        IOrderRouterV2ExecutionHost host,
        uint64 orderId,
        IOrderRouterV2ExecutionHost.ItemAction action,
        address executor
    ) private view returns (IOrderRouterV2ExecutionHost.ItemRequest memory request) {
        ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
        request.orderId = orderId;
        request.action = action;
        request.executor = executor;
        request.observedConfigHash = IOrderLifecycleBook(host.lifecycleBook()).currentExecutionConfigHash();
        request.neutralMarkPrice = engine_.lastMarkPrice();
        request.poolDepthUsdc = IHousePool(engine_.pool()).totalAssets();
        request.bountyAccountingPrice = _bountyAccountingStoredMark(engine_);
        request.bountyAccountingPublishTime = engine_.lastMarkTime();
    }

    function _executionItem(
        IOrderRouterV2ExecutionHost host,
        CfdTypes.Order memory order,
        OracleResult memory oracleResult,
        address executor
    ) private view returns (IOrderRouterV2ExecutionHost.ItemRequest memory request) {
        ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
        request.orderId = order.orderId;
        request.action = IOrderRouterV2ExecutionHost.ItemAction.Execute;
        request.executor = executor;
        request.observedConfigHash = IOrderLifecycleBook(host.lifecycleBook()).currentExecutionConfigHash();
        request.executionMode = oracleResult.mode;
        request.priceSource = OrderV2Types.PriceSource.OracleExecution;
        request.executionPrice = oracleResult.executionPrice;
        request.neutralMarkPrice = oracleResult.neutralMarkPrice;
        request.poolDepthUsdc = IHousePool(engine_.pool()).totalAssets();
        request.oraclePublishTime = oracleResult.publishTime;
        request.bountyAccountingPrice = oracleResult.neutralMarkPrice;
        request.bountyAccountingPublishTime = oracleResult.publishTime;
        request.oracleFrozen = oracleResult.oracleFrozen;
        request.openExecutionCloseOnly = oracleResult.closeOnly;
    }

    function _prepareSingleOracle(
        IOrderRouterV2ExecutionHost host,
        CfdTypes.Order memory order,
        address executor,
        bytes[] calldata pythUpdateData
    ) private returns (OracleResult memory result) {
        IPletherOracle oracle = IPletherOracle(host.pletherOracle());
        result.fee = oracle.getUpdateFee(pythUpdateData);
        if (msg.value < result.fee) {
            revert IPletherOracle.PletherOracle__InsufficientFee(msg.value, result.fee);
        }
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice{value: result.fee}(executor, pythUpdateData, _oracleRequest(order, true));
        if (!ok) {
            _revertOrderExecutionStale(oracle);
        }
        result = _oracleResult(snapshot);
        _updateEngineMark(host, result);
    }

    function _prepareBatchOracle(
        IOrderRouterV2ExecutionHost host,
        CfdTypes.Order memory order,
        bytes[] calldata pythUpdateData,
        BatchExecutionState memory state
    ) private returns (bool ok, OracleResult memory result, IPletherOracle.BatchOrderPriceCache memory nextCache) {
        IPletherOracle oracle = IPletherOracle(host.pletherOracle());
        uint256 fee = 0;
        if (!_canReuseHistoricalBatchBasket(oracle, order, state.oracleCache)) {
            fee = oracle.getUpdateFee(pythUpdateData);
            // The outer FIFO loop passes a monotonic spent total; this guard prevents aggregate Pyth overspending.
            // slither-disable-next-line msg-value-loop
            uint256 suppliedValue = msg.value;
            if (suppliedValue < state.pythFeeTotal + fee) {
                revert IPletherOracle.PletherOracle__InsufficientFee(suppliedValue, state.pythFeeTotal + fee);
            }
        }
        IPletherOracle.PriceSnapshot memory snapshot;
        IPletherOracle.OrderExecutionRequest memory oracleRequest = _oracleRequest(order, false);
        (ok, snapshot, nextCache) = oracle.updateBatchOrderExecutionPrice{value: fee}(
            state.executor, pythUpdateData, oracleRequest, state.oracleCache
        );
        result.fee = snapshot.updateFee;
        if (!ok) {
            return (false, result, nextCache);
        }
        result = _oracleResult(snapshot);
        _updateEngineMark(host, result);
    }

    function _oracleResult(
        IPletherOracle.PriceSnapshot memory snapshot
    ) private pure returns (OracleResult memory result) {
        result.executionPrice = snapshot.price;
        result.neutralMarkPrice = snapshot.markPrice;
        result.publishTime = snapshot.publishTime;
        result.fee = snapshot.updateFee;
        result.oracleFrozen = snapshot.oracleFrozen;
        result.closeOnly = snapshot.closeOnly;
        result.mode = snapshot.oracleFrozen
            ? OrderV2Types.ExecutionMode.Frozen
            : snapshot.isFadWindow ? OrderV2Types.ExecutionMode.Fad : OrderV2Types.ExecutionMode.Live;
    }

    function _updateEngineMark(
        IOrderRouterV2ExecutionHost host,
        OracleResult memory result
    ) private {
        ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
        if (result.publishTime >= engine_.lastMarkTime()) {
            engine_.updateMarkPrice(result.neutralMarkPrice, result.publishTime);
        }
    }

    function _oracleRequest(
        CfdTypes.Order memory order,
        bool revertOnHistoricalUnavailable
    ) private pure returns (IPletherOracle.OrderExecutionRequest memory request) {
        request.commitTime = order.commitTime;
        request.targetPrice = order.targetPrice;
        request.side = order.side;
        request.isClose = order.isClose;
        request.revertOnHistoricalUnavailable = revertOnHistoricalUnavailable;
    }

    function _canReuseHistoricalBatchBasket(
        IPletherOracle oracle,
        CfdTypes.Order memory order,
        IPletherOracle.BatchOrderPriceCache memory cache
    ) private view returns (bool) {
        if (oracle.isOracleFrozen() || !cache.hasHistoricalBasket) {
            return false;
        }
        uint64 commitTime = order.commitTime;
        if (commitTime < cache.minReusableCommitTime || commitTime >= cache.publishTime) {
            return false;
        }
        if (cache.publishTime > block.timestamp) {
            return false;
        }
        return uint256(cache.publishTime) <= uint256(commitTime) + oracle.orderSettlementWindow();
    }

    function _revertOrderExecutionStale(
        IPletherOracle oracle
    ) private view {
        revert IPletherOracle.PletherOracle__StalePrice(
            IPletherOracle.PriceMode.OrderExecution,
            bytes32(0),
            block.timestamp,
            oracle.orderExecutionStalenessLimit(),
            block.timestamp
        );
    }

    function _validateBatchBounds(
        IOrderRouterV2ExecutionHost host,
        uint64 maxOrderId
    ) private view {
        uint64 head = host.nextExecuteId();
        if (head == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (maxOrderId < head) {
            revert OrderRouter__BatchBeforeQueueHead();
        }
        if (maxOrderId >= host.nextCommitId()) {
            revert OrderRouter__BatchOrderNotCommitted();
        }
    }

    function _requireOrderView(
        uint64 orderId,
        IOrderRouterV2ExecutionHost.OrderView memory orderView
    ) private pure {
        if (!orderView.pending || orderView.order.orderId != orderId || orderView.order.account == address(0)) {
            revert OrderRouterV2ExecutionSidecar__OrderIdentityMismatch(orderId);
        }
    }

    function _riskOffCutoff(
        IOrderRouterV2ExecutionHost host
    ) private view returns (uint64) {
        return IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
    }

    function _isRiskOffOpen(
        uint64 orderId,
        bool isClose,
        uint64 cutoff
    ) private pure returns (bool) {
        return cutoff != 0 && orderId <= cutoff && !isClose;
    }

    function _bountyAccountingStoredMark(
        ICfdEngineCore engine_
    ) private view returns (uint256 price) {
        price = engine_.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }
        uint256 capPrice = engine_.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _hasExecutionEnvelope(
        uint256 minEngineGas
    ) private view returns (bool) {
        uint256 available = gasleft();
        uint256 reserve = POST_ENGINE_GAS_RESERVE + EVALUATOR_RETURN_GAS_RESERVE;
        if (minEngineGas > type(uint256).max - reserve) {
            return false;
        }
        reserve += minEngineGas;
        return available > reserve;
    }

    function _evaluatorCallGas(
        address engineAddress,
        uint256 minEngineGas
    ) private view returns (uint256 evaluatorGas) {
        uint256 reserve = POST_ENGINE_GAS_RESERVE + EVALUATOR_RETURN_GAS_RESERVE;
        if (minEngineGas > type(uint256).max - reserve) {
            revert OrderRouterV2ExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
        reserve += minEngineGas;
        uint256 available = gasleft();
        if (available <= reserve) {
            revert OrderRouterV2ExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
        return available - reserve;
    }

    function _engineCallGas(
        address engineAddress,
        uint256 minEngineGas
    ) private view returns (uint256 callGas) {
        uint256 available = gasleft();
        if (available <= POST_ENGINE_GAS_RESERVE) {
            revert OrderRouterV2ExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
        callGas = available - POST_ENGINE_GAS_RESERVE;
        uint256 eip150Limit = available - (available / 64);
        uint256 forwardable = callGas < eip150Limit ? callGas : eip150Limit;
        if (forwardable < minEngineGas) {
            revert OrderRouterV2ExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
    }

    /// @dev Preserves enough gas in the outer batch frame to classify a failed item, persist its cursor, refund or
    ///      defer ETH, and return without rolling back the already-finalized prefix.
    function _itemCallGas() private view returns (uint256 itemGas) {
        uint256 available = gasleft();
        if (available <= POST_ENGINE_GAS_RESERVE * 2) {
            return 0;
        }
        return available - POST_ENGINE_GAS_RESERVE;
    }

    function _plannerFailureMatches(
        TerminalClassification memory classification,
        bool orderIsClose
    ) private pure returns (bool) {
        return !classification.plannerFailure || classification.plannerIsClose == orderIsClose;
    }

    function _assertAssessmentState(
        OrderV2Types.ExecutionAssessment memory assessment,
        OrderV2Types.ExecutionMode requestedMode,
        AccountState memory preState,
        AccountState memory postState
    ) private pure {
        _assertAssessmentField(1, uint256(requestedMode), uint256(assessment.mode));
        _assertAssessmentField(2, preState.settlementBalanceUsdc, assessment.preSettlementBalanceUsdc);
        _assertAssessmentField(3, postState.settlementBalanceUsdc, assessment.postSettlementBalanceUsdc);
        _assertAssessmentField(4, preState.traderClaimUsdc, assessment.preTraderClaimUsdc);
        _assertAssessmentField(5, postState.traderClaimUsdc, assessment.postTraderClaimUsdc);
        _assertAssessmentField(6, postState.positionSize, assessment.postPositionSize);
        _assertAssessmentField(7, postState.positionMarginUsdc, assessment.postPositionMarginUsdc);
    }

    function _assertAssessmentField(
        uint8 field,
        uint256 actual,
        uint256 expected
    ) private pure {
        if (actual != expected) {
            revert OrderRouterV2ExecutionSidecar__AssessmentStateMismatch(field, expected, actual);
        }
    }

    function _pendingResult(
        uint64 orderId,
        OrderV2Types.PendingReason reason
    ) private pure returns (OrderV2Types.ExecutionResult memory result) {
        result.orderId = orderId;
        result.status = OrderV2Types.LifecycleStatus.Pending;
        result.pendingReason = reason;
    }

    function _refundEth(
        IOrderRouterV2ExecutionHost host,
        address recipient,
        uint256 amount
    ) private {
        if (amount != 0) {
            host.sendEthFromSidecar(recipient, amount);
        }
    }

    function _requireBounty(
        uint256 expected,
        uint256 actual
    ) private pure {
        if (actual != expected) {
            revert OrderRouterV2ExecutionSidecar__BountyMismatch(expected, actual);
        }
    }

    function _validateSettledTerminalInput(
        IOrderRouterV2ExecutionHost host,
        OrderV2Types.PendingIntent memory pending,
        IOrderRouterV2ExecutionHost.SettledTerminalInput calldata input
    ) private view {
        bool failureIsEmpty = input.failure.selector == bytes4(0) && input.failure.category == 0
            && input.failure.code == 0 && input.failure.constraint == OrderV2Types.ConstraintKind.None
            && input.failure.actual == 0 && input.failure.limit == 0 && input.failure.revertDataHash == bytes32(0);
        if (!failureIsEmpty) {
            revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
        }

        if (input.bountyUsdc == 0) {
            if (input.bountyDisposition != OrderV2Types.BountyDisposition.None || input.bountyRecipient != address(0)) {
                revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
            }
        } else if (input.reason == OrderV2Types.TerminalReason.RiskOff) {
            if (
                input.bountyDisposition != OrderV2Types.BountyDisposition.RefundedToAccount
                    || input.bountyRecipient != pending.account
            ) {
                revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
            }
        } else if (
            input.bountyDisposition != OrderV2Types.BountyDisposition.Forfeited
                || input.bountyRecipient != ICfdEngineCore(host.engine()).protocolTreasury()
        ) {
            revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
        }

        if (input.reason == OrderV2Types.TerminalReason.RiskOff) {
            if (
                input.executionMode != OrderV2Types.ExecutionMode.None
                    || input.priceSource != OrderV2Types.PriceSource.None || input.executionPrice != 0
                    || input.oraclePublishTime != 0 || input.priceReachedEngine
            ) {
                revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
            }
            return;
        }
        if (input.priceSource != OrderV2Types.PriceSource.Liquidation || input.priceReachedEngine) {
            revert OrderRouterV2ExecutionSidecar__InvalidSettledReason();
        }
    }

    function _setPaidBounty(
        OrderV2Types.OrderReceipt memory receipt,
        uint256 bountyUsdc,
        address recipient
    ) private pure {
        receipt.bountyUsdc = bountyUsdc;
        if (bountyUsdc != 0) {
            receipt.bountyRecipient = recipient;
            receipt.bountyDisposition = OrderV2Types.BountyDisposition.Paid;
        }
    }

    function _revertRetryable(
        address target,
        bytes memory revertData
    ) private pure {
        revert OrderRouterV2ExecutionSidecar__RetryableFailure(target, _selector(revertData), revertData.length);
    }

    function _pendingReasonForRevert(
        bytes memory revertData
    ) internal pure returns (OrderV2Types.PendingReason reason) {
        if (revertData.length == 0) {
            return OrderV2Types.PendingReason.EngineFailure;
        }
        bytes4 outerSelector = _selector(revertData);
        if (outerSelector == OrderRouterV2ExecutionSidecar__RetryableFailure.selector && revertData.length == 100) {
            bytes4 innerSelector = _bytes4Word(revertData, 36);
            if (
                innerSelector == ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector
                    || innerSelector == OrderRouter__MarkPriceOutOfOrder.selector
            ) {
                return OrderV2Types.PendingReason.MarkPriceOutOfOrder;
            }
            if (innerSelector == OrderRouter__InsufficientGas.selector) {
                return OrderV2Types.PendingReason.InsufficientGas;
            }
            return OrderV2Types.PendingReason.EngineFailure;
        }
        if (
            outerSelector == OrderRouterV2ExecutionSidecar__MalformedSuccess.selector
                || outerSelector == OrderRouterV2ExecutionSidecar__AssessmentStateMismatch.selector
        ) {
            return OrderV2Types.PendingReason.EngineFailure;
        }
        return OrderV2Types.PendingReason.ReceiptFailure;
    }

    function _selector(
        bytes memory data
    ) private pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
    }

    function _word(
        bytes memory data,
        uint256 offset
    ) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }

    function _bytes4Word(
        bytes memory data,
        uint256 offset
    ) private pure returns (bytes4 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }

}

/// @dev Engine receipt-read surface intentionally omitted from the size-constrained core interface.
interface ICfdOrderReceiptEngineView {

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

}
