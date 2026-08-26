// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderCommitHandler
/// @notice Creates delayed orders, reserves their clearinghouse balances, and exposes order-record views.
abstract contract OrderCommitHandler is OrderValidation {

    /// @notice Maximum live pending orders allowed per account.
    uint256 public maxPendingOrders = 5;

    /// @notice Reserves funds, stores one live order, and appends it to the router's queue indexes.
    /// @dev Public commit entrypoints are non-reentrant and both reservation dependencies are immutable protocol
    ///      contracts. Any reservation failure reverts before the queue write and rolls back the complete transaction.
    // slither-disable-start reentrancy-benign
    function _createPendingOrder(
        CfdTypes.Order memory order,
        uint256 executionBountyUsdc
    ) internal {
        uint64 orderId = order.orderId;
        address account = order.account;
        _reserveExecutionBounty(account, order.sizeDelta, executionBountyUsdc, order.isClose);
        _reserveCommittedMargin(account, orderId, order.isClose, order.marginDelta);

        _recordCommittedOrder(order, executionBountyUsdc);
    }

    // slither-disable-end reentrancy-benign

    /// @notice Stores and links an already-validated order whose reservations have already been established.
    /// @dev Position-protection triggering reuses this primitive with a bounty transferred from the external book.
    function _recordCommittedOrder(
        CfdTypes.Order memory order,
        uint256 executionBountyUsdc
    ) internal {
        uint64 orderId = order.orderId;
        address account = order.account;
        OrderRecord storage record = orderRecords[orderId];
        record.core = order;
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        record.executionBountyUsdc = executionBountyUsdc;
        if (order.isClose) {
            pendingCloseSize[account] += order.sizeDelta;
        }
        _linkGlobalOrder(orderId);
        _linkAccountOrder(account, orderId);
        if (++pendingOrderCounts[account] > maxPendingOrders) {
            revert OrderRouter__TooManyPendingOrders();
        }
        emit OrderCommitted(orderId, account, order.side);
    }

    /// @dev Retained as an override seam for position-protection handlers; delegated commit logic owns the live check.
    function _requireNoActivePositionProtection(
        address account
    ) internal view virtual {
        account;
    }

    /// @notice Prunes spent reservation links after authenticating the engine or settlement sidecar.
    /// @param account Account whose full margin queue is synchronized.
    function _syncMarginQueue(
        address account
    ) internal {
        _onlyEngine();
        _pruneMarginQueue(account);
    }

    /// @notice Builds the accounting view stored for an order id and returns its live account-queue successor.
    /// @dev Terminal records are deleted. An unknown or terminal id returns a zero-valued view except
    ///      `pending.orderId == orderId`; permanent terminal identity and outcomes live in the lifecycle book.
    /// @param orderId Order id to inspect.
    /// @return pending Pending core data plus current clearinghouse margin and router bounty reservation.
    /// @return nextAccountOrderId Next live order for the same account, or zero.
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
