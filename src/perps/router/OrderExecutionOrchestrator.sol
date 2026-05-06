// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {OracleFreshnessPolicyLib} from "../libraries/OracleFreshnessPolicyLib.sol";
import {OrderValidationLib} from "../libraries/OrderValidationLib.sol";
import {OrderExecutionSettlement} from "./OrderExecutionSettlement.sol";

abstract contract OrderExecutionOrchestrator is OrderExecutionSettlement {

    enum OrderExecutionStepResult {
        Continue,
        Break,
        Return
    }

    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 public maxOrderAge = DEFAULT_MAX_ORDER_AGE;
    uint256 public minEngineGas;
    uint256 public maxPruneOrdersPerCall;

    function _releaseCommittedMarginForExecution(
        uint64 orderId
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
        uint256 age = maxOrderAge;
        while (nextExecuteId != 0 && nextExecuteId <= upToId && pruned < maxPrunes) {
            uint64 headId = nextExecuteId;
            OrderRecord storage record = _orderRecord(headId);
            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
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

    function _executePendingOrder(
        uint64 orderId,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 oraclePublishTime,
        RouterExecutionContext memory executionContext,
        bool revertOnBlockedExecution
    ) internal returns (OrderExecutionStepResult result) {
        OracleFreshnessPolicyLib.Policy memory orderPolicy =
            _executionPolicyForOrder(order.isClose, executionContext.oracleFrozen, executionContext.isFadWindow);
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, OrderFailReason.Expired);
            _finalizeOrCleanupOrder(
                orderId, false, _failedOutcomeForTerminalFailure(order), executionPrice, oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        if (orderPolicy.closeOnly) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__CloseOnlyWindow();
            }
            return OrderExecutionStepResult.Break;
        }

        if (address(pyth) != address(0) && !executionContext.oracleFrozen && block.number == order.commitBlock) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__MevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (address(pyth) != address(0) && !executionContext.oracleFrozen && oraclePublishTime <= order.commitTime) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__MevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (!OrderValidationLib.checkSlippage(order, executionPrice)) {
            emit OrderFailed(orderId, OrderFailReason.SlippageExceeded);
            _finalizeOrCleanupOrder(
                orderId, false, _failedOutcomeForSlippageFailure(order), executionPrice, oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        uint256 forwardedGas = gasleft() - (gasleft() / 64);
        if (forwardedGas < minEngineGas) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__InsufficientGas();
            }
            return OrderExecutionStepResult.Break;
        }

        uint256 housePoolDepth = housePool.totalAssets();
        _releaseCommittedMarginForExecution(orderId);

        (bool executionSucceeded, OrderFailReason failureReason, FailedOrderOutcome failureOutcome) =
            _processTypedOrderExecution(order, executionPrice, housePoolDepth, oraclePublishTime);
        if (executionSucceeded) {
            emit OrderExecuted(orderId, executionPrice);
            _finalizeOrCleanupOrder(orderId, true, FailedOrderOutcome.ClearerFull, executionPrice, oraclePublishTime);
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        emit OrderFailed(orderId, failureReason);
        _finalizeOrCleanupOrder(orderId, false, failureOutcome, executionPrice, oraclePublishTime);
        return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal virtual;

}
