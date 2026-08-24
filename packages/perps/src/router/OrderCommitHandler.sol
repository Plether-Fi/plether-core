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

    /// @notice Account-explicit commit primitive used by the router-bound position-protection book.
    /// @dev The public path always passes `msg.sender`; the protected-open host path authenticates the book separately.
    function _commitOrderFor(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) internal returns (uint64 orderId) {
        _requireNoActivePositionProtection(account);
        if (!isClose) {
            _validateOpenCommitAllowed();
        }
        _validateBaseCommit(sizeDelta, marginDelta, isClose);

        uint256 executionBountyUsdc = isClose
            ? _validatedCloseExecutionBountyUsdc(account, side, sizeDelta)
            : _validatedOpenExecutionBountyUsdc(account, side, sizeDelta, marginDelta);

        orderId = nextCommitId++;

        _reserveExecutionBounty(account, sizeDelta, executionBountyUsdc, isClose);
        _reserveCommittedMargin(account, orderId, isClose, marginDelta);

        _recordCommittedOrder(orderId, account, side, sizeDelta, marginDelta, targetPrice, isClose, executionBountyUsdc);
    }

    /// @notice Stores and links an already-validated order whose reservations have already been established.
    /// @dev Position-protection triggering reuses this primitive with a bounty transferred from the external book.
    function _recordCommittedOrder(
        uint64 orderId,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose,
        uint256 executionBountyUsdc
    ) internal {
        OrderRecord storage record = orderRecords[orderId];
        CfdTypes.Order storage order = record.core;
        order.account = account;
        order.sizeDelta = sizeDelta;
        order.marginDelta = marginDelta;
        order.targetPrice = targetPrice;
        order.commitTime = uint64(block.timestamp);
        order.commitBlock = uint64(block.number);
        order.orderId = orderId;
        order.side = side;
        order.isClose = isClose;
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        record.executionBountyUsdc = executionBountyUsdc;
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

    /// @notice Rejects discretionary order commits while a derived protection feature owns the account trade lock.
    /// @dev The base router has no such lock. Position-protection handling overrides this hook.
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
