// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Shared accounting-facing subset of OrderRouter used by engine views and margin bookkeeping.
/// @dev This remains an internal/admin integration surface.
///      Product-facing consumers should prefer `IPerpsTraderViews` via `PerpsPublicLens` and
///      avoid depending on queue-accounting internals directly.
interface IOrderRouterAccounting {

    /// @notice Lifecycle status retained for a committed router order.
    enum OrderStatus {
        /// @notice No order was assigned to the id.
        None,
        /// @notice The order is live in the delayed FIFO queue.
        Pending,
        /// @notice Engine execution succeeded and the order is terminal.
        Executed,
        /// @notice The order became terminal through expiry, slippage, execution rejection, or liquidation cleanup.
        Failed
    }

    /// @notice Router/accounting view of queued order reservations attributed to an account.
    /// @dev `committedMarginUsdc` is derived from canonical MarginClearinghouse reservation state.
    ///      `executionBountyUsdc` is the router-attributed sum of clearinghouse-custodied bounties; the router holds
    ///      no settlement cash itself. Monetary fields use 6-decimal USDC.
    /// @param committedMarginUsdc Remaining committed margin across active clearinghouse reservations.
    /// @param executionBountyUsdc Unpaid execution bounties attributed to linked pending orders.
    /// @param pendingOrderCount Number of linked pending orders for the account.
    struct AccountReservationView {
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        uint256 pendingOrderCount;
    }

    /// @notice User-facing metadata and live reservation amounts for one retained router order record.
    /// @param orderId Router order identifier.
    /// @param isClose Whether the order strictly reduces queued position exposure.
    /// @param side Direction to open/increase or direction of the queued position being closed.
    /// @param sizeDelta Position-size change with 18 decimals.
    /// @param marginDelta Original order-supplied margin in USDC; close orders require zero.
    /// @param targetPrice Direction-aware execution limit with 8 decimals, or zero for no limit.
    /// @param commitTime Submission timestamp in Unix seconds.
    /// @param commitBlock Submission block number.
    /// @param committedMarginUsdc Current remaining clearinghouse reservation for the order, in USDC.
    /// @param executionBountyUsdc Current unpaid clearinghouse-custodied keeper bounty, in USDC.
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
    /// @dev Callable only by the engine or its current settlement sidecar. Mutates router linkage only; the
    ///      clearinghouse remains canonical for reservation value.
    /// @param account Account whose margin reservation queue should be synchronized
    function syncMarginQueue(
        address account
    ) external;

    /// @notice Returns aggregate queued reservation attributed to an account across all pending orders.
    /// @dev Traverses the account queue for bounty and count, while committed margin comes from the clearinghouse.
    /// @param account Account to inspect
    /// @return reservation Pending count plus clearinghouse-custodied committed-margin and bounty totals
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
    /// @dev Core order fields are retained and can remain populated after terminal execution. The reservation values
    ///      and next link reflect current state; traverse from `accountHeadOrderId` when pending-only data is required.
    ///      An unknown id returns zero-valued fields except that `pending.orderId` echoes the requested id.
    /// @param orderId Order id to inspect
    /// @return pending Retained order metadata plus current clearinghouse margin and bounty reservation
    /// @return nextAccountOrderId Next live order id in the account queue, or zero at the tail
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (PendingOrderView memory pending, uint64 nextAccountOrderId);

    /// @notice Returns the number of pending orders currently attributed to an account.
    /// @param account Account to inspect
    /// @return Number of linked live orders
    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    /// @notice Returns the current router-maintained margin-queue order ids for an account in FIFO order.
    /// @dev This is a structural traversal helper and can include links whose clearinghouse reservation reached zero
    ///      but has not yet been pruned. It does not report value; the clearinghouse reservation ledger remains canonical.
    /// @param account Account to inspect
    /// @return orderIds Pending order ids linked into the account's margin reservation queue
    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory orderIds);

}
