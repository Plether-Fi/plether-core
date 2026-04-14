// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolPendingPreviewLib} from "./HousePoolPendingPreviewLib.sol";

library HousePoolPendingLivePlanLib {

    struct PendingLivePlan {
        HousePoolPendingPreviewLib.PendingAccountingState state;
        bool seniorPrincipalChanged;
    }

    function planApplyPendingClaimantBuckets(
        HousePoolPendingPreviewLib.PendingAccountingState memory state,
        uint256 currentSeniorPrincipal,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets
    ) internal pure returns (PendingLivePlan memory plan) {
        plan.state = state;
        HousePoolPendingPreviewLib.applyPendingClaimantBucketsPreview(plan.state, claimantBuckets);

        plan.seniorPrincipalChanged = plan.state.waterfall.seniorPrincipal != currentSeniorPrincipal;
    }

}
