// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title AccountLensViewTypes
/// @notice Shared return types for the detailed CFD account lens.
library AccountLensViewTypes {

    /// @notice Compact view of an account's clearinghouse custody, router reservations, and trader claims.
    /// @dev All monetary fields are settlement token amounts with 6 decimals.
    /// @param settlementBalanceAssets Total clearinghouse settlement balance, including encumbered settlement.
    /// @param freeSettlementAssets Settlement balance not assigned to a typed locked-margin bucket.
    /// @param activePositionMarginAssets Locked margin backing the account's live position.
    /// @param otherLockedMarginAssets Locked liquidation-reserve, committed-order, and reserved-settlement margin.
    /// @param executionBountyReserveAssets Clearinghouse-custodied settlement attributed to router execution bounties.
    /// @param committedMarginAssets Margin committed through the router to pending open or increase orders.
    /// @param traderClaimBalanceAssets Unpaid trader value recorded as a protocol claim.
    /// @param pendingOrderCount Number of orders currently linked in the account's pending router queue.
    struct AccountLedgerView {
        uint256 settlementBalanceAssets;
        uint256 freeSettlementAssets;
        uint256 activePositionMarginAssets;
        uint256 otherLockedMarginAssets;
        uint256 executionBountyReserveAssets;
        uint256 committedMarginAssets;
        uint256 traderClaimBalanceAssets;
        uint256 pendingOrderCount;
    }

    /// @notice Full account snapshot combining custody buckets, router reservations, and live-position risk.
    /// @dev settlement token-denominated fields use 6 decimals, `size` uses 18 decimals, and `entryPrice` uses 8 decimals.
    ///      Position-risk fields are zeroed when `hasPosition` is false.
    /// @param settlementBalanceAssets Total clearinghouse settlement balance, including encumbered settlement.
    /// @param freeSettlementAssets Settlement balance not assigned to a typed locked-margin bucket.
    /// @param activePositionMarginAssets Locked margin backing the account's live position.
    /// @param otherLockedMarginAssets Locked liquidation-reserve, committed-order, and reserved-settlement margin.
    /// @param positionMarginBucketAssets Canonical clearinghouse position-margin bucket.
    /// @param committedOrderMarginBucketAssets Canonical clearinghouse pending-order margin bucket.
    /// @param reservedSettlementBucketAssets Canonical clearinghouse reserved-settlement bucket.
    /// @param executionBountyReserveAssets Clearinghouse-custodied settlement attributed to router execution bounties.
    /// @param committedMarginAssets Margin committed through the router to pending open or increase orders.
    /// @param traderClaimBalanceAssets Unpaid trader value recorded as a protocol claim.
    /// @param pendingOrderCount Number of orders currently linked in the account's pending router queue.
    /// @param closeReachableAssets Legacy close view equal to free settlement, not a complete close-settlement bound.
    /// @param liquidationReachableSettlementAssets Total settlement less execution-bounty reservations, floored at zero;
    ///        includes locked value liquidation may release and excludes trader claims.
    /// @param terminalPriceCollectibleCapAssets Live-position terminal price-loss cap: PnL pledge plus same-account
    ///        claim, clipped to maximum endpoint loss; zero without a live position. Close records add no backing.
    /// @param accountEquityAssets Raw clearinghouse settlement equity before live PnL and carry.
    /// @param freeBuyingPowerAssets Raw clearinghouse equity less all typed locked-margin buckets, floored at zero.
    /// @param hasPosition Whether the account currently has a nonzero position.
    /// @param side Direction of the live position.
    /// @param size Live position size, with 18 decimals.
    /// @param margin Canonical position-margin bucket backing the live position.
    /// @param entryPrice Average position entry price, with 8 decimals.
    /// @param unrealizedPnlAssets Mark-to-market PnL at the cached engine mark, excluding pending carry and VPI.
    /// @param netEquityAssets Exact price-risk equity from projected post-carry PnL pledge, same-account claim, and
    ///        unrealized price PnL. VPI, generic settlement, and action reserves are excluded. Carry uncovered by both
    ///        margin and free settlement and an underfunded negative-VPI reserve independently fail health checks.
    /// @param liquidatable Whether exact price risk breaches the active margin requirement, projected carry remains
    ///        uncovered, or the negative-VPI reserve is underfunded. This cached-mark diagnostic does not validate
    ///        mark freshness; the liquidation planner rejects an underfunded VPI reserve before settlement.
    ///        Zero-bounty close records add no liquidation price collateral.
    struct AccountLedgerSnapshot {
        uint256 settlementBalanceAssets;
        uint256 freeSettlementAssets;
        uint256 activePositionMarginAssets;
        uint256 otherLockedMarginAssets;
        uint256 positionMarginBucketAssets;
        uint256 committedOrderMarginBucketAssets;
        uint256 reservedSettlementBucketAssets;
        uint256 executionBountyReserveAssets;
        uint256 committedMarginAssets;
        uint256 traderClaimBalanceAssets;
        uint256 pendingOrderCount;
        uint256 closeReachableAssets;
        uint256 liquidationReachableSettlementAssets;
        uint256 terminalPriceCollectibleCapAssets;
        uint256 accountEquityAssets;
        uint256 freeBuyingPowerAssets;
        bool hasPosition;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        int256 unrealizedPnlAssets;
        int256 netEquityAssets;
        bool liquidatable;
    }

}
