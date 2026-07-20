// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderCommitHandler
/// @notice Creates delayed orders, reserves their clearinghouse balances, and exposes order-record views.
abstract contract OrderCommitHandler is OrderValidation {

    /// @notice Maximum live pending orders allowed per account.
    uint256 public maxPendingOrders = 5;

    /// @notice Validates, reserves, records, and links a caller's delayed order.
    /// @dev The caller is the canonical account. The order id is assigned before external reservation calls,
    ///      but any revert rolls the increment back. Orders are appended to the global and account queues; only
    ///      opens with nonzero margin enter the margin queue. Reverts if the post-increment account count exceeds
    ///      `maxPendingOrders` and emits `OrderCommitted` on success.
    /// @param side Requested open direction or direction of the queued position being closed.
    /// @param sizeDelta Position-size change (18 decimals).
    /// @param marginDelta Open committed margin (6-decimal USDC), required to be zero for closes.
    /// @param targetPrice Direction-aware execution limit (8 decimals), or zero for no limit.
    /// @param isClose Whether this is a strict position reduction.
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

        address account = msg.sender;
        uint256 executionBountyUsdc = isClose
            ? _validatedCloseExecutionBountyUsdc(account, side, sizeDelta)
            : _validatedOpenExecutionBountyUsdc(account, side, sizeDelta, marginDelta);

        uint64 orderId = nextCommitId++;

        _reserveExecutionBounty(account, orderId, sizeDelta, executionBountyUsdc, isClose);
        _reserveCommittedMargin(account, orderId, isClose, marginDelta);

        OrderRecord storage record = orderRecords[orderId];
        record.core = CfdTypes.Order({
            account: account,
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
            pendingCloseSize[account] += sizeDelta;
        }
        _linkGlobalOrder(orderId);
        _linkAccountOrder(account, orderId);
        if (++pendingOrderCounts[account] > maxPendingOrders) {
            revert OrderRouter__TooManyPendingOrders();
        }
        emit OrderCommitted(orderId, account, side);
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
    /// @dev Does not inspect `record.status`: terminal records retain core fields but have zeroed live links and
    ///      consumed reservations; an unknown id returns a zero-valued view except `pending.orderId == orderId`.
    /// @param orderId Order id to inspect.
    /// @return pending Retained core data plus current clearinghouse margin and router bounty reservation.
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
