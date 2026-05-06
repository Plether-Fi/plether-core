// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
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
        uint64 initialHeadOrderId = nextExecuteId;
        (, CfdTypes.Order memory initialHeadOrder) = _pendingOrder(initialHeadOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, initialHeadOrder.targetPrice);

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
        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) internal {
        _validateBatchBounds(maxOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, 1e8);
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

        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareMarkRefreshOracle(pythUpdateData);
        _sendEth(msg.sender, msg.value - update.pythFee);
    }

}
