// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouter} from "../interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IPletherOracle} from "../interfaces/IPletherOracle.sol";
import {OrderValidation} from "./OrderValidation.sol";

/// @notice External-order execution entry handling for single and batch keeper execution.
abstract contract OrderExecutionHandler is OrderValidation {

    function _executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) internal {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        uint64 oracleOrderId = orderId < nextExecuteId ? nextExecuteId : orderId;
        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, _oracleModeForPendingOrder(oracleOrderId));

        _skipStaleOrders(orderId, update.executionPrice, update.oraclePublishTime);
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (orderId < nextExecuteId) {
            orderId = nextExecuteId;
        }
        if (orderId != nextExecuteId) {
            revert OrderRouter__OrderNotQueueHead();
        }
        (, CfdTypes.Order memory order) = _pendingOrder(orderId);

        _executePendingOrder(orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, true);
    }

    function _executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) internal {
        _validateBatchBounds(maxOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, _oracleModeForPendingOrder(nextExecuteId));
        uint256 expiredPrunes;

        while (nextExecuteId != 0 && nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= maxPruneOrdersPerCall) {
                    break;
                }
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(
                    orderId, _failedOutcomeForTerminalFailure(order), update.executionPrice, update.oraclePublishTime
                );
                expiredPrunes++;
                continue;
            }

            OrderExecutionStepResult result = _executePendingOrder(
                orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, false
            );
            if (result == OrderExecutionStepResult.Break) {
                break;
            }
        }
    }

    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        _prepareMarkRefreshOracle(pythUpdateData);
    }

    function _oracleModeForPendingOrder(
        uint64 orderId
    ) private view returns (IPletherOracle.PriceMode) {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.status == IOrderRouterAccounting.OrderStatus.Pending && record.core.isClose) {
            return IPletherOracle.PriceMode.MarkRefresh;
        }
        return IPletherOracle.PriceMode.OrderExecution;
    }

}
