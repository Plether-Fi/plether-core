// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouter} from "../interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {OrderReservationAccounting} from "./OrderReservationAccounting.sol";

abstract contract OrderQueueBook is OrderReservationAccounting {

    struct QueuedPositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
    }

    uint64 public nextExecuteId = 1;
    uint64 public globalTailOrderId;

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

    function _pendingOrder(
        uint64 orderId
    ) internal view returns (OrderRecord storage record, CfdTypes.Order memory order) {
        record = _orderRecord(orderId);
        if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
            revert OrderRouter__OrderNotPending();
        }
        order = record.core;
    }

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
