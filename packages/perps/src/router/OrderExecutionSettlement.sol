// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";
import {OrderQueueBook} from "@plether/perps/router/OrderQueueBook.sol";

/// @title OrderExecutionSettlement
/// @notice Defines retained execution events and hooks for canonical Router terminal settlement.
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

    /// @notice Removes an order from all live queues and records its terminal status.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus `Executed` or `Failed` status to retain.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

    /// @notice Fails protection attached to a risk-off parent and returns its no-checkpoint bounty refund.
    /// @dev The default keeps the execution layer independent of optional attached-order features.
    function _failPendingOpenProtectionForRiskOff(
        uint64 parentOrderId,
        address account
    ) internal virtual returns (uint256 refundableProtectionBountyUsdc) {
        parentOrderId;
        account;
        return 0;
    }

}
