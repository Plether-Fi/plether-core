// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";

/// @title OrderQueueBook
/// @notice Maintains the Router's global FIFO list and pending-order accessors.
abstract contract OrderQueueBook is OrderReservationAccounting {

    /// @notice Current head order id of the global execution queue, or zero when the queue is empty.
    uint64 public nextExecuteId = 1;
    /// @notice Current tail order id of the global execution queue, or zero when the queue is empty.
    uint64 public globalTailOrderId;

    /// @notice Appends an order id to the global doubly linked FIFO queue.
    /// @param orderId Newly committed order id to append.
    function _linkGlobalOrder(
        uint64 orderId
    ) internal {
        uint64 tailOrderId = globalTailOrderId;
        if (tailOrderId == 0) {
            nextExecuteId = orderId;
            globalTailOrderId = orderId;
            return;
        }

        orderRecords[tailOrderId].nextGlobalOrderId = orderId;
        orderRecords[orderId].prevGlobalOrderId = tailOrderId;
        globalTailOrderId = orderId;
    }

    /// @notice Removes an order from the global queue and clears its global pointers.
    /// @dev Reverts if head, tail, and neighboring pointers reveal a corrupt list.
    /// @param orderId Live global order id to remove.
    function _unlinkGlobalOrder(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint64 prevOrderId = record.prevGlobalOrderId;
        uint64 nextOrderId = record.nextGlobalOrderId;
        uint64 headOrderId = nextExecuteId;
        uint64 tailOrderId = globalTailOrderId;

        if (headOrderId == orderId) {
            nextExecuteId = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextGlobalOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__GlobalQueueCorrupt();
        }

        if (tailOrderId == orderId) {
            globalTailOrderId = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevGlobalOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__GlobalQueueCorrupt();
        }

        record.nextGlobalOrderId = 0;
        record.prevGlobalOrderId = 0;
    }

    /// @notice Loads an order record and requires it to have `Pending` status.
    /// @param orderId Order id to load.
    /// @return record Mutable storage reference to the order record.
    /// @return order In-memory copy of its canonical order payload.
    function _pendingOrder(
        uint64 orderId
    ) internal view returns (OrderRecord storage record, CfdTypes.Order memory order) {
        record = _orderRecord(orderId);
        if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
            revert OrderRouter__OrderNotPending();
        }
        order = record.core;
    }

    /// @notice Returns whether an open is permanently invalidated by the supplied inclusive risk-off cutoff.
    function _isRiskOffOpen(
        uint64 orderId,
        bool isClose,
        uint64 riskOffCutoff
    ) internal pure returns (bool) {
        return riskOffCutoff != 0 && orderId <= riskOffCutoff && !isClose;
    }

}
