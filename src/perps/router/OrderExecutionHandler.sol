// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {OrderRouterAdmin} from "../OrderRouterAdmin.sol";
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
        uint256 expiredPrunes = _skipExpiredHeadOrdersBeforeOracle(orderId, true);
        if (nextExecuteId == 0 || orderId < nextExecuteId || (expiredPrunes > 0 && orderId != nextExecuteId)) {
            _sendEth(msg.sender, msg.value);
            return;
        }
        uint64 initialHeadOrderId = nextExecuteId;
        (, CfdTypes.Order memory initialHeadOrder) = _pendingOrder(initialHeadOrderId);
        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, initialHeadOrder, 0);
        uint256 pythFeeTotal = update.pythFee;

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
        if (orderId != initialHeadOrderId) {
            (update, executionContext) = _prepareOrderExecutionOracle(pythUpdateData, order, pythFeeTotal);
            pythFeeTotal += update.pythFee;
        }

        _executePendingOrder(orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, true);
        _sendEth(msg.sender, msg.value - pythFeeTotal);
    }

    function _executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) internal {
        _validateBatchBounds(maxOrderId);

        OracleUpdateResult memory update;
        RouterExecutionContext memory executionContext;
        IPletherOracle.BatchOrderPriceCache memory oracleCache;
        uint256 pythFeeTotal;
        uint256 expiredPrunes;
        bool madeProgress;

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
                OracleUpdateResult memory cleanupMark = _cachedMarkForExpiredOrderCleanup();
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(
                    orderId,
                    _failedOutcomeForTerminalFailure(order),
                    cleanupMark.executionPrice,
                    cleanupMark.oraclePublishTime
                );
                expiredPrunes++;
                madeProgress = true;
                continue;
            }

            bool oracleResolved;
            (oracleResolved, update, executionContext, oracleCache) =
                _tryPrepareBatchOrderExecutionOracle(pythUpdateData, order, pythFeeTotal, oracleCache);
            if (!oracleResolved) {
                pythFeeTotal += update.pythFee;
                if (!madeProgress) {
                    _revertOrderExecutionStale();
                }
                break;
            }
            pythFeeTotal += update.pythFee;

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= maxPruneOrdersPerCall) {
                    break;
                }
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(
                    orderId, _failedOutcomeForTerminalFailure(order), update.executionPrice, update.oraclePublishTime
                );
                expiredPrunes++;
                madeProgress = true;
                continue;
            }

            OrderExecutionStepResult result = _executePendingOrder(
                orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, false
            );
            if (result == OrderExecutionStepResult.Break) {
                break;
            }
            madeProgress = true;
        }

        _sendEth(msg.sender, msg.value - pythFeeTotal);
    }

    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        _prepareMarkRefreshOracle(pythUpdateData);
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) {
            OrderRouterAdmin(admin).creditClaimableEth{value: amount}(to, amount);
        }
    }

}
