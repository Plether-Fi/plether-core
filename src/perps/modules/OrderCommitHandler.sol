// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {OrderValidation} from "./OrderValidation.sol";

/// @notice Commit-time delayed-order handling and pending-order read helpers.
abstract contract OrderCommitHandler is OrderValidation {

    function _commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) internal {
        if (!isClose) {
            _validateOpenCommitAllowed();
        }
        _validateBaseCommit(sizeDelta, marginDelta, isClose);

        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));
        uint256 executionBountyUsdc = isClose
            ? _validatedCloseExecutionBountyUsdc(accountId, side, sizeDelta)
            : _validatedOpenExecutionBountyUsdc(accountId, side, sizeDelta, marginDelta);

        uint64 orderId = nextCommitId++;

        _reserveExecutionBounty(accountId, orderId, sizeDelta, executionBountyUsdc, isClose);
        _reserveCommittedMargin(accountId, orderId, isClose, marginDelta);

        OrderRecord storage record = orderRecords[orderId];
        record.core = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: orderId,
            side: side,
            isClose: isClose
        });
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        if (isClose) {
            pendingCloseSize[accountId] += sizeDelta;
        }
        _linkGlobalOrder(orderId);
        _linkAccountOrder(accountId, orderId);
        if (++pendingOrderCounts[accountId] > maxPendingOrders) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(7);
        }
        emit OrderCommitted(orderId, accountId, side);
    }

    function _syncMarginQueue(
        bytes32 accountId
    ) internal {
        _onlyEngine();
        _pruneMarginQueue(accountId);
    }

    function _getPendingOrderView(
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        OrderRecord storage record = orderRecords[orderId];
        CfdTypes.Order memory order = record.core;
        pending = IOrderRouterAccounting.PendingOrderView({
            orderId: orderId,
            isClose: order.isClose,
            side: order.side,
            sizeDelta: order.sizeDelta,
            marginDelta: order.marginDelta,
            targetPrice: order.targetPrice,
            commitTime: order.commitTime,
            commitBlock: order.commitBlock,
            committedMarginUsdc: clearinghouse.getOrderReservation(orderId).remainingAmountUsdc,
            executionBountyUsdc: record.executionBountyUsdc
        });
        nextAccountOrderId = record.nextAccountOrderId;
    }

}
