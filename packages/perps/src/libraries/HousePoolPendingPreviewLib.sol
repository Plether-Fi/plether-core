// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";

/// @title HousePoolPendingPreviewLib
/// @notice Applies pending recapitalization and trading-revenue buckets to an in-memory HousePool waterfall preview.
/// @dev All monetary values use 6-decimal USDC. State-taking helpers mutate the supplied memory object in place and
///      do not move tokens or update storage. Recapitalization is always processed before revenue. Additions use
///      Solidity's checked arithmetic; component subtraction explicitly saturates where documented.
library HousePoolPendingPreviewLib {

    /// @notice Outstanding claimant inflows separated by their waterfall intent.
    /// @param recapitalizationUsdc Assets intended to restore senior principal, then remain unassigned.
    /// @param revenueUsdc Trading revenue intended to restore senior impairment, then accrue to junior owners.
    struct ClaimantPendingBuckets {
        uint256 recapitalizationUsdc;
        uint256 revenueUsdc;
    }

    /// @notice In-memory waterfall and ownership state used for pending-inflow previews.
    /// @param waterfall Current senior principal, junior principal, and senior high-water mark.
    /// @param unassignedAssets Assets not represented by a senior or junior principal claim.
    /// @param seniorSupply Current senior share supply; only zero versus nonzero is used.
    /// @param juniorSupply Current junior share supply; only zero versus nonzero is used.
    struct PendingAccountingState {
        HousePoolWaterfallAccountingLib.WaterfallState waterfall;
        uint256 unassignedAssets;
        uint256 seniorSupply;
        uint256 juniorSupply;
    }

    /// @notice Applies pending buckets using those same buckets as the full claimant intent.
    /// @dev Equivalent to the three-argument overload with `claimantIntentBuckets == claimantBuckets` and with
    ///      revenue continuation disabled. Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param claimantBuckets Settleable recapitalization and revenue amounts to apply.
    function applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        ClaimantPendingBuckets memory claimantBuckets
    ) internal pure {
        applyPendingClaimantBucketsPreview(state, claimantBuckets, claimantBuckets);
    }

    /// @notice Applies settleable pending buckets while preserving a separate full recapitalization target.
    /// @dev Revenue continuation is disabled: if principal is already claimed after recapitalization, revenue becomes
    ///      unassigned. Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param claimantBuckets Settleable recapitalization and revenue amounts to apply.
    /// @param claimantIntentBuckets Full outstanding intent; only `recapitalizationUsdc` is used as the bootstrap
    ///        senior high-water-mark target.
    function applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        ClaimantPendingBuckets memory claimantBuckets,
        ClaimantPendingBuckets memory claimantIntentBuckets
    ) internal pure {
        applyPendingClaimantBucketsPreview(state, claimantBuckets, claimantIntentBuckets, false);
    }

    /// @notice Applies settleable recapitalization first and settleable revenue second to a memory preview.
    /// @dev Zero buckets are skipped. `claimantIntentBuckets.revenueUsdc` is intentionally unused. Mutates `state` in
    ///      place; it does not decrement either input bucket.
    /// @param state In-memory accounting state to update.
    /// @param claimantBuckets Settleable recapitalization and revenue amounts to apply.
    /// @param claimantIntentBuckets Full outstanding intent used to establish the recapitalization bootstrap target.
    /// @param allowRevenueContinuation Whether revenue may be routed into already-claimed waterfall equity.
    function applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        ClaimantPendingBuckets memory claimantBuckets,
        ClaimantPendingBuckets memory claimantIntentBuckets,
        bool allowRevenueContinuation
    ) internal pure {
        if (claimantBuckets.recapitalizationUsdc > 0) {
            applyClaimantRecapitalizationIntent(
                state, claimantBuckets.recapitalizationUsdc, claimantIntentBuckets.recapitalizationUsdc
            );
        }
        if (claimantBuckets.revenueUsdc > 0) {
            applyRevenueIntent(state, claimantBuckets.revenueUsdc, allowRevenueContinuation);
        }
    }

    /// @notice Sums recapitalization and revenue assets in a claimant bucket.
    /// @param claimantBuckets Buckets to total.
    /// @return Total pending assets in 6-decimal USDC.
    function claimantBucketAssets(
        ClaimantPendingBuckets memory claimantBuckets
    ) internal pure returns (uint256) {
        return claimantBuckets.recapitalizationUsdc + claimantBuckets.revenueUsdc;
    }

    /// @notice Caps pending assets to a maximum with recapitalization taking priority over revenue.
    /// @param claimantBuckets Requested pending buckets.
    /// @param maxAssets Maximum combined assets that may be returned.
    /// @return cappedBuckets Prefix of the requested buckets whose sum is at most `maxAssets`.
    function capClaimantBuckets(
        ClaimantPendingBuckets memory claimantBuckets,
        uint256 maxAssets
    ) internal pure returns (ClaimantPendingBuckets memory cappedBuckets) {
        uint256 remaining = maxAssets;
        cappedBuckets.recapitalizationUsdc =
            claimantBuckets.recapitalizationUsdc > remaining ? remaining : claimantBuckets.recapitalizationUsdc;
        remaining -= cappedBuckets.recapitalizationUsdc;
        cappedBuckets.revenueUsdc = claimantBuckets.revenueUsdc > remaining ? remaining : claimantBuckets.revenueUsdc;
    }

    /// @notice Subtracts independently settled pending buckets using saturating subtraction.
    /// @dev If a settled component exceeds its corresponding claimant component, that residual component is zero;
    ///      excess from one component is not applied to the other.
    /// @param claimantBuckets Outstanding buckets before settlement.
    /// @param settledBuckets Component-wise amounts treated as settled.
    /// @return residualBuckets Outstanding component balances after saturating subtraction.
    function subtractClaimantBuckets(
        ClaimantPendingBuckets memory claimantBuckets,
        ClaimantPendingBuckets memory settledBuckets
    ) internal pure returns (ClaimantPendingBuckets memory residualBuckets) {
        residualBuckets.recapitalizationUsdc = claimantBuckets.recapitalizationUsdc
            > settledBuckets.recapitalizationUsdc
            ? claimantBuckets.recapitalizationUsdc - settledBuckets.recapitalizationUsdc
            : 0;
        residualBuckets.revenueUsdc = claimantBuckets.revenueUsdc > settledBuckets.revenueUsdc
            ? claimantBuckets.revenueUsdc - settledBuckets.revenueUsdc
            : 0;
    }

    /// @notice Applies recapitalization using the amount itself as the bootstrap high-water-mark target.
    /// @dev Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param amount Recapitalization assets to apply, in 6-decimal USDC.
    function applyClaimantRecapitalizationIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        applyClaimantRecapitalizationIntent(state, amount, amount);
    }

    /// @notice Routes recapitalization to senior restoration or to unassigned assets.
    /// @dev With senior owners and zero claimed principal, all `amount` bootstraps senior principal and sets the
    ///      high-water mark to `max(recapitalizationTargetUsdc, amount)`. Otherwise, senior principal is restored only
    ///      up to its high-water mark. Any remainder, including all value when there are no senior owners, becomes
    ///      unassigned; recapitalization never accrues to junior principal. Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param amount Settleable recapitalization assets to apply.
    /// @param recapitalizationTargetUsdc Full recapitalization intent used as the high-water mark on an empty bootstrap.
    function applyClaimantRecapitalizationIntent(
        PendingAccountingState memory state,
        uint256 amount,
        uint256 recapitalizationTargetUsdc
    ) internal pure {
        uint256 remaining = amount;
        if (state.seniorSupply > 0) {
            if (state.waterfall.seniorPrincipal == 0 && state.waterfall.juniorPrincipal == 0) {
                state.waterfall.seniorPrincipal += remaining;
                state.waterfall.seniorHighWaterMark =
                    recapitalizationTargetUsdc > remaining ? recapitalizationTargetUsdc : remaining;
                remaining = 0;
            } else {
                uint256 gap = state.waterfall.seniorHighWaterMark > state.waterfall.seniorPrincipal
                    ? state.waterfall.seniorHighWaterMark - state.waterfall.seniorPrincipal
                    : 0;
                if (gap > 0) {
                    uint256 seniorAssignedUsdc = remaining > gap ? gap : remaining;
                    state.waterfall.seniorPrincipal += seniorAssignedUsdc;
                    remaining -= seniorAssignedUsdc;
                }
            }
        }
        if (remaining > 0) {
            state.unassignedAssets += remaining;
        }
    }

    /// @notice Applies revenue with continuation into already-claimed equity disabled.
    /// @dev Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param amount Revenue assets to apply, in 6-decimal USDC.
    function applyRevenueIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        applyRevenueIntent(state, amount, false);
    }

    /// @notice Routes revenue through senior restoration, junior principal, and unassigned assets.
    /// @dev Unless `allowClaimedEquity` is true, any nonzero claimed principal causes the entire amount to become
    ///      unassigned. Otherwise revenue first restores senior principal up to its high-water mark when senior owners
    ///      exist, then accrues to junior principal when junior owners exist, and leaves any remainder unassigned.
    ///      Mutates `state` in place.
    /// @param state In-memory accounting state to update.
    /// @param amount Revenue assets to apply, in 6-decimal USDC.
    /// @param allowClaimedEquity Whether revenue may continue into a waterfall that already has claimed principal.
    function applyRevenueIntent(
        PendingAccountingState memory state,
        uint256 amount,
        bool allowClaimedEquity
    ) internal pure {
        if (!allowClaimedEquity && state.waterfall.seniorPrincipal + state.waterfall.juniorPrincipal != 0) {
            state.unassignedAssets += amount;
            return;
        }

        uint256 remaining = amount;
        if (state.seniorSupply > 0) {
            uint256 gap = state.waterfall.seniorHighWaterMark > state.waterfall.seniorPrincipal
                ? state.waterfall.seniorHighWaterMark - state.waterfall.seniorPrincipal
                : 0;
            if (gap > 0) {
                uint256 seniorAssignedUsdc = remaining > gap ? gap : remaining;
                state.waterfall.seniorPrincipal += seniorAssignedUsdc;
                remaining -= seniorAssignedUsdc;
            }
        }

        if (remaining > 0 && state.juniorSupply > 0) {
            state.waterfall.juniorPrincipal += remaining;
            remaining = 0;
        }

        if (remaining > 0) {
            state.unassignedAssets += remaining;
        }
    }

}
