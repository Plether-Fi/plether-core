// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Keeper-facing execution and liquidation surface for the simplified product API.
interface IPerpsKeeper {

    /// @notice Permissionlessly executes an eligible delayed order using router-validated oracle data.
    /// @dev May first terminally prune expired queue heads below or equal to the requested bound, subject to the prune
    ///      cap. The target must then be the global head. Expiry, slippage, and engine failures other than
    ///      `CfdEngine__MarkPriceOutOfOrder` terminally fail an order and pay its reserved USDC bounty to the caller; that
    ///      mark-ordering error is rethrown and leaves the order pending. MEV timing, close-only, and gas gates can also
    ///      leave it pending. The router refunds aggregate unused ETH; a failed refund becomes an admin-held claim.
    /// @param orderId Queue-head id to execute, or a later committed id used as the expired-head pruning bound
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover all Pyth fees used by the call
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Permissionlessly processes consecutive eligible FIFO orders through an inclusive committed id bound.
    /// @dev Uses post-commit historical Pyth baskets outside frozen-oracle mode and can reuse a proven compatible tick.
    ///      Terminal failures are cleaned up and pay bounties; the batch stops without consuming the blocked order at a
    ///      close-only open, MEV boundary, insufficient gas, prune cap, or unavailable historical data after progress.
    ///      `CfdEngine__MarkPriceOutOfOrder` reverts the batch nonterminally. The router refunds aggregate unused ETH;
    ///      a failed refund becomes an admin-held deferred claim.
    /// @param maxOrderId Last committed order id the batch may process; must be at or after the current head and below
    ///        the next unassigned commit id
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover cumulative Pyth fees used by the batch
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Liquidates an unsafe account using fresh oracle data.
    /// @dev Permissionless and available while paused. Uses an account-adverse price. On success it forfeits every
    ///      queued execution bounty on the account, fails and unlinks all queued orders, releases committed margin, and
    ///      credits the engine-planned liquidation bounty to the caller's clearinghouse account. The oracle refunds ETH
    ///      above the Pyth fee to the caller or defers it as a caller-claimable balance if transfer fails.
    /// @param account Canonical account whose live position is tested and liquidated
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable;

}
