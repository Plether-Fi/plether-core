// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineCore} from "../interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {CashPriorityLib} from "../libraries/CashPriorityLib.sol";
import {OracleFreshnessPolicyLib} from "../libraries/OracleFreshnessPolicyLib.sol";
import {OrderOracleExecution} from "./OrderOracleExecution.sol";
import {OrderQueueBook} from "./OrderQueueBook.sol";

abstract contract OrderExecutionOrchestrator is OrderOracleExecution, OrderQueueBook {

    enum OrderExecutionStepResult {
        Continue,
        Break,
        Return
    }

    enum FailedOrderOutcome {
        ClearerFull
    }

    enum OrderFailReason {
        Expired,
        CloseOnly,
        SlippageExceeded,
        EnginePanic,
        AccountLiquidated,
        EngineRevert
    }

    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);

    uint256 public minEngineGas;
    uint256 public maxPruneOrdersPerCall;
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    bytes4 internal constant TYPED_ORDER_FAILURE_SELECTOR = ICfdEngineCore.CfdEngine__TypedOrderFailure.selector;
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineCore.CfdEngine__MarkPriceOutOfOrder.selector;

    function _maxOrderAge() internal view virtual returns (uint256);
    function _queueHeadOrderId() internal view virtual override returns (uint64);
    function _setQueueHeadOrderId(
        uint64 orderId
    ) internal virtual override;

    function _revertNoOrdersToExecute() internal pure virtual;
    function _revertInsufficientGas() internal pure virtual;
    function _revertMevDetected() internal pure virtual;
    function _revertCloseOnlyMode() internal pure virtual;
    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal virtual;
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

    function _skipStaleOrders(
        uint64 upToId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 skipped) {
        skipped = _pruneExpiredHeadOrders(upToId, maxPruneOrdersPerCall, executionPrice, oraclePublishTime);
    }

    function _pruneExpiredHeadOrders(
        uint64 upToId,
        uint256 maxPrunes,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 pruned) {
        uint256 age = _maxOrderAge();
        while (_queueHeadOrderId() != 0 && _queueHeadOrderId() <= upToId && pruned < maxPrunes) {
            uint64 headId = _queueHeadOrderId();
            OrderRecord storage record = _orderRecord(headId);
            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                _setQueueHeadOrderId(record.nextGlobalOrderId);
                continue;
            }
            if (headId == upToId || age == 0) {
                break;
            }
            CfdTypes.Order memory order = record.core;
            if (block.timestamp - order.commitTime <= age) {
                break;
            }
            emit OrderFailed(headId, OrderFailReason.Expired);
            _cleanupOrder(headId, _failedOutcomeForTerminalFailure(order), executionPrice, oraclePublishTime);
            pruned++;
        }
    }

    function _processTypedOrderExecution(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 vaultDepth,
        uint64 oraclePublishTime
    ) internal returns (bool success, OrderFailReason failureReason, FailedOrderOutcome failureOutcome) {
        try engine.processOrderTyped(order, executionPrice, vaultDepth, oraclePublishTime) {
            return (true, OrderFailReason.EngineRevert, FailedOrderOutcome.ClearerFull);
        } catch (bytes memory revertData) {
            bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
            if (selector == MARK_PRICE_OUT_OF_ORDER_SELECTOR) {
                _revertOraclePublishTimeOutOfOrder();
            }
            failureReason = selector == PANIC_SELECTOR ? OrderFailReason.EnginePanic : OrderFailReason.EngineRevert;
            failureOutcome = _failedOutcomeFromEngineRevert(order, revertData);
            return (false, failureReason, failureOutcome);
        }
    }

    function _executePendingOrder(
        uint64 orderId,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 oraclePublishTime,
        RouterExecutionContext memory executionContext,
        bool revertOnBlockedExecution,
        uint256 pythFee
    ) internal returns (OrderExecutionStepResult result) {
        OracleFreshnessPolicyLib.Policy memory orderPolicy =
            _executionPolicyForOrder(order.isClose, executionContext.oracleFrozen, executionContext.isFadWindow);
        if (_maxOrderAge() > 0 && block.timestamp - order.commitTime > _maxOrderAge()) {
            emit OrderFailed(orderId, OrderFailReason.Expired);
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                false,
                _failedOutcomeForTerminalFailure(order),
                revertOnBlockedExecution,
                executionPrice,
                oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        if (orderPolicy.closeOnly) {
            if (revertOnBlockedExecution) {
                _revertCloseOnlyMode();
            }
            return OrderExecutionStepResult.Break;
        }

        if (address(pyth) != address(0) && !executionContext.oracleFrozen && block.number == order.commitBlock) {
            if (revertOnBlockedExecution) {
                _revertMevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (address(pyth) != address(0) && !executionContext.oracleFrozen && oraclePublishTime <= order.commitTime) {
            if (revertOnBlockedExecution) {
                _revertMevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (!_checkSlippage(order, executionPrice)) {
            emit OrderFailed(orderId, OrderFailReason.SlippageExceeded);
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                false,
                _failedOutcomeForSlippageFailure(order),
                revertOnBlockedExecution,
                executionPrice,
                oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        uint256 forwardedGas = gasleft() - (gasleft() / 64);
        if (forwardedGas < minEngineGas) {
            if (revertOnBlockedExecution) {
                _revertInsufficientGas();
            }
            return OrderExecutionStepResult.Break;
        }

        uint256 vaultDepth = vault.totalAssets();
        _releaseCommittedMarginForExecution(orderId);

        (bool executionSucceeded, OrderFailReason failureReason, FailedOrderOutcome failureOutcome) =
            _processTypedOrderExecution(order, executionPrice, vaultDepth, oraclePublishTime);
        if (executionSucceeded) {
            emit OrderExecuted(orderId, executionPrice);
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                true,
                FailedOrderOutcome.ClearerFull,
                revertOnBlockedExecution,
                executionPrice,
                oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        emit OrderFailed(orderId, failureReason);
        _finalizeOrCleanupOrder(
            orderId, pythFee, false, failureOutcome, revertOnBlockedExecution, executionPrice, oraclePublishTime
        );
        return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
    }

    function _finalizeOrCleanupOrder(
        uint64 orderId,
        uint256 pythFee,
        bool success,
        FailedOrderOutcome failedOutcome,
        bool refundEthNow,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        if (success) {
            _finalizeExecution(orderId, executionPrice, oraclePublishTime);
        } else {
            _cleanupOrder(orderId, failedOutcome, executionPrice, oraclePublishTime);
        }

        if (refundEthNow) {
            _sendEth(msg.sender, msg.value - pythFee);
        }
    }

    function _decodeTypedOrderFailure(
        bytes memory revertData
    )
        internal
        pure
        returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose)
    {
        assembly {
            failureCategory := mload(add(revertData, 36))
            failureCode := mload(add(revertData, 68))
            isClose := mload(add(revertData, 100))
        }
    }

    function _failedOutcomeFromEngineRevert(
        CfdTypes.Order memory order,
        bytes memory revertData
    ) internal pure returns (FailedOrderOutcome outcome) {
        if (revertData.length >= 4 && bytes4(revertData) == TYPED_ORDER_FAILURE_SELECTOR) {
            (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode,) =
                _decodeTypedOrderFailure(revertData);
            if (order.isClose) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCode == uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES)) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCategory == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCategory == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid) {
                return FailedOrderOutcome.ClearerFull;
            }
        }

        return _failedOutcomeForTerminalFailure(order);
    }

    function _failedOutcomeForTerminalFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    function _failedOutcomeForSlippageFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    function _cleanupOrder(
        uint64 orderId,
        FailedOrderOutcome,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderEscrow(orderId, false, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        _consumeOrderEscrow(orderId, true, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Executed);
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal virtual;

}
