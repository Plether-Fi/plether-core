// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRecoverySidecar} from "@plether/perps/OrderRecoverySidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";

/// @title OrderRouterExecutionSidecar
/// @notice Stateless delegate module for V3 order oracle orchestration, bounded execution, and receipts.
/// @dev This contract declares no mutable storage. It must be deployed independently and supplied to a fresh Router;
///      calling a stateful entrypoint on the sidecar address itself is rejected. Router self-calls isolate each batch
///      item, so an unknown Engine or receipt failure cannot roll back already completed items.
/// @custom:security-contact contact@plether.com
contract OrderRouterExecutionSidecar is IOrderRouterErrors {

    /// @notice A stateful entrypoint was called directly rather than through delegatecall.
    error OrderRouterExecutionSidecar__OnlyDelegateCall();
    /// @notice An item-only entrypoint was not reached through the Router's external self-call boundary.
    error OrderRouterExecutionSidecar__OnlyRouterSelf();
    /// @notice Router queue data and lifecycle-book identity disagree.
    error OrderRouterExecutionSidecar__OrderIdentityMismatch(uint64 orderId);
    /// @notice A Router-supplied item action is not currently applicable.
    error OrderRouterExecutionSidecar__InvalidItemAction(uint64 orderId);
    /// @notice A trusted stateless dependency returned a malformed successful payload.
    error OrderRouterExecutionSidecar__MalformedSuccess(address target, uint256 returndataLength);
    /// @notice An unrecognized, malformed, empty, or panic external failure must leave the order pending.
    error OrderRouterExecutionSidecar__RetryableFailure(address target, bytes4 selector, uint256 returndataLength);
    /// @notice Router settlement did not consume exactly the lifecycle-book bounty.
    error OrderRouterExecutionSidecar__BountyMismatch(uint256 expectedUsdc, uint256 actualUsdc);
    /// @notice A receipt-only helper was supplied a reason outside its risk-off/liquidation domain.
    error OrderRouterExecutionSidecar__InvalidSettledReason();
    /// @notice Evaluator output disagreed with the actual pre- or post-settlement protocol state.
    error OrderRouterExecutionSidecar__AssessmentStateMismatch(uint8 field, uint256 expected, uint256 actual);

    uint256 internal constant MAX_RISK_OFF_REFUNDS_PER_CALL = 64;
    uint256 internal constant POST_ENGINE_GAS_RESERVE = 1_000_000;
    uint256 internal constant EVALUATOR_RETURN_GAS_RESERVE = 250_000;
    uint256 internal constant EXECUTION_ASSESSMENT_ABI_LENGTH = 29 * 32;

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
        OrderV3Types.TerminalReason reason;
        OrderV3Types.FailureDetails failure;
    }

    struct OracleResult {
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint64 publishTime;
        uint256 fee;
        OrderV3Types.ExecutionMode mode;
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
        IOrderRouterExecutionHost host;
        IOrderLifecycleBook book;
        CfdTypes.Order order;
        OrderV3Types.PendingIntent pending;
        bytes32 observedConfigHash;
        uint256 minimumEngineGas;
    }

    address public immutable recoverySidecar;

    constructor() {
        recoverySidecar = address(new OrderRecoverySidecar());
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
            revert OrderRouterExecutionSidecar__OnlyDelegateCall();
        }
    }

    function _requireRouterSelf() private view {
        _requireDelegateCall();
        if (msg.sender != address(this)) {
            revert OrderRouterExecutionSidecar__OnlyRouterSelf();
        }
    }

    /// @notice Executes one queue target after bounded oracle-independent head cleanup.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable onlyDelegateCall returns (OrderV3Types.ExecutionResult memory result) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
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
            IOrderRouterExecutionHost.OrderView memory orderView = host.getOrderForSidecar(head);
            _requireOrderView(head, orderView);
            (IOrderRouterExecutionHost.ItemAction action, bool terminalBeforeOracle) =
                _preOracleAction(host, orderView.order, head, riskOffCutoff);
            if (!terminalBeforeOracle) {
                break;
            }
            if (action == IOrderRouterExecutionHost.ItemAction.RiskOff) {
                if (riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL) {
                    result = _pendingResult(head, OrderV3Types.PendingReason.CleanupLimit);
                    _refundEth(host, executor, msg.value);
                    return result;
                }
                ++riskOffRefunds;
            } else {
                if (terminalPrunes == host.maxPruneOrdersPerCall()) {
                    result = _pendingResult(head, OrderV3Types.PendingReason.CleanupLimit);
                    _refundEth(host, executor, msg.value);
                    return result;
                }
                ++terminalPrunes;
            }

            IOrderRouterExecutionHost.ItemRequest memory request = _preOracleItem(host, head, action, executor);
            uint256 itemGas = _itemCallGas();
            if (itemGas == 0) {
                result = _pendingResult(head, OrderV3Types.PendingReason.InsufficientGas);
                _refundEth(host, executor, msg.value);
                return result;
            }
            try host.executeOrderItemFromSidecar{gas: itemGas}(request) returns (
                OrderV3Types.ExecutionResult memory itemResult
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

        IOrderRouterExecutionHost.OrderView memory target = host.getOrderForSidecar(head);
        _requireOrderView(head, target);
        OracleResult memory oracleResult = _prepareSingleOracle(host, target.order, executor, pythUpdateData);
        IOrderRouterExecutionHost.ItemRequest memory executionRequest =
            _executionItem(host, target.order, oracleResult, executor);
        uint256 executionGas = _itemCallGas();
        if (executionGas == 0) {
            result = _pendingResult(head, OrderV3Types.PendingReason.InsufficientGas);
        } else {
            try host.executeOrderItemFromSidecar{gas: executionGas}(executionRequest) returns (
                OrderV3Types.ExecutionResult memory executionResult
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
    ) external payable onlyDelegateCall returns (OrderV3Types.BatchResult memory batchResult) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        _validateBatchBounds(host, maxOrderId);

        BatchExecutionState memory state;
        state.executor = msg.sender;
        state.riskOffCutoff = _riskOffCutoff(host);

        while (host.nextExecuteId() != 0 && host.nextExecuteId() <= maxOrderId) {
            uint64 orderId = host.nextExecuteId();
            IOrderRouterExecutionHost.OrderView memory orderView = host.getOrderForSidecar(orderId);
            _requireOrderView(orderId, orderView);

            (IOrderRouterExecutionHost.ItemAction action, bool terminalBeforeOracle) =
                _preOracleAction(host, orderView.order, orderId, state.riskOffCutoff);
            if (terminalBeforeOracle) {
                if (action == IOrderRouterExecutionHost.ItemAction.RiskOff) {
                    if (state.riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL) {
                        batchResult.stopReason = OrderV3Types.PendingReason.CleanupLimit;
                        break;
                    }
                    unchecked {
                        ++state.riskOffRefunds;
                    }
                } else {
                    if (state.terminalPrunes == host.maxPruneOrdersPerCall()) {
                        batchResult.stopReason = OrderV3Types.PendingReason.CleanupLimit;
                        break;
                    }
                    unchecked {
                        ++state.terminalPrunes;
                    }
                }

                IOrderRouterExecutionHost.ItemRequest memory cleanup =
                    _preOracleItem(host, orderId, action, state.executor);
                uint256 cleanupGas = _itemCallGas();
                if (cleanupGas == 0) {
                    batchResult.stopReason = OrderV3Types.PendingReason.InsufficientGas;
                    break;
                }
                try host.executeOrderItemFromSidecar{gas: cleanupGas}(cleanup) returns (
                    OrderV3Types.ExecutionResult memory cleanupResult
                ) {
                    if (cleanupResult.status != OrderV3Types.LifecycleStatus.Pending) {
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
                batchResult.stopReason = OrderV3Types.PendingReason.HistoricalPriceUnavailable;
                break;
            }

            IOrderRouterExecutionHost.ItemRequest memory executionRequest =
                _executionItem(host, orderView.order, oracleResult, state.executor);
            uint256 executionGas = _itemCallGas();
            if (executionGas == 0) {
                batchResult.stopReason = OrderV3Types.PendingReason.InsufficientGas;
                break;
            }
            try host.executeOrderItemFromSidecar{gas: executionGas}(executionRequest) returns (
                OrderV3Types.ExecutionResult memory executionResult
            ) {
                if (executionResult.status == OrderV3Types.LifecycleStatus.Pending) {
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

    function expireOrder(
        uint64
    ) external onlyDelegateCall returns (OrderV3Types.ExecutionResult memory) {
        return _delegateRecovery(msg.data);
    }

    function _delegateRecovery(
        bytes memory data
    ) private returns (OrderV3Types.ExecutionResult memory) {
        (bool success, bytes memory result) = recoverySidecar.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        return abi.decode(result, (OrderV3Types.ExecutionResult));
    }

    /// @notice Executes or terminally settles one order inside a Router self-call rollback frame.
    /// @dev The Router callback bearing this selector must delegate the exact calldata back to this sidecar.
    function executeOrderItemFromSidecar(
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) external onlyRouterSelf returns (OrderV3Types.ExecutionResult memory result) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderRouterExecutionHost.OrderView memory orderView = host.getOrderForSidecar(request.orderId);
        _requireOrderView(request.orderId, orderView);
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(request.orderId);
        if (pending.account == address(0) || pending.account != orderView.order.account) {
            revert OrderRouterExecutionSidecar__OrderIdentityMismatch(request.orderId);
        }

        {
            IMarginClearinghouse reservations = IMarginClearinghouse(ICfdEngineCore(host.engine()).clearinghouse());
            if (block.timestamp > pending.timing.executionDeadline) {
                try reservations.validateBountyReservation(
                    pending.account, IMarginClearinghouse.BountyKind.Order, request.orderId, pending.executionBountyUsdc
                ) {}
                catch {
                    return _recoverExpired(host, book, pending, request);
                }
            } else {
                reservations.validateBountyReservation(
                    pending.account, IMarginClearinghouse.BountyKind.Order, request.orderId, pending.executionBountyUsdc
                );
            }
        }

        uint64 riskOffCutoff = _riskOffCutoff(host);
        if (_isRiskOffOpen(request.orderId, orderView.order.isClose, riskOffCutoff)) {
            return _settleRiskOff(host, book, orderView.order, pending, request, riskOffCutoff);
        }
        if (request.action == IOrderRouterExecutionHost.ItemAction.RiskOff) {
            revert OrderRouter__OrderNotRiskOff();
        }

        if (block.timestamp > pending.timing.executionDeadline) {
            return _settleNonEngine(
                host,
                book,
                orderView.order,
                pending,
                request,
                OrderV3Types.TerminalReason.Expired,
                OrderV3Types.FailureDetails(bytes4(0), 0, 0, OrderV3Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }

        if (pending.closeMode == OrderV3Types.CloseMode.CallerPaidFullExit) {
            ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
            (uint256 size,,,, CfdTypes.Side side,,) = engine_.positions(pending.account);
            if (
                engine_.positionEpoch(pending.account) != pending.positionEpoch || size != pending.positionSize
                    || side != pending.positionSide
            ) {
                // Zero oracle/execution fields are intentional: a changed terminal position is never executed.
                // slither-disable-next-line uninitialized-local
                IOrderRouterExecutionHost.ItemRequest memory terminalRequest;
                terminalRequest.orderId = request.orderId;
                terminalRequest.executor = request.executor;
                return _settleNonEngine(
                    host,
                    book,
                    orderView.order,
                    pending,
                    terminalRequest,
                    OrderV3Types.TerminalReason.TerminalPositionChanged,
                    OrderV3Types.FailureDetails(bytes4(0), 0, 0, OrderV3Types.ConstraintKind.None, 0, 0, bytes32(0))
                );
            }
        }
        // Execute requests carry the digest read after oracle/mark updates by _executionItem. Only static
        // dependency reads and Router self-calls occur between that observation and this check. Reuse it inside
        // this authenticated item; public committed assessment still validates configuration independently.
        // Cleanup requests may originate without an observation (for example permissionless expiry).
        bytes32 observedConfigHash = request.action == IOrderRouterExecutionHost.ItemAction.Execute
            && request.observedConfigHash != bytes32(0)
            ? request.observedConfigHash
            : book.currentExecutionConfigHash();
        bytes32 expectedConfigHash = pending.bounds.expectedConfigHash;
        // Zero is reserved for Router-created trigger closes whose intent is deliberately unpinned.
        if (expectedConfigHash != bytes32(0) && observedConfigHash != expectedConfigHash) {
            IOrderRouterExecutionHost.ItemRequest memory configRequest = request;
            configRequest.observedConfigHash = observedConfigHash;
            return _settleNonEngine(
                host,
                book,
                orderView.order,
                pending,
                configRequest,
                OrderV3Types.TerminalReason.ConfigMismatch,
                OrderV3Types.FailureDetails(bytes4(0), 0, 0, OrderV3Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }

        if (request.action != IOrderRouterExecutionHost.ItemAction.Execute) {
            revert OrderRouterExecutionSidecar__InvalidItemAction(request.orderId);
        }
        return _executePrepared(host, book, orderView.order, pending, request, observedConfigHash);
    }

    function _recoverExpired(
        IOrderRouterExecutionHost,
        IOrderLifecycleBook,
        OrderV3Types.PendingIntent memory,
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) private returns (OrderV3Types.ExecutionResult memory) {
        return
            _delegateRecovery(
                abi.encodeCall(OrderRecoverySidecar.recoverExpiredItem, (request.orderId, request.executor))
            );
    }

    function recordSettledTerminal(
        IOrderRouterExecutionHost.SettledTerminalInput calldata
    ) external onlyRouterSelf returns (OrderV3Types.ExecutionResult memory) {
        return _delegateRecovery(msg.data);
    }

    function _executePrepared(
        IOrderRouterExecutionHost host,
        IOrderLifecycleBook book,
        CfdTypes.Order memory order,
        OrderV3Types.PendingIntent memory pending,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        bytes32 observedConfigHash
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        if (!order.isClose && request.openExecutionCloseOnly) {
            return _pendingResult(order.orderId, OrderV3Types.PendingReason.CloseOnly);
        }
        // Exact block equality is the intended same-block MEV boundary, not a balance or price comparison.
        // slither-disable-next-line incorrect-equality
        if (!request.oracleFrozen && block.number == order.commitBlock) {
            return _pendingResult(order.orderId, OrderV3Types.PendingReason.SameBlock);
        }
        if (!request.oracleFrozen && request.oraclePublishTime <= order.commitTime) {
            return _pendingResult(order.orderId, OrderV3Types.PendingReason.MevBoundary);
        }
        if (!OrderValidationLib.checkSlippage(order, request.executionPrice)) {
            return _settleNonEngine(
                host,
                book,
                order,
                pending,
                request,
                OrderV3Types.TerminalReason.Slippage,
                OrderV3Types.FailureDetails(bytes4(0), 0, 0, OrderV3Types.ConstraintKind.None, 0, 0, bytes32(0))
            );
        }
        uint256 minimumEngineGas = host.minEngineGas();
        if (!_hasExecutionEnvelope(minimumEngineGas)) {
            return _pendingResult(order.orderId, OrderV3Types.PendingReason.InsufficientGas);
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
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) private returns (OrderV3Types.ExecutionResult memory result) {
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
        OrderV3Types.ExecutionAssessment memory assessment = _decodeAssessment(evaluator, assessmentData);

        (bool engineSucceeded, bytes memory engineData) = _callEngine(context, request, address(engine_));
        if (!engineSucceeded) {
            return _settleEngineFailure(context, request, preState, address(engine_), engineData);
        }
        if (engineData.length != 0) {
            revert OrderRouterExecutionSidecar__MalformedSuccess(address(engine_), engineData.length);
        }

        IOrderRouterExecutionHost.BountySettlement memory bountySettlement = _settleExecutedOrder(context, request);
        return _finalizeExecutedOrder(context, request, assessment, preState, bountySettlement);
    }

    function _finalizeExecutedOrder(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        OrderV3Types.ExecutionAssessment memory assessment,
        AccountState memory preState,
        IOrderRouterExecutionHost.BountySettlement memory bountySettlement
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        AccountState memory postState = _accountState(ICfdEngineCore(context.host.engine()), context.order.account);
        _assertAssessmentState(assessment, request.executionMode, preState, postState);
        OrderV3Types.OrderReceipt memory receipt =
            _preparedBaseReceipt(context, request, OrderV3Types.TerminalReason.Executed, assessment.mode, true);
        receipt.status = OrderV3Types.LifecycleStatus.Executed;
        _setBountySettlement(receipt, bountySettlement);
        receipt.economics = _assessmentEconomics(assessment, preState, postState);
        return _finalizeReceipt(context.book, receipt);
    }

    function _settleExecutedOrder(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) private returns (IOrderRouterExecutionHost.BountySettlement memory bountySettlement) {
        bountySettlement = context.host
            .settleOrderFromSidecar(
                context.order.orderId,
                true,
                OrderV3Types.TerminalReason.Executed,
                request.executor,
                request.executionPrice,
                request.bountyAccountingPrice,
                request.bountyAccountingPublishTime
            );
        _requireBounty(context.pending.executionBountyUsdc, bountySettlement.bountyUsdc);
    }

    function _callPolicyEvaluator(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request,
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
        IOrderRouterExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        address evaluator,
        bytes memory assessmentData
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        TerminalClassification memory classification = _classifyTypedFailure(assessmentData);
        if (!classification.terminal || !_plannerFailureMatches(classification, context.order.isClose)) {
            _revertRetryable(evaluator, assessmentData);
        }
        return _settleTypedFailure(context, request, preState, classification, false);
    }

    function _decodeAssessment(
        address evaluator,
        bytes memory assessmentData
    ) private pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        uint256 assessedMode = assessmentData.length >= 32 ? _word(assessmentData, 0) : 0;
        if (
            assessmentData.length != EXECUTION_ASSESSMENT_ABI_LENGTH || assessedMode == 0
                || assessedMode > uint256(OrderV3Types.ExecutionMode.Frozen)
        ) {
            revert OrderRouterExecutionSidecar__MalformedSuccess(evaluator, assessmentData.length);
        }
        return abi.decode(assessmentData, (OrderV3Types.ExecutionAssessment));
    }

    function _callEngine(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request,
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
        IOrderRouterExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        address engineAddress,
        bytes memory engineData
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        TerminalClassification memory classification = _classifyTypedFailure(engineData);
        if (!classification.terminal || !_plannerFailureMatches(classification, context.order.isClose)) {
            _revertRetryable(engineAddress, engineData);
        }
        return _settleTypedFailure(context, request, preState, classification, true);
    }

    function _assessmentCallData(
        address engineAddress,
        CfdTypes.Order memory order,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        OrderV3Types.PendingIntent memory pending
    ) private pure returns (bytes memory) {
        pending;
        return abi.encodeCall(
            ICfdOrderPolicyEvaluator.assessCommittedOrder,
            (engineAddress, order.orderId, request.executor, request.executionPrice, request.oraclePublishTime)
        );
    }

    function _settleTypedFailure(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        AccountState memory preState,
        TerminalClassification memory classification,
        bool priceReachedEngine
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        IOrderRouterExecutionHost.BountySettlement memory bountySettlement = context.host
            .settleOrderFromSidecar(
                context.order.orderId,
                false,
                classification.reason,
                request.executor,
                request.executionPrice,
                request.bountyAccountingPrice,
                request.bountyAccountingPublishTime
            );
        _requireBounty(context.pending.executionBountyUsdc, bountySettlement.bountyUsdc);
        AccountState memory postState = _accountState(ICfdEngineCore(context.host.engine()), context.order.account);
        OrderV3Types.OrderReceipt memory receipt =
            _preparedBaseReceipt(context, request, classification.reason, request.executionMode, priceReachedEngine);
        _setBountySettlement(receipt, bountySettlement);
        receipt.failure = classification.failure;
        receipt.economics = _stateOnlyEconomics(preState, postState);
        return _finalizeReceipt(context.book, receipt);
    }

    function _settleNonEngine(
        IOrderRouterExecutionHost,
        IOrderLifecycleBook,
        CfdTypes.Order memory,
        OrderV3Types.PendingIntent memory,
        IOrderRouterExecutionHost.ItemRequest memory request,
        OrderV3Types.TerminalReason reason,
        OrderV3Types.FailureDetails memory failure
    ) private returns (OrderV3Types.ExecutionResult memory) {
        return _delegateRecovery(abi.encodeCall(OrderRecoverySidecar.settleNonEngine, (request, reason, failure)));
    }

    function _settleRiskOff(
        IOrderRouterExecutionHost host,
        IOrderLifecycleBook book,
        CfdTypes.Order memory order,
        OrderV3Types.PendingIntent memory pending,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        uint64 riskOffCutoff
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        uint256 bountyUsdc = host.refundRiskOffOrderFromSidecar(order.orderId, riskOffCutoff);
        _requireBounty(pending.executionBountyUsdc, bountyUsdc);
        // Risk-off only releases reservation classifications: settlement balance, trader claim, and position state
        // cannot change. Read the normalized receipt state once after cleanup instead of duplicating four external
        // reads for every order in the bounded emergency batch.
        AccountState memory state = _accountState(ICfdEngineCore(host.engine()), order.account);

        OrderV3Types.OrderReceipt memory receipt = _baseReceipt(
            order.orderId,
            pending,
            request.executor,
            request.observedConfigHash,
            OrderV3Types.TerminalReason.RiskOff,
            OrderV3Types.ExecutionMode.None,
            OrderV3Types.PriceSource.None,
            0,
            request.neutralMarkPrice,
            request.poolDepthUsdc,
            0,
            false
        );
        receipt.bountyUsdc = bountyUsdc;
        if (bountyUsdc != 0) {
            receipt.bountyRecipient = order.account;
            receipt.bountyDisposition = OrderV3Types.BountyDisposition.RefundedToAccount;
        }
        receipt.economics = _stateOnlyEconomics(state, state);
        return _finalizeReceipt(book, receipt);
    }

    function _baseReceipt(
        uint64 orderId,
        OrderV3Types.PendingIntent memory pending,
        address executor,
        bytes32 observedConfigHash,
        OrderV3Types.TerminalReason reason,
        OrderV3Types.ExecutionMode executionMode,
        OrderV3Types.PriceSource priceSource,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 poolDepthUsdc,
        uint64 oraclePublishTime,
        bool priceReachedEngine
    ) private pure returns (OrderV3Types.OrderReceipt memory receipt) {
        receipt.closeMode = pending.closeMode;
        receipt.commitment = pending.commitment;
        receipt.bounty.bountyEntitlementUsdc = pending.executionBountyUsdc;
        receipt.orderId = orderId;
        receipt.account = pending.account;
        receipt.clientOrderId = pending.clientOrderId;
        receipt.intentHash = pending.intentHash;
        receipt.timing = pending.timing;
        receipt.expectedConfigHash = pending.bounds.expectedConfigHash;
        receipt.observedConfigHash = observedConfigHash;
        receipt.status = OrderV3Types.LifecycleStatus.Failed;
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

    function _preparedBaseReceipt(
        PreparedExecutionContext memory context,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        OrderV3Types.TerminalReason reason,
        OrderV3Types.ExecutionMode executionMode,
        bool priceReachedEngine
    ) private pure returns (OrderV3Types.OrderReceipt memory receipt) {
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
        OrderV3Types.OrderReceipt memory receipt
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        if (receipt.reason != OrderV3Types.TerminalReason.ExpiredReservationMismatch) {
            if (receipt.bountyDisposition == OrderV3Types.BountyDisposition.Paid) {
                receipt.bounty.bountyPaidUsdc = receipt.bountyUsdc;
            } else if (receipt.bountyDisposition == OrderV3Types.BountyDisposition.Forfeited) {
                receipt.bounty.bountyForfeitedUsdc = receipt.bountyUsdc;
            } else if (receipt.bountyDisposition == OrderV3Types.BountyDisposition.RefundedToAccount) {
                receipt.bounty.bountyRefundedUsdc = receipt.bountyUsdc;
            } else if (receipt.bountyDisposition == OrderV3Types.BountyDisposition.RetainedForProtectionRetry) {
                receipt.bounty.bountyRetainedUsdc = receipt.bountyUsdc;
            }
        }
        bytes32 receiptHash = book.finalize(receipt);
        result.orderId = receipt.orderId;
        result.status = receipt.status;
        result.terminalReason = receipt.reason;
        result.receiptHash = receiptHash;
    }

    function _assessmentEconomics(
        OrderV3Types.ExecutionAssessment memory assessment,
        AccountState memory preState,
        AccountState memory postState
    ) private pure returns (OrderV3Types.OrderEconomics memory economics) {
        economics.close = assessment.close;
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
    ) private pure returns (OrderV3Types.OrderEconomics memory economics) {
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
            bool knownCode = isClose == 0 ? code > 0 && code <= 10 : isClose == 1 && code > 0 && code <= 6;
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
                classification.reason = OrderV3Types.TerminalReason.PlannerRejected;
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
            if (mode > 0 && mode <= uint256(OrderV3Types.ExecutionMode.Frozen) && mask <= 7) {
                classification.terminal = true;
                classification.reason = OrderV3Types.TerminalReason.ExecutionModeDisallowed;
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
            if (constraint > 0 && constraint <= uint256(OrderV3Types.ConstraintKind.PostLeverage)) {
                classification.terminal = true;
                classification.reason = OrderV3Types.TerminalReason.ConstraintViolation;
                classification.failure.selector = selector;
                classification.failure.constraint = OrderV3Types.ConstraintKind(constraint);
                classification.failure.actual = _word(revertData, 36);
                classification.failure.limit = _word(revertData, 68);
                classification.failure.revertDataHash = keccak256(revertData);
            }
        }
    }

    function _preOracleAction(
        IOrderRouterExecutionHost host,
        CfdTypes.Order memory order,
        uint64 orderId,
        uint64 riskOffCutoff
    ) private view returns (IOrderRouterExecutionHost.ItemAction action, bool terminal) {
        if (_isRiskOffOpen(orderId, order.isClose, riskOffCutoff)) {
            return (IOrderRouterExecutionHost.ItemAction.RiskOff, true);
        }
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(orderId);
        if (pending.account != order.account) {
            revert OrderRouterExecutionSidecar__OrderIdentityMismatch(orderId);
        }
        if (block.timestamp > pending.timing.executionDeadline) {
            return (IOrderRouterExecutionHost.ItemAction.Expire, true);
        }
        bytes32 expectedConfigHash = pending.bounds.expectedConfigHash;
        // External V3 commits reject zero; internal trigger closes use it to inherit execution-time configuration.
        if (expectedConfigHash != bytes32(0) && book.currentExecutionConfigHash() != expectedConfigHash) {
            return (IOrderRouterExecutionHost.ItemAction.ConfigMismatch, true);
        }
        return (IOrderRouterExecutionHost.ItemAction.Execute, false);
    }

    function _preOracleItem(
        IOrderRouterExecutionHost host,
        uint64 orderId,
        IOrderRouterExecutionHost.ItemAction action,
        address executor
    ) private view returns (IOrderRouterExecutionHost.ItemRequest memory request) {
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
        IOrderRouterExecutionHost host,
        CfdTypes.Order memory order,
        OracleResult memory oracleResult,
        address executor
    ) private view returns (IOrderRouterExecutionHost.ItemRequest memory request) {
        ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
        request.orderId = order.orderId;
        request.action = IOrderRouterExecutionHost.ItemAction.Execute;
        request.executor = executor;
        request.observedConfigHash = IOrderLifecycleBook(host.lifecycleBook()).currentExecutionConfigHash();
        request.executionMode = oracleResult.mode;
        request.priceSource = OrderV3Types.PriceSource.OracleExecution;
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
        IOrderRouterExecutionHost host,
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
        IOrderRouterExecutionHost host,
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
            ? OrderV3Types.ExecutionMode.Frozen
            : snapshot.isFadWindow ? OrderV3Types.ExecutionMode.Fad : OrderV3Types.ExecutionMode.Live;
    }

    function _updateEngineMark(
        IOrderRouterExecutionHost host,
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
        IOrderRouterExecutionHost host,
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
        IOrderRouterExecutionHost.OrderView memory orderView
    ) private pure {
        if (!orderView.pending || orderView.order.orderId != orderId || orderView.order.account == address(0)) {
            revert OrderRouterExecutionSidecar__OrderIdentityMismatch(orderId);
        }
    }

    function _riskOffCutoff(
        IOrderRouterExecutionHost host
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
            revert OrderRouterExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
        reserve += minEngineGas;
        uint256 available = gasleft();
        if (available <= reserve) {
            revert OrderRouterExecutionSidecar__RetryableFailure(
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
            revert OrderRouterExecutionSidecar__RetryableFailure(
                engineAddress, OrderRouter__InsufficientGas.selector, 0
            );
        }
        callGas = available - POST_ENGINE_GAS_RESERVE;
        uint256 eip150Limit = available - (available / 64);
        uint256 forwardable = callGas < eip150Limit ? callGas : eip150Limit;
        if (forwardable < minEngineGas) {
            revert OrderRouterExecutionSidecar__RetryableFailure(
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
        OrderV3Types.ExecutionAssessment memory assessment,
        OrderV3Types.ExecutionMode requestedMode,
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
            revert OrderRouterExecutionSidecar__AssessmentStateMismatch(field, expected, actual);
        }
    }

    function _pendingResult(
        uint64 orderId,
        OrderV3Types.PendingReason reason
    ) private pure returns (OrderV3Types.ExecutionResult memory result) {
        result.orderId = orderId;
        result.status = OrderV3Types.LifecycleStatus.Pending;
        result.pendingReason = reason;
    }

    function _refundEth(
        IOrderRouterExecutionHost host,
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
            revert OrderRouterExecutionSidecar__BountyMismatch(expected, actual);
        }
    }

    function _setBountySettlement(
        OrderV3Types.OrderReceipt memory receipt,
        IOrderRouterExecutionHost.BountySettlement memory settlement
    ) private pure {
        receipt.bountyUsdc = settlement.bountyUsdc;
        receipt.bountyRecipient = settlement.bountyRecipient;
        receipt.bountyDisposition = settlement.bountyDisposition;
    }

    function _revertRetryable(
        address target,
        bytes memory revertData
    ) private pure {
        revert OrderRouterExecutionSidecar__RetryableFailure(target, _selector(revertData), revertData.length);
    }

    function _pendingReasonForRevert(
        bytes memory revertData
    ) internal pure returns (OrderV3Types.PendingReason reason) {
        if (revertData.length == 0) {
            return OrderV3Types.PendingReason.EngineFailure;
        }
        bytes4 outerSelector = _selector(revertData);
        if (outerSelector == OrderRouterExecutionSidecar__RetryableFailure.selector && revertData.length == 100) {
            bytes4 innerSelector = _bytes4Word(revertData, 36);
            if (
                innerSelector == ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector
                    || innerSelector == OrderRouter__MarkPriceOutOfOrder.selector
            ) {
                return OrderV3Types.PendingReason.MarkPriceOutOfOrder;
            }
            if (innerSelector == OrderRouter__InsufficientGas.selector) {
                return OrderV3Types.PendingReason.InsufficientGas;
            }
            return OrderV3Types.PendingReason.EngineFailure;
        }
        if (
            outerSelector == OrderRouterExecutionSidecar__MalformedSuccess.selector
                || outerSelector == OrderRouterExecutionSidecar__AssessmentStateMismatch.selector
        ) {
            return OrderV3Types.PendingReason.EngineFailure;
        }
        return OrderV3Types.PendingReason.ReceiptFailure;
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
