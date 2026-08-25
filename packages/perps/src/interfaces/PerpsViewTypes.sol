// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Canonical public-facing view structs for the simplified perps product surface.
library PerpsViewTypes {

    /// @notice Product-facing order lifecycle status.
    /// @dev `getPendingOrders` currently returns only `Pending`; terminal values are reserved for richer history views.
    enum OrderStatus {
        /// @notice No order exists for the queried identifier.
        None,
        /// @notice The order remains live in the delayed queue awaiting execution or terminal cleanup.
        Pending,
        /// @notice The order executed successfully.
        Executed,
        /// @notice The order reached a terminal failure state.
        Failed
    }

    /// @notice Compact custody, reservation, and risk summary for one trader account.
    /// @dev All monetary fields use USDC's 6 decimals.
    /// @param equityUsdc Cached-mark exact price-risk equity: PnL pledge plus same-account claim plus exact price PnL.
    ///        Carry and VPI are excluded. Uncovered carry or an underfunded negative-VPI reserve independently sets
    ///        `liquidatable` and withdrawal capacity to zero. This field is floored at zero and equals raw settlement
    ///        equity when flat.
    /// @param withdrawableUsdc Same-state withdrawal estimate from the account lens. Uncovered carry or an underfunded
    ///        negative-VPI reserve makes this zero. When price-risk headroom binds, the live guard requires equity to
    ///        remain strictly above the requirement, so the exact quoted boundary may need to be reduced by one atomic
    ///        USDC unit.
    /// @param pendingOrderMarginUsdc Margin committed to pending open or increase orders.
    /// @param pendingExecutionBountyUsdc Clearinghouse-custodied settlement attributed to execution bounties.
    /// @param hasOpenPosition Whether the account currently has a nonzero position.
    /// @param liquidatable Cached-mark diagnostic that is true for an exact price-risk maintenance breach, carry left
    ///        uncovered after projected free-settlement collection, or an underfunded negative-VPI reserve; mark
    ///        freshness is not validated by this view.
    struct TraderAccountView {
        uint256 equityUsdc;
        uint256 withdrawableUsdc;
        uint256 pendingOrderMarginUsdc;
        uint256 pendingExecutionBountyUsdc;
        bool hasOpenPosition;
        bool liquidatable;
    }

    /// @notice Compact current-position summary for one account.
    /// @dev USDC fields use 6 decimals, `size` uses 18 decimals, and `entryPrice` uses 8 decimals.
    /// @param exists Whether the account currently has a nonzero position.
    /// @param side Direction of the live position.
    /// @param size Live position size.
    /// @param entryPrice Average position entry price.
    /// @param marginUsdc Canonical position-margin bucket backing the position.
    /// @param unrealizedPnlUsdc Mark-to-market PnL at the cached engine mark, excluding pending carry and VPI.
    /// @param maintenanceMarginUsdc Margin required at the current mark under the active calendar regime.
    /// @param liquidatable Cached-mark diagnostic that is true for an exact price-risk maintenance breach or any carry
    ///        left uncovered after projected free-settlement collection; mark freshness is not validated by this view.
    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 entryPrice;
        uint256 marginUsdc;
        int256 unrealizedPnlUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    /// @notice Product-facing summary of one queued order.
    /// @dev USDC fields use 6 decimals, `sizeDelta` uses 18 decimals, and `acceptablePrice` uses 8 decimals.
    /// @param orderId Monotonically increasing router order identifier.
    /// @param side Requested position direction.
    /// @param sizeDelta Position size to open, increase, or reduce.
    /// @param marginDeltaUsdc Requested nonnegative margin amount; close orders always report zero.
    /// @param acceptablePrice Router directional target-price boundary; zero disables the slippage check.
    /// @param isReduceOnly Whether the order is a close/reduce order.
    /// @param status Product-facing lifecycle status.
    struct PendingOrderView {
        uint64 orderId;
        CfdTypes.Side side;
        uint256 sizeDelta;
        int256 marginDeltaUsdc;
        uint256 acceptablePrice;
        bool isReduceOnly;
        OrderStatus status;
    }

    /// @notice Compact view of a senior or junior tranche vault.
    /// @param totalAssetsUsdc Assets attributed to the tranche, with 6 decimals.
    /// @param totalShares Outstanding raw ERC4626 share units, using the vault's share decimals.
    /// @param sharePrice Raw `(totalAssetsUsdc * 1e18) / totalShares` quotient, or `1e18` when supply is zero. The
    ///        populated-vault branch does not normalize differing asset and share decimals.
    /// @param maxWithdrawUsdc Pool-wide stored-state tranche cap, with 6 decimals; not holder-specific and not a
    ///        preview of the reconciliation performed by live withdrawal execution.
    /// @param frozenLpFeeBps Active frozen-oracle LP fee in basis points, or zero outside frozen mode.
    /// @param depositEnabled Whether the pool accepts a delayed deposit request for the tranche.
    /// @param withdrawEnabled Whether pool-level withdrawals are currently live.
    /// @param oracleFrozen Whether the engine is in the calendar-defined frozen-oracle regime.
    struct TrancheView {
        uint256 totalAssetsUsdc;
        uint256 totalShares;
        uint256 sharePrice;
        uint256 maxWithdrawUsdc;
        uint256 frozenLpFeeBps;
        bool depositEnabled;
        bool withdrawEnabled;
        bool oracleFrozen;
    }

    /// @notice Synchronized queue heads and runtime gates for one tranche.
    /// @param vault Configured Senior or Junior tranche vault.
    /// @param currentEpoch Current shared HousePool LP epoch.
    /// @param cutoffEpoch Latest epoch eligible for the next settlement call.
    /// @param nextRequestEpoch Epoch currently targeted by new deposit and redemption requests.
    /// @param nextRequestCutoffTime Future Unix timestamp when `nextRequestEpoch` will next roll forward.
    /// @param depositHeadEpoch Oldest matured deposit epoch, or zero when none is visible.
    /// @param depositHeadAssets Assets in the matured deposit head, with 6-decimal USDC units.
    /// @param redeemHeadEpoch Oldest matured redemption epoch, or zero when none is visible.
    /// @param redeemHeadShares Unfunded shares in the matured redemption head.
    /// @param depositBacklog Whether matured deposit work is visible to settlement.
    /// @param redeemBacklog Whether matured redemption work is visible to settlement.
    /// @param settlementLive Whether runtime gates permit new redemption funding.
    /// @param poolPaused Whether HousePool pause currently defers deposit activation.
    /// @param lpEpochSettlementPaused Whether governance has held LP epoch settlement, deferring deposit activation
    ///        and new redemption funding without disabling request admission or already-funded claims.
    struct TrancheQueueView {
        address vault;
        uint256 currentEpoch;
        uint256 cutoffEpoch;
        uint256 nextRequestEpoch;
        uint256 nextRequestCutoffTime;
        uint256 depositHeadEpoch;
        uint256 depositHeadAssets;
        uint256 redeemHeadEpoch;
        uint256 redeemHeadShares;
        bool depositBacklog;
        bool redeemBacklog;
        bool settlementLive;
        bool poolPaused;
        bool lpEpochSettlementPaused;
    }

    /// @notice Controller state for one deposit/redemption request id on one tranche.
    /// @dev Pending estimates are indicative current-price views, while claimable and refundable fields report exact
    ///      request accounting.
    /// @param vault Configured Senior or Junior tranche vault.
    /// @param requestId Shared LP epoch used as the asynchronous request id.
    /// @param controller Account that controls the request.
    /// @param pendingDepositAssets Requested assets that have not become claimable, with 6-decimal USDC units.
    /// @param pendingDepositSharesEstimate Indicative shares for the pending deposit assets at current pricing.
    /// @param claimableDepositAssets Finalized deposit contribution basis available to claim, in USDC units.
    /// @param claimableDepositShares Finalized vault shares available to claim.
    /// @param pendingRedeemShares Requested shares that have not become claimable or refundable.
    /// @param pendingRedeemAssetsEstimate Indicative assets for the pending redemption shares, in USDC units.
    /// @param claimableRedeemShares Funded redemption shares available to claim.
    /// @param claimableRedeemAssets Exact funded USDC available to claim.
    /// @param refundableDepositAssets Rejected deposit assets available to recover through cancellation, in USDC units.
    /// @param refundableRedeemShares Unburned redemption shares available to reclaim from request escrow.
    /// @param redeemRefundPending Whether the controller must acknowledge a terminal redemption refund; this can be
    ///        true even when its pro-rata refundable share amount rounded to zero.
    struct LpRequestStateView {
        address vault;
        uint256 requestId;
        address controller;
        uint256 pendingDepositAssets;
        uint256 pendingDepositSharesEstimate;
        uint256 claimableDepositAssets;
        uint256 claimableDepositShares;
        uint256 pendingRedeemShares;
        uint256 pendingRedeemAssetsEstimate;
        uint256 claimableRedeemShares;
        uint256 claimableRedeemAssets;
        uint256 refundableDepositAssets;
        uint256 refundableRedeemShares;
        bool redeemRefundPending;
    }

    /// @notice High-level LP lifecycle and oracle status.
    /// @param tradingActive Whether the pool has completed bootstrap and activated trading.
    /// @param withdrawalLive Whether degraded-mode and mark-freshness gates permit pool-level withdrawals; this does
    ///        not include vault cooldown, owner-balance, or seed-floor constraints.
    /// @param lastMarkTime Oracle publish timestamp associated with the cached engine mark.
    /// @param oracleFresh Whether the mark satisfies the HousePool's current reconciliation freshness policy.
    /// @param oracleFrozen Whether the engine is in the calendar-defined frozen-oracle regime.
    /// @param lpEpochSettlementPaused Whether governance has held LP epoch settlement.
    struct LpStatusView {
        bool tradingActive;
        bool withdrawalLive;
        uint64 lastMarkTime;
        bool oracleFresh;
        bool oracleFrozen;
        bool lpEpochSettlementPaused;
    }

    /// @notice High-level protocol runtime status.
    /// @param phase Numeric encoding of `ICfdEngine.ProtocolPhase`.
    /// @param lastMarkPrice Cached engine mark price, with 8 decimals.
    /// @param lastMarkTime Oracle publish timestamp associated with the cached mark.
    /// @param oracleFrozen Whether the engine is in the calendar-defined frozen-oracle regime.
    /// @param fadWindow Whether Friday Afternoon Deleverage controls are currently active.
    /// @param tradingActive Whether the pool has completed bootstrap and activated trading.
    /// @param withdrawalLive Whether degraded-mode and mark-freshness gates permit pool-level withdrawals.
    /// @param lpEpochSettlementPaused Whether governance has held LP epoch settlement.
    struct ProtocolStatusView {
        uint8 phase;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool fadWindow;
        bool tradingActive;
        bool withdrawalLive;
        bool lpEpochSettlementPaused;
    }

}
