// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderExecutionHandler
/// @notice Coordinates oracle fees, FIFO traversal, terminal cleanup, and ETH refunds for keeper execution calls.
abstract contract OrderExecutionHandler is OrderValidation {

    /// @notice Processes one requested FIFO order after bounded pre-oracle expiry pruning.
    /// @dev If pruning empties the queue, passes the target, or makes progress without landing on the requested
    ///      target as the new head, it refunds all ETH and returns. Otherwise it prices the initial live head,
    ///      cleans stale preceding orders, enforces that the target resolves to the current head, and may pay a
    ///      second oracle fee if the priced head changed. Unused ETH is refunded or deferred.
    /// @param orderId Head order to execute, or later id used as the expiry-pruning bound.
    /// @param pythUpdateData Pyth update blobs shared by oracle attempts in this call.
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

    /// @notice Processes consecutive FIFO orders up to a committed inclusive id and policy/gas/prune boundary.
    /// @dev Reuses compatible historical oracle caches, aggregates Pyth fees, and terminally clears expiry, slippage,
    ///      and engine failures other than mark-price-out-of-order. That error reverts the batch nonterminally.
    ///      Unavailable history reverts when no earlier batch step made progress; after an execution or expiry cleanup
    ///      it stops and preserves the blocked order. One refund/defer attempt follows.
    /// @param maxOrderId Inclusive last committed order id the loop may process.
    /// @param pythUpdateData Pyth update blobs shared by all batch oracle attempts.
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

    /// @notice Applies a mark-refresh oracle update and forwards it to the engine.
    /// @param pythUpdateData Pyth update blobs supplied by the caller.
    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        _prepareMarkRefreshOracle(pythUpdateData);
    }

    /// @notice Sends an ETH refund or credits it in the admin contract when the recipient rejects the transfer.
    /// @dev A zero amount is a no-op. The fallback admin credit is funded with the same ETH amount and may revert.
    /// @param to Refund recipient.
    /// @param amount Amount to return in wei.
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
