// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../CfdTypes.sol";

/// @notice Shared accounting-facing subset of OrderRouter used by engine views and margin bookkeeping.
/// @dev This remains an internal/admin integration surface.
///      Product-facing consumers should prefer `IPerpsTraderViews` via `PerpsPublicLens` and
///      avoid depending on queue-accounting internals directly.
interface IOrderRouterAccounting {

    enum OrderStatus {
        None,
        Pending,
        Executed,
        Failed
    }

    /// @notice Router/accounting view of queued order reservations attributed to an account.
    /// @dev `committedMarginUsdc` is derived from canonical MarginClearinghouse reservation state.
    ///      `executionBountyUsdc` is clearinghouse-reserved bounty reservation for queued orders.
    struct AccountReservationView {
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        uint256 pendingOrderCount;
    }

    struct PendingOrderView {
        uint64 orderId;
        bool isClose;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        uint64 commitTime;
        uint64 commitBlock;
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
    }

    /// @notice Prunes any zero-remaining committed-order reservations out of the router's margin queue for an account.
    /// @param account Account whose margin reservation queue should be synchronized
    function syncMarginQueue(
        address account
    ) external;

    /// @notice Returns aggregate queued reservation attributed to an account across all pending orders.
    /// @param account Account to inspect
    /// @return reservation Pending-order count plus committed-margin and bounty reservation totals
    function getAccountReservations(
        address account
    ) external view returns (AccountReservationView memory reservation);

    /// @notice Returns the current account-queue head id for pending-order traversal.
    /// @param account Account to inspect
    /// @return headOrderId First pending order id for the account, or zero if none
    function accountHeadOrderId(
        address account
    ) external view returns (uint64 headOrderId);

    /// @notice Returns the pending-order view for a specific order plus the next account-queue order id.
    /// @param orderId Order id to inspect
    /// @return pending Pending order data, or an empty view when the order is not pending
    /// @return nextAccountOrderId Next order id in the account queue, or zero at the tail
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (PendingOrderView memory pending, uint64 nextAccountOrderId);

    /// @notice Returns the number of pending orders currently attributed to an account.
    /// @param account Account to inspect
    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    /// @notice Returns the current router-maintained margin-queue order ids for an account in FIFO order.
    /// @dev This is a structural traversal helper; committed-margin value remains owned by the clearinghouse reservation ledger.
    /// @param account Account to inspect
    /// @return orderIds Pending order ids linked into the account's margin reservation queue
    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory orderIds);

}
