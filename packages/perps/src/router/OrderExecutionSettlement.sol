// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";
import {OrderQueueBook} from "@plether/perps/router/OrderQueueBook.sol";

/// @title OrderExecutionSettlement
/// @notice Defines retained execution events and hooks for canonical Router terminal settlement.
abstract contract OrderExecutionSettlement is OrderOracleExecution, OrderQueueBook {

    /// @notice Legacy failure classifications retained for the Router event ABI.
    /// @dev V3 emits `OrderFailed` only for RiskOff and AccountLiquidated. Every V3 terminal reason is recorded by
    ///      `OrderLifecycleBook.OrderFinalized`; the remaining enum members are retained compatibility values.
    enum OrderFailReason {
        /// @notice Legacy age-based expiry classification.
        Expired,
        /// @notice Legacy close-only classification; V3 leaves close-only opens pending.
        CloseOnly,
        /// @notice Legacy classification for a direction-aware limit violation.
        SlippageExceeded,
        /// @notice Legacy panic classification; V3 panics leave the order pending.
        EnginePanic,
        /// @notice The order was cleared because its account was liquidated.
        AccountLiquidated,
        /// @notice Legacy non-panic engine-revert classification; V3 requires recognized typed terminal evidence.
        EngineRevert,
        /// @notice A pre-cutoff open was invalidated by the persistent emergency risk-off latch.
        RiskOff
    }

    /// @notice Emitted when an order is processed successfully and reaches `Executed` status.
    /// @param orderId Executed order id.
    /// @param executionPrice Oracle price used by the engine (8 decimals).
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    /// @notice Emitted for risk-off or account-liquidation cleanup when an order is removed from live queues.
    /// @dev Read `OrderLifecycleBook.OrderFinalized` for complete V3 terminal evidence, including other failures.
    /// @param orderId Failed order id.
    /// @param reason Router-level failure classification.
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);

    /// @notice Removes an order from live queues and passes its terminal status to feature lifecycle hooks.
    /// @dev Permanent terminal evidence is finalized separately in the lifecycle book.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus `Executed` or `Failed` status supplied to lifecycle hooks before record deletion.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

}
