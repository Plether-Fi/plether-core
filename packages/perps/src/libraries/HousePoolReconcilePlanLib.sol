// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";

/// @title HousePoolReconcilePlanLib
/// @notice Plans coupon checkpointing and mark-dependent reconciliation of HousePool claimant principal.
/// @dev All monetary fields use 6-decimal USDC, rates use a 10,000 basis-point denominator, and elapsed time is in
///      seconds. The library mutates only memory and leaves storage application and pending-bucket settlement to callers.
library HousePoolReconcilePlanLib {

    /// @notice Complete memory result of one HousePool reconciliation preview.
    /// @param state Waterfall, unassigned assets, and share supplies after planned accounting.
    /// @param markFresh Whether the caller authorized mark-dependent repricing.
    /// @param juniorSupplyZero Whether junior share supply was zero at planning time.
    /// @param claimedEquityZero Whether senior plus junior principal was zero after coupon processing.
    /// @param revenue Whether reconciliation found distributable value above claimed principal.
    /// @param deltaUsdc Magnitude of revenue or loss; zero for equality, stale-mark early return, or seeded bootstrap.
    /// @param juniorPrincipalBeforeRevenue Junior principal immediately before a revenue delta was distributed.
    struct ReconcilePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
        bool markFresh;
        bool juniorSupplyZero;
        bool claimedEquityZero;
        bool revenue;
        uint256 deltaUsdc;
        uint256 juniorPrincipalBeforeRevenue;
    }

    /// @notice Plans coupon transfer, reservation-aware distributable value, and waterfall revenue or loss.
    /// @dev Coupon processing can occur even when `markFresh` is false, but only when `couponElapsed > 0` and junior
    ///      share supply is nonzero. A stale mark then returns without changing unassigned assets or repricing principal.
    ///      With a fresh mark, settleable pending-bucket assets are reserved first and unassigned assets are capped to
    ///      remaining distributable value. If claimed principal is zero, remaining distributable value is seeded via
    ///      the pending-revenue routing rules. Otherwise the waterfall is reconciled against distributable value net of
    ///      unassigned assets. Subtractions saturate at zero; coupon arithmetic rounds down.
    /// @param state Current waterfall principal, unassigned assets, and senior/junior share supplies.
    /// @param snapshot Current physical-asset, trader-claim, MtM, and distributable accounting snapshot.
    /// @param pendingBucketAssets Settleable pending claimant assets already represented in `snapshot.distributable` and
    ///        therefore reserved from ordinary waterfall reconciliation.
    /// @param seniorRateBps Annualized senior coupon rate in basis points.
    /// @param couponElapsed Seconds since the senior coupon checkpoint.
    /// @param markFresh Whether mark-dependent principal reconciliation may proceed.
    /// @return plan Planned memory state and diagnostic reconciliation flags and deltas.
    function planReconcile(
        HousePoolPendingPreviewLib.PendingAccountingState memory state,
        HousePoolAccountingLib.ReconcileSnapshot memory snapshot,
        uint256 pendingBucketAssets,
        uint256 seniorRateBps,
        uint256 couponElapsed,
        bool markFresh
    ) internal pure returns (ReconcilePlan memory plan) {
        plan.state = state;
        plan.markFresh = markFresh;
        if (couponElapsed > 0 && state.juniorSupply > 0) {
            (plan.state.waterfall,) =
                HousePoolWaterfallAccountingLib.paySeniorCoupon(plan.state.waterfall, seniorRateBps, couponElapsed);
        }
        plan.juniorSupplyZero = plan.state.juniorSupply == 0;
        plan.claimedEquityZero = plan.state.waterfall.seniorPrincipal + plan.state.waterfall.juniorPrincipal == 0;

        if (!markFresh) {
            return plan;
        }

        if (pendingBucketAssets > 0) {
            snapshot.distributable =
                snapshot.distributable > pendingBucketAssets ? snapshot.distributable - pendingBucketAssets : 0;
        }

        plan.state.unassignedAssets =
            state.unassignedAssets > snapshot.distributable ? snapshot.distributable : state.unassignedAssets;

        if (plan.claimedEquityZero) {
            uint256 seededDistributableToClaims = snapshot.distributable > plan.state.unassignedAssets
                ? snapshot.distributable - plan.state.unassignedAssets
                : 0;
            HousePoolPendingPreviewLib.applyRevenueIntent(plan.state, seededDistributableToClaims);
            return plan;
        }

        uint256 distributableToClaims = snapshot.distributable > plan.state.unassignedAssets
            ? snapshot.distributable - plan.state.unassignedAssets
            : 0;
        HousePoolWaterfallAccountingLib.ReconcilePlan memory waterfallPlan =
            HousePoolWaterfallAccountingLib.planReconcile(
                plan.state.waterfall.seniorPrincipal, plan.state.waterfall.juniorPrincipal, distributableToClaims
            );

        plan.revenue = waterfallPlan.isRevenue;
        plan.deltaUsdc = waterfallPlan.deltaUsdc;

        if (plan.revenue) {
            plan.juniorPrincipalBeforeRevenue = plan.state.waterfall.juniorPrincipal;
            plan.state.waterfall =
                HousePoolWaterfallAccountingLib.distributeRevenue(plan.state.waterfall, plan.deltaUsdc);
            return plan;
        }

        if (plan.deltaUsdc > 0) {
            plan.state.waterfall = HousePoolWaterfallAccountingLib.absorbLoss(plan.state.waterfall, plan.deltaUsdc);
            return plan;
        }
    }

    /// @notice Computes revenue temporarily assigned to junior principal despite having no junior owners.
    /// @dev Returns nonzero only for a revenue plan whose captured junior supply was zero. The caller can move this
    ///      amount from junior principal to unassigned assets. Saturating subtraction protects malformed input plans.
    /// @param plan Completed reconciliation plan.
    /// @return Revenue increase in junior principal that has no corresponding junior share owners.
    function juniorRevenueWithoutOwners(
        ReconcilePlan memory plan
    ) internal pure returns (uint256) {
        if (!plan.revenue || !plan.juniorSupplyZero) {
            return 0;
        }

        return plan.state.waterfall.juniorPrincipal > plan.juniorPrincipalBeforeRevenue
            ? plan.state.waterfall.juniorPrincipal - plan.juniorPrincipalBeforeRevenue
            : 0;
    }

}
