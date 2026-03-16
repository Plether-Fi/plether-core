// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Shared accounting-facing subset of OrderRouter used by engine views and margin bookkeeping.
interface IOrderRouterAccounting {

    /// @notice Router-custodied order escrow attributed to an account.
    /// @dev `committedMarginUsdc` remains trader-owned but temporarily reserved inside MarginClearinghouse.
    ///      `executionBountyUsdc` is router-custodied bounty escrow reserved for queued orders.
    struct AccountEscrowView {
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        uint256 pendingOrderCount;
    }

    /// @notice Prunes any zero-remaining committed-order reservations out of the router's margin queue for an account.
    function syncMarginQueue(
        bytes32 accountId
    ) external;

    /// @notice Returns aggregate queued escrow attributed to an account across all pending orders.
    function getAccountEscrow(
        bytes32 accountId
    ) external view returns (AccountEscrowView memory escrow);

    /// @notice Returns the number of pending orders currently attributed to an account.
    function pendingOrderCounts(
        bytes32 accountId
    ) external view returns (uint256);
}
