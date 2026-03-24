// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolPendingPreviewLib} from "./HousePoolPendingPreviewLib.sol";

library HousePoolPendingLivePlanLib {
    struct PendingLivePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
        bool seniorPrincipalChanged;
    }

    function planApplyPendingBuckets(
        HousePoolPendingPreviewLib.PendingAccountingState memory state,
        uint256 currentSeniorPrincipal,
        uint256 pendingRecapitalizationUsdc,
        uint256 pendingTradingRevenueUsdc
    ) internal pure returns (PendingLivePlan memory plan) {
        plan.state = state;

        if (pendingRecapitalizationUsdc > 0) {
            HousePoolPendingPreviewLib.applyRecapitalizationIntent(plan.state, pendingRecapitalizationUsdc);
        }
        if (pendingTradingRevenueUsdc > 0) {
            HousePoolPendingPreviewLib.routeSeededRevenue(plan.state, pendingTradingRevenueUsdc);
        }

        plan.seniorPrincipalChanged = plan.state.waterfall.seniorPrincipal != currentSeniorPrincipal;
    }
}
