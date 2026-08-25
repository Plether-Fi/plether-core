// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";
import {OrderQueueBook} from "@plether/perps/router/OrderQueueBook.sol";

/// @title OrderExecutionSettlement
/// @notice Classifies engine execution failures and performs terminal reservation and queue settlement.
abstract contract OrderExecutionSettlement is OrderOracleExecution, OrderQueueBook {

    /// @notice Public classification emitted when an order reaches a failed terminal state.
    enum OrderFailReason {
        /// @notice The configured maximum order age elapsed.
        Expired,
        /// @notice Execution was blocked by close-only policy.
        /// @dev Reserved for compatibility; close-only currently stops/reverts execution without terminal failure.
        CloseOnly,
        /// @notice The resolved price violated the order's direction-aware limit.
        SlippageExceeded,
        /// @notice The engine reverted with Solidity's `Panic(uint256)` selector.
        EnginePanic,
        /// @notice The order was cleared because its account was liquidated.
        AccountLiquidated,
        /// @notice A non-panic engine revert other than the separately rethrown mark-price-out-of-order selector,
        ///         including empty data.
        EngineRevert,
        /// @notice A pre-cutoff open was invalidated by the persistent emergency risk-off latch.
        RiskOff
    }

    /// @notice Emitted when an order is processed successfully and reaches `Executed` status.
    /// @param orderId Executed order id.
    /// @param executionPrice Oracle price used by the engine (8 decimals).
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    /// @notice Emitted when an order is terminally failed and removed from live queues.
    /// @param orderId Failed order id.
    /// @param reason Router-level failure classification.
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);

    /// @notice Solidity `Panic(uint256)` error selector.
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    /// @notice Engine out-of-order mark selector promoted to a nonterminal router revert.
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector;

    /// @notice Removes an order from all live queues and records its terminal status.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus `Executed` or `Failed` status to retain.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

    /// @notice Calls the engine's typed order path and normalizes success or revert classification.
    /// @dev A mark-price-out-of-order engine revert is promoted to a router revert instead of terminally
    ///      failing the order. Other panics and reverts return failure metadata to the caller.
    /// @param order Order payload to process.
    /// @param executionPrice Validated execution price (8 decimals).
    /// @param housePoolDepth Current HousePool assets used as execution depth (6-decimal USDC).
    /// @param oraclePublishTime Publish timestamp of the execution basket.
    /// @return success Whether the engine processed the order.
    /// @return failureReason Meaningful only when `success` is false.
    function _processTypedOrderExecution(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 housePoolDepth,
        uint64 oraclePublishTime
    ) internal returns (bool success, OrderFailReason failureReason) {
        try engine.processOrderTyped(order, executionPrice, housePoolDepth, oraclePublishTime) {
            return (true, OrderFailReason.EngineRevert);
        } catch (bytes memory revertData) {
            bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
            if (selector == MARK_PRICE_OUT_OF_ORDER_SELECTOR) {
                revert OrderRouter__MarkPriceOutOfOrder();
            }
            failureReason = selector == PANIC_SELECTOR ? OrderFailReason.EnginePanic : OrderFailReason.EngineRevert;
            return (false, failureReason);
        }
    }

    /// @notice Dispatches an order to successful finalization or failed cleanup.
    /// @param orderId Order id to settle.
    /// @param success Whether engine execution succeeded.
    /// @param executionPrice Execution price supplied to bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to bounty accounting.
    function _finalizeOrCleanupOrder(
        uint64 orderId,
        bool success,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        if (success) {
            _finalizeExecution(orderId, executionPrice, oraclePublishTime);
        } else {
            _cleanupOrder(orderId, executionPrice, oraclePublishTime);
        }
    }

    /// @notice Releases failed-order margin, pays its reserved bounty to `msg.sender`, and records `Failed` status.
    /// @param orderId Failed order id.
    /// @param executionPrice Price supplied to engine bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to engine bounty accounting.
    /// @return executionBountyUsdc Bounty credited to the caller (6-decimal USDC), or zero.
    function _cleanupOrder(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderReservation(orderId, false, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
    }

    /// @notice Refunds one invalidated open to its account without paying or consulting an oracle.
    /// @dev Router queue and bounty effects precede the clearinghouse call; any downstream failure reverts all effects.
    function _refundRiskOffOrder(
        uint64 orderId,
        uint64 riskOffCutoff
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (
            record.status != IOrderRouterAccounting.OrderStatus.Pending
                || !_isRiskOffOpen(orderId, record.core.isClose, riskOffCutoff)
        ) {
            revert OrderRouter__OrderNotRiskOff();
        }

        uint64[] memory orderIds = new uint64[](1);
        orderIds[0] = orderId;
        address account = record.core.account;
        uint256 executionBountyUsdc = record.executionBountyUsdc;
        record.executionBountyUsdc = 0;
        emit OrderFailed(orderId, OrderFailReason.RiskOff);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
        clearinghouse.releaseInvalidatedOrderReserves(account, orderIds, executionBountyUsdc);
    }

    /// @notice Refunds every invalidated open in one account queue.
    /// @dev The account queue is bounded by the admin-enforced pending-order limit (currently at most 32).
    ///      Each refund uses the same exact single-order Clearinghouse reversal as permissionless cleanup.
    /// @return refundedOrders Number of invalidated opens removed and refunded.
    function _refundRiskOffAccountOrders(
        address account,
        uint64 riskOffCutoff
    ) internal returns (uint256 refundedOrders) {
        if (riskOffCutoff == 0) {
            return 0;
        }

        uint64 orderId = accountHeadOrderId[account];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            uint64 nextOrderId = record.nextAccountOrderId;
            if (_isRiskOffOpen(orderId, record.core.isClose, riskOffCutoff)) {
                _refundRiskOffOrder(orderId, riskOffCutoff);
                ++refundedOrders;
            }
            orderId = nextOrderId;
        }
    }

    /// @notice Pays a successfully executed order's bounty and records `Executed` status.
    /// @param orderId Executed order id.
    /// @param executionPrice Price supplied to engine bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to engine bounty accounting.
    function _finalizeExecution(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        _consumeOrderReservation(orderId, true, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Executed);
    }

}
