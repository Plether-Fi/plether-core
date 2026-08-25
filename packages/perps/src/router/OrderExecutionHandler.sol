// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderExecutionHandler
/// @notice Coordinates oracle fees, FIFO traversal, terminal cleanup, and ETH refunds for keeper execution calls.
abstract contract OrderExecutionHandler is OrderValidation {

    /// @notice Processes one requested FIFO order after bounded pre-oracle terminal-head cleanup.
    /// @dev If cleanup empties the queue, passes the target, or makes progress without landing on the requested
    ///      target as the new head, it refunds all ETH and returns. Otherwise it prices the initial live head,
    ///      cleans stale preceding orders, enforces that the target resolves to the current head, and may pay a
    ///      second oracle fee if the priced head changed. Unused ETH is refunded or deferred.
    /// @param orderId Head order to execute, or later id used as the terminal-head cleanup bound.
    /// @param pythUpdateData Pyth update blobs shared by oracle attempts in this call.
    function _executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) internal {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        uint64 riskOffCutoff = _riskOffOrderCutoff();
        (uint256 expiredPrunes, uint256 riskOffRefunds) =
            _skipTerminalHeadOrdersBeforeOracle(orderId, true, riskOffCutoff);
        bool terminalProgress = expiredPrunes != 0 || riskOffRefunds != 0;
        if (
            nextExecuteId == 0 || orderId < nextExecuteId || (terminalProgress && orderId != nextExecuteId)
                || riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL
        ) {
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
        uint256 riskOffRefunds;
        bool madeProgress;
        uint64 riskOffCutoff = _riskOffOrderCutoff();

        while (nextExecuteId != 0 && nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }

            if (_isRiskOffOpen(orderId, order.isClose, riskOffCutoff)) {
                if (riskOffRefunds == MAX_RISK_OFF_REFUNDS_PER_CALL) {
                    break;
                }
                _refundRiskOffOrder(orderId, riskOffCutoff);
                ++riskOffRefunds;
                madeProgress = true;
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= maxPruneOrdersPerCall) {
                    break;
                }
                OracleUpdateResult memory cleanupMark = _cachedMarkForExpiredOrderCleanup();
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(orderId, cleanupMark.executionPrice, cleanupMark.oraclePublishTime);
                expiredPrunes++;
                madeProgress = true;
                continue;
            }

            {
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
            }
            pythFeeTotal += update.pythFee;

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= maxPruneOrdersPerCall) {
                    break;
                }
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(orderId, update.executionPrice, update.oraclePublishTime);
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

    /// @notice Permissionlessly refunds one pending open covered by the persistent risk-off cutoff.
    function _clearRiskOffOrder(
        uint64 orderId
    ) internal {
        _refundRiskOffOrder(orderId, _riskOffOrderCutoff());
    }

    /// @notice Applies a mark-refresh oracle update and forwards it to the engine.
    /// @param pythUpdateData Pyth update blobs supplied by the caller.
    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        _refreshEngineMark(pythUpdateData, IPletherOracle.PriceMode.MarkRefresh, msg.value);
    }

    /// @notice Refreshes the pool-accounting mark and settles matured LP epochs in one rollback frame.
    /// @dev Sends only the quoted fee to the oracle so no excess-fee callback can occur before settlement. The caller's
    ///      remaining ETH is refunded only after the engine and HousePool have consumed the validated snapshot.
    /// @param pythUpdateData Pyth price update blobs supplied by the caller.
    function _settleLpEpoch(
        bytes[] calldata pythUpdateData
    ) internal {
        uint256 pythFee = _checkedPythFee(pythUpdateData, 0);
        (uint256 markPrice, uint64 publishTime) =
            _refreshEngineMark(pythUpdateData, IPletherOracle.PriceMode.PoolReconcile, pythFee);
        address pool = address(housePool);
        uint256 selector = uint32(IHousePool.settleLpEpoch.selector);
        // Call `settleLpEpoch(uint256,uint256)` without copying its large result struct into Router bytecode. The
        // HousePool event is canonical for the outcome; this path still bubbles the complete revert payload.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            mstore(add(ptr, 4), markPrice)
            mstore(add(ptr, 36), publishTime)
            if iszero(call(gas(), pool, 0, ptr, 68, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 448) { revert(0, 0) }
        }
        _sendEth(msg.sender, msg.value - pythFee);
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
