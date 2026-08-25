// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Keeper-facing order, liquidation, and LP epoch settlement surface for the simplified product API.
interface IPerpsKeeper {

    /// @notice Permissionlessly executes an eligible delayed order using router-validated oracle data.
    /// @dev Before oracle work, refunds cutoff-invalid open heads and then prunes expired heads below or equal to the
    ///      requested bound. Risk-off refunds return all remaining margin and bounty to the trader, pay no caller reward,
    ///      and are capped at 64 per call; cleanup progress may return without executing the target. The target must
    ///      otherwise be the global head. Expiry, slippage, and engine failures other than
    ///      `CfdEngine__MarkPriceOutOfOrder` terminally fail an order and pay its reserved USDC bounty to the caller; that
    ///      mark-ordering error is rethrown and leaves the order pending. MEV timing, close-only, and gas gates can also
    ///      leave it pending. The router refunds aggregate unused ETH; a failed refund becomes an admin-held claim.
    /// @param orderId Queue-head id to execute, or a later committed id used as the terminal-head cleanup bound
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover all Pyth fees used by the call
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Permissionlessly processes consecutive eligible FIFO orders through an inclusive committed id bound.
    /// @dev Before oracle work, refunds cutoff-invalid opens before expiry. It processes at most 64 risk-off refunds;
    ///      after the 64th it may continue with a non-risk-off head, while a 65th eligible refund stops the call. Each
    ///      refund returns all remaining margin and bounty to the trader and pays no caller reward. The batch otherwise
    ///      uses post-commit historical Pyth baskets outside frozen-oracle mode and can reuse a proven compatible tick.
    ///      Ordinary terminal failures are cleaned up and pay bounties; the batch stops without consuming the blocked
    ///      order at a close-only open, MEV boundary, insufficient gas, either cleanup cap, or unavailable historical
    ///      data after progress. `CfdEngine__MarkPriceOutOfOrder` reverts the batch nonterminally. The router refunds
    ///      aggregate unused ETH; a failed refund becomes an admin-held deferred claim.
    /// @param maxOrderId Last committed order id the batch may process; must be at or after the current head and below
    ///        the next unassigned commit id
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover cumulative Pyth fees used by the batch
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Permissionlessly refunds one pending open invalidated by the persistent risk-off cutoff.
    /// @dev This oracle-independent path accepts no ETH, may remove a non-head order, refunds all remaining margin and
    ///      bounty to the submitting account's free internal settlement, and pays no cleaner reward.
    /// @param orderId Pending pre-cutoff open to refund and terminally fail.
    function clearRiskOffOrder(
        uint64 orderId
    ) external;

    /// @notice Atomically refreshes the pool-accounting mark and settles matured LP epochs against that exact mark.
    /// @dev Permissionless and available while the router admin is paused. The router forwards exactly the quoted Pyth
    ///      fee, installs the validated neutral mark in the engine, invokes the Router-bound HousePool settlement path,
    ///      and then refunds unused ETH. Any failure rolls back the oracle update, mark update, and LP settlement.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function settleLpEpoch(
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Liquidates an unsafe account using fresh oracle data.
    /// @dev Permissionless and available while paused. Uses an account-adverse price. Cutoff-invalid opens are refunded
    ///      before the solvency check; on liquidation, only the remaining live execution bounties are forfeited. Every
    ///      queued order is then failed and unlinked, committed margin is released, and the engine-planned liquidation
    ///      bounty is credited to the caller's clearinghouse account. The oracle refunds ETH above the Pyth fee to the
    ///      caller or defers it as a caller-claimable balance if transfer fails.
    /// @param account Canonical account whose live position is tested and liquidated
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Attempts up to 256 account liquidations using one shared Pyth update and neutral mark refresh.
    /// @dev Each account executes in an independent rollback frame. No-position and solvent accounts are skipped, while
    ///      unexpected account-local failures are reported without reverting earlier successes. The original caller
    ///      receives each successful engine-planned bounty. Low gas or an empty item revert leaves the returned index
    ///      unattempted. The limit bounds candidates rather than guaranteed executions in one transaction; resume by
    ///      submitting the suffix at `nextIndex` with a fresh Pyth update.
    /// @param accounts Candidate accounts, in keeper-selected processing order.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` funds one shared update.
    /// @return nextIndex First unattempted account index, or `accounts.length` when every account was attempted.
    function executeLiquidationBatch(
        address[] calldata accounts,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 nextIndex);

}
