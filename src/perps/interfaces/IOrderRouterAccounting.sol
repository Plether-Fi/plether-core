// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

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

    /// @notice Router/accounting view of queued order escrow attributed to an account.
    /// @dev `committedMarginUsdc` is derived from canonical MarginClearinghouse reservation state.
    ///      `executionBountyUsdc` is router-custodied bounty escrow reserved for queued orders.
    struct AccountEscrowView {
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
    function syncMarginQueue(
        address account
    ) external;

    /// @notice Returns aggregate queued escrow attributed to an account across all pending orders.
    function getAccountEscrow(
        address account
    ) external view returns (AccountEscrowView memory escrow);

    /// @notice Returns the current account-queue head id for pending-order traversal.
    function accountHeadOrderId(
        address account
    ) external view returns (uint64 headOrderId);

    /// @notice Returns the pending-order view for a specific order plus the next account-queue order id.
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (PendingOrderView memory pending, uint64 nextAccountOrderId);

    /// @notice Returns the number of pending orders currently attributed to an account.
    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    /// @notice Returns the current router-maintained margin-queue order ids for an account in FIFO order.
    /// @dev This is a structural traversal helper; committed-margin value remains owned by the clearinghouse reservation ledger.
    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory orderIds);

}
