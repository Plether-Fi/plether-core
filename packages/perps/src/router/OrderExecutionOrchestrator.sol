// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";
import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";

/// @title OrderExecutionOrchestrator
/// @notice Applies expiry, policy, MEV, slippage, and gas gates around one FIFO order execution step.
abstract contract OrderExecutionOrchestrator is OrderExecutionSettlement {

    /// @notice Control signal returned to the batch or single-order handler after an execution step.
    enum OrderExecutionStepResult {
        /// @notice The current order was terminally processed; a batch may continue.
        Continue,
        /// @notice The current order remains pending and batch processing must stop.
        Break,
        /// @notice A single-order call terminally processed its target and should return.
        Return
    }

    /// @notice Initial maximum pending lifetime: 60 seconds.
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    /// @notice Maximum order age in seconds; zero disables age-based expiry.
    uint256 public maxOrderAge = DEFAULT_MAX_ORDER_AGE;
    /// @notice Minimum EIP-150-forwardable gas required before calling the engine.
    uint256 public minEngineGas;
    /// @notice Maximum number of expired head orders that one execution call may prune.
    uint256 public maxPruneOrdersPerCall;

    /// @notice Releases committed margin immediately before the engine execution call.
    /// @param orderId Order whose committed-margin reservation is released.
    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal virtual;

    /// @notice Prunes expired heads strictly before `upToId` using a resolved oracle snapshot.
    /// @param upToId Inclusive traversal ceiling but excluded as a prune target.
    /// @param executionPrice Price used for bounty accounting on pruned orders (8 decimals).
    /// @param oraclePublishTime Publish timestamp used for bounty accounting on pruned orders.
    /// @return skipped Number of expired pending orders terminally failed.
    function _skipStaleOrders(
        uint64 upToId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 skipped) {
        skipped = _pruneExpiredHeadOrders(upToId, maxPruneOrdersPerCall, executionPrice, oraclePublishTime, false);
    }

    /// @notice Prunes expired heads before paying for oracle work, using the engine's cached mark.
    /// @param upToId Highest order id to consider.
    /// @param includeUpTo Whether the order exactly equal to `upToId` may also be pruned.
    /// @return skipped Number of expired pending orders terminally failed.
    function _skipExpiredHeadOrdersBeforeOracle(
        uint64 upToId,
        bool includeUpTo
    ) internal returns (uint256 skipped) {
        OracleUpdateResult memory cleanupMark = _cachedMarkForExpiredOrderCleanup();
        skipped = _pruneExpiredHeadOrders(
            upToId, maxPruneOrdersPerCall, cleanupMark.executionPrice, cleanupMark.oraclePublishTime, includeUpTo
        );
    }

    /// @notice Terminally removes consecutive expired global queue heads within explicit bounds.
    /// @dev Non-pending records encountered at the head are bypassed without incrementing `pruned`. Expiry is
    ///      disabled when `maxOrderAge == 0`. Every pruned order releases margin and pays its bounty to `msg.sender`.
    /// @param upToId Highest global order id considered.
    /// @param maxPrunes Maximum expired pending orders to remove.
    /// @param executionPrice Price used for keeper-bounty accounting (8 decimals).
    /// @param oraclePublishTime Publish timestamp used for keeper-bounty accounting.
    /// @param includeUpTo Whether the order exactly equal to `upToId` may be pruned.
    /// @return pruned Number of expired pending orders removed.
    function _pruneExpiredHeadOrders(
        uint64 upToId,
        uint256 maxPrunes,
        uint256 executionPrice,
        uint64 oraclePublishTime,
        bool includeUpTo
    ) internal returns (uint256 pruned) {
        uint256 age = maxOrderAge;
        while (nextExecuteId != 0 && nextExecuteId <= upToId && pruned < maxPrunes) {
            uint64 headId = nextExecuteId;
            OrderRecord storage record = _orderRecord(headId);
            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }
            if ((!includeUpTo && headId == upToId) || age == 0) {
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

    /// @notice Builds the price metadata used when expiry cleanup happens before an oracle update.
    /// @dev Uses the cap-bounded commit reference price and the engine's stored mark time; mark price and fee remain zero.
    /// @return update Cleanup price metadata.
    function _cachedMarkForExpiredOrderCleanup() internal view returns (OracleUpdateResult memory update) {
        update.executionPrice = _commitReferencePrice();
        update.oraclePublishTime = engine.lastMarkTime();
    }

    /// @notice Applies terminal and blocking gates, then attempts one pending order against the engine.
    /// @dev Expiry, slippage, engine business-rule rejection or panic, and success consume the order and pay its
    ///      bounty. `CfdEngine__MarkPriceOutOfOrder` is instead rethrown, rolling back the call and leaving the order
    ///      pending. Close-only, same-block/post-commit MEV constraints, and insufficient gas also keep it pending:
    ///      single execution reverts while batch execution returns `Break`. MEV timing checks are waived in
    ///      frozen-oracle mode. The gas check uses the EIP-150 forwardable amount `gasleft() - gasleft()/64`.
    /// @param orderId Pending order id.
    /// @param order In-memory order payload.
    /// @param executionPrice Validated order execution price (8 decimals).
    /// @param oraclePublishTime Publish timestamp of the execution price.
    /// @param executionContext Oracle policy flags captured with the price.
    /// @param revertOnBlockedExecution True for single-order semantics, false for batch stop semantics.
    /// @return result Signal directing the calling handler to continue, stop, or return.
    function _executePendingOrder(
        uint64 orderId,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 oraclePublishTime,
        RouterExecutionContext memory executionContext,
        bool revertOnBlockedExecution
    ) internal returns (OrderExecutionStepResult result) {
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, OrderFailReason.Expired);
            _finalizeOrCleanupOrder(
                orderId, false, _failedOutcomeForTerminalFailure(order), executionPrice, oraclePublishTime
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        if (!order.isClose && executionContext.openExecutionCloseOnly) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__CloseOnlyWindow();
            }
            return OrderExecutionStepResult.Break;
        }

        if (!executionContext.oracleFrozen && block.number == order.commitBlock) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__MevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (!executionContext.oracleFrozen && oraclePublishTime <= order.commitTime) {
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

}
