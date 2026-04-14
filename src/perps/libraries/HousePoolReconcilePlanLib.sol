// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolAccountingLib} from "./HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "./HousePoolPendingPreviewLib.sol";
import {HousePoolWaterfallAccountingLib} from "./HousePoolWaterfallAccountingLib.sol";

library HousePoolReconcilePlanLib {

    struct ReconcilePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
        uint256 yieldAccrued;
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
        uint256 yieldElapsed,
        bool markFresh
    ) internal pure returns (ReconcilePlan memory plan) {
        plan.state = state;
        plan.markFresh = markFresh;
        plan.juniorSupplyZero = state.juniorSupply == 0;
        plan.claimedEquityZero = state.waterfall.seniorPrincipal + state.waterfall.juniorPrincipal == 0;

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
                state.waterfall.seniorPrincipal,
                state.waterfall.juniorPrincipal,
                distributableToClaims,
                seniorRateBps,
                yieldElapsed
            );

        plan.yieldAccrued = waterfallPlan.yieldAccrued;
        plan.revenue = waterfallPlan.isRevenue;
        plan.deltaUsdc = waterfallPlan.deltaUsdc;

        if (plan.revenue) {
            plan.juniorPrincipalBeforeRevenue = plan.state.waterfall.juniorPrincipal;
            plan.state.waterfall.unpaidSeniorYield += plan.yieldAccrued;
            plan.state.waterfall =
                HousePoolWaterfallAccountingLib.distributeRevenue(plan.state.waterfall, plan.deltaUsdc);
            return plan;
        }

        if (plan.deltaUsdc > 0) {
            plan.state.waterfall.unpaidSeniorYield += plan.yieldAccrued;
            plan.state.waterfall = HousePoolWaterfallAccountingLib.absorbLoss(plan.state.waterfall, plan.deltaUsdc);
            return plan;
        }

        plan.state.waterfall.unpaidSeniorYield += plan.yieldAccrued;
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
