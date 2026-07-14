// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";

library HousePoolReconcilePlanLib {

    struct ReconcilePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
        bool markFresh;
        bool juniorSupplyZero;
        bool claimedEquityZero;
        bool revenue;
        uint256 deltaUsdc;
        uint256 juniorPrincipalBeforeRevenue;
    }

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
