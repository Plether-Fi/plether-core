// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolWaterfallAccountingLib} from "./HousePoolWaterfallAccountingLib.sol";

library HousePoolPendingPreviewLib {

    struct ClaimantPendingBuckets {
        uint256 recapitalizationUsdc;
        uint256 revenueUsdc;
    }

    struct PendingAccountingState {
        HousePoolWaterfallAccountingLib.WaterfallState waterfall;
        uint256 unassignedAssets;
        uint256 seniorSupply;
        uint256 juniorSupply;
    }

    function applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        ClaimantPendingBuckets memory claimantBuckets
    ) internal pure {
        applyPendingClaimantBucketsPreview(state, claimantBuckets, claimantBuckets);
    }

    function applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        ClaimantPendingBuckets memory claimantBuckets,
        ClaimantPendingBuckets memory claimantIntentBuckets
    ) internal pure {
        applyPendingClaimantBucketsPreview(state, claimantBuckets, claimantIntentBuckets, false);
    }

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

    function claimantBucketAssets(
        ClaimantPendingBuckets memory claimantBuckets
    ) internal pure returns (uint256) {
        return claimantBuckets.recapitalizationUsdc + claimantBuckets.revenueUsdc;
    }

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

    function applyClaimantRecapitalizationIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        applyClaimantRecapitalizationIntent(state, amount, amount);
    }

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

    function applyRevenueIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        applyRevenueIntent(state, amount, false);
    }

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
