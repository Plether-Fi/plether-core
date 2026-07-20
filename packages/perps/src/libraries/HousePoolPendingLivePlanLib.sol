// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";

/// @title HousePoolPendingLivePlanLib
/// @notice Wraps preview accounting output as a mutation plan for pending claimant buckets.
library HousePoolPendingLivePlanLib {

    /// @notice Planned post-application pending accounting state.
    /// @param state State after applying claimant buckets and permitted continuation.
    struct PendingLivePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
    }

    /// @notice Plans application of pending claimant value without mutating HousePool storage.
    /// @param state Current pending-accounting state.
    /// @param claimantBuckets Pending recapitalization and revenue balances applied in full.
    /// @param claimantIntentBuckets Intent metadata whose recapitalization field can initialize the senior high-water
    ///        target when claimed equity is zero; its revenue field is not used by the current preview algorithm.
    /// @param allowRevenueContinuation Whether revenue may fill existing senior impairment and then flow to junior;
    ///        when false, revenue encountered with existing claimed principal is quarantined as unassigned assets.
    /// @return plan Post-application state wrapped for the live mutation path.
    function planApplyPendingClaimantBuckets(
        HousePoolPendingPreviewLib.PendingAccountingState memory state,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantIntentBuckets,
        bool allowRevenueContinuation
    ) internal pure returns (PendingLivePlan memory plan) {
        plan.state = state;
        HousePoolPendingPreviewLib.applyPendingClaimantBucketsPreview(
            plan.state, claimantBuckets, claimantIntentBuckets, allowRevenueContinuation
        );
    }

}
