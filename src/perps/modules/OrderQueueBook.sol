// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {OrderEscrowAccounting} from "./OrderEscrowAccounting.sol";

abstract contract OrderQueueBook is OrderEscrowAccounting {

    struct QueuedPositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
    }

    function _queueHeadOrderId() internal view virtual returns (uint64);

    function _setQueueHeadOrderId(
        uint64 orderId
    ) internal virtual;

    function _queueTailOrderId() internal view virtual returns (uint64);

    function _setQueueTailOrderId(
        uint64 orderId
    ) internal virtual;

    function _linkGlobalOrder(
        uint64 orderId
    ) internal {
        uint64 tailOrderId = _queueTailOrderId();
        if (tailOrderId == 0) {
            _setQueueHeadOrderId(orderId);
            _setQueueTailOrderId(orderId);
            return;
        }

        orderRecords[tailOrderId].nextGlobalOrderId = orderId;
        orderRecords[orderId].prevGlobalOrderId = tailOrderId;
        _setQueueTailOrderId(orderId);
    }

    function _unlinkGlobalOrder(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint64 prevOrderId = record.prevGlobalOrderId;
        uint64 nextOrderId = record.nextGlobalOrderId;
        uint64 headOrderId = _queueHeadOrderId();
        uint64 tailOrderId = _queueTailOrderId();

        if (headOrderId == orderId) {
            _setQueueHeadOrderId(nextOrderId);
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextGlobalOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert IOrderRouterErrors.OrderRouter__QueueState(6);
        }

        if (tailOrderId == orderId) {
            _setQueueTailOrderId(prevOrderId);
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevGlobalOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert IOrderRouterErrors.OrderRouter__QueueState(6);
        }

        record.nextGlobalOrderId = 0;
        record.prevGlobalOrderId = 0;
    }

    function _pendingOrder(
        uint64 orderId
    ) internal view returns (OrderRecord storage record, CfdTypes.Order memory order) {
        record = _orderRecord(orderId);
        if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
            revert IOrderRouterErrors.OrderRouter__QueueState(4);
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
