// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title AccountLensViewTypes
/// @notice Shared return types for the detailed CFD account lens.
library AccountLensViewTypes {

    /// @notice Compact view of an account's clearinghouse custody, router reservations, and trader claims.
    /// @dev All monetary fields are USDC amounts with 6 decimals.
    /// @param settlementBalanceUsdc Total clearinghouse settlement balance, including encumbered settlement.
    /// @param freeSettlementUsdc Settlement balance not assigned to a typed locked-margin bucket.
    /// @param activePositionMarginUsdc Locked margin backing the account's live position.
    /// @param otherLockedMarginUsdc Locked committed-order and reserved-settlement margin.
    /// @param executionBountyReserveUsdc Clearinghouse-custodied settlement attributed to router execution bounties.
    /// @param committedMarginUsdc Margin committed through the router to pending open or increase orders.
    /// @param traderClaimBalanceUsdc Unpaid trader value recorded as a protocol claim.
    /// @param pendingOrderCount Number of orders currently linked in the account's pending router queue.
    struct AccountLedgerView {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 executionBountyReserveUsdc;
        uint256 committedMarginUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 pendingOrderCount;
    }

    /// @notice Full account snapshot combining custody buckets, router reservations, and live-position risk.
    /// @dev USDC-denominated fields use 6 decimals, `size` uses 18 decimals, and `entryPrice` uses 8 decimals.
    ///      Position-risk fields are zeroed when `hasPosition` is false.
    /// @param settlementBalanceUsdc Total clearinghouse settlement balance, including encumbered settlement.
    /// @param freeSettlementUsdc Settlement balance not assigned to a typed locked-margin bucket.
    /// @param activePositionMarginUsdc Locked margin backing the account's live position.
    /// @param otherLockedMarginUsdc Locked committed-order and reserved-settlement margin.
    /// @param positionMarginBucketUsdc Canonical clearinghouse position-margin bucket.
    /// @param committedOrderMarginBucketUsdc Canonical clearinghouse pending-order margin bucket.
    /// @param reservedSettlementBucketUsdc Canonical clearinghouse reserved-settlement bucket.
    /// @param executionBountyReserveUsdc Clearinghouse-custodied settlement attributed to router execution bounties.
    /// @param committedMarginUsdc Margin committed through the router to pending open or increase orders.
    /// @param traderClaimBalanceUsdc Unpaid trader value recorded as a protocol claim.
    /// @param pendingOrderCount Number of orders currently linked in the account's pending router queue.
    /// @param closeReachableUsdc Legacy close view equal to free settlement, not a complete close-settlement bound.
    /// @param terminalReachableUsdc Total settlement less execution-bounty reservations, floored at zero; includes
    ///        locked value terminal close or liquidation paths may unlock and excludes trader claims.
    /// @param accountEquityUsdc Raw clearinghouse settlement equity before live PnL and carry.
    /// @param freeBuyingPowerUsdc Raw clearinghouse equity less all typed locked-margin buckets, floored at zero.
    /// @param hasPosition Whether the account currently has a nonzero position.
    /// @param side Direction of the live position.
    /// @param size Live position size, with 18 decimals.
    /// @param margin Canonical position-margin bucket backing the live position.
    /// @param entryPrice Average position entry price, with 8 decimals.
    /// @param unrealizedPnlUsdc Mark-to-market PnL at the cached engine mark, excluding pending carry and VPI.
    /// @param netEquityUsdc Terminal-reachable collateral plus unrealized PnL, less pending carry and negative
    ///        accumulated VPI; excludes trader claims.
    /// @param liquidatable Whether net equity is at or below FAD margin in FAD, or maintenance margin otherwise;
    ///        this cached-mark diagnostic does not validate mark freshness.
    struct AccountLedgerSnapshot {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 positionMarginBucketUsdc;
        uint256 committedOrderMarginBucketUsdc;
        uint256 reservedSettlementBucketUsdc;
        uint256 executionBountyReserveUsdc;
        uint256 committedMarginUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 pendingOrderCount;
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        bool hasPosition;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        int256 unrealizedPnlUsdc;
        int256 netEquityUsdc;
        bool liquidatable;
    }

}
