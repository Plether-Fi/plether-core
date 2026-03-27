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
        HousePoolPendingPreviewLib.applyPendingBucketsPreview(
            plan.state, pendingRecapitalizationUsdc, pendingTradingRevenueUsdc
        );

        plan.seniorPrincipalChanged = plan.state.waterfall.seniorPrincipal != currentSeniorPrincipal;
    }

}
