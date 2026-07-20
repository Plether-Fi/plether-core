// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";

/// @title OrderQueueBook
/// @notice Maintains the router's global FIFO list and derives account positions after applying queued intents.
abstract contract OrderQueueBook is OrderReservationAccounting {

    /// @notice Minimal position state produced by replaying an account's live queue over its engine position.
    /// @param exists Whether a nonzero position remains after replay.
    /// @param side Direction of that position.
    /// @param size Simulated position size in synthetic-token units (18 decimals).
    struct QueuedPositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
    }

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

    /// @notice Replays an account's queued closes and same-side opens over its current engine position.
    /// @dev Closes only reduce a simulated position of the same side and floor its size at zero. An open creates
    ///      a position when none exists and increases only a same-side simulated position; opposite-side opens
    ///      do not alter this projection because engine/preflight validation handles that invalid transition.
    /// @param account Account whose engine position and live queue are replayed.
    /// @return queuedPosition Projected position used to validate a new close commit.
    function _getQueuedPositionView(
        address account
    ) internal view returns (QueuedPositionView memory queuedPosition) {
        (uint256 positionSize,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (positionSize > 0) {
            queuedPosition.exists = true;
            queuedPosition.side = side;
            queuedPosition.size = positionSize;
        }

        for (
            uint64 orderId = accountHeadOrderId[account];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;

            if (order.isClose) {
                if (queuedPosition.exists && order.side == queuedPosition.side) {
                    queuedPosition.size =
                        queuedPosition.size > order.sizeDelta ? queuedPosition.size - order.sizeDelta : 0;
                    if (queuedPosition.size == 0) {
                        queuedPosition.exists = false;
                    }
                }
            } else if (!queuedPosition.exists || queuedPosition.size == 0) {
                queuedPosition.exists = true;
                queuedPosition.side = order.side;
                queuedPosition.size = order.sizeDelta;
            } else if (order.side == queuedPosition.side) {
                queuedPosition.size += order.sizeDelta;
            }
        }
    }

}
