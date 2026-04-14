// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

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
        if (claimantBuckets.recapitalizationUsdc > 0) {
            applyClaimantRecapitalizationIntent(state, claimantBuckets.recapitalizationUsdc);
        }
        if (claimantBuckets.revenueUsdc > 0) {
            applyRevenueIntent(state, claimantBuckets.revenueUsdc);
        }
    }

    function applyClaimantRecapitalizationIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        uint256 remaining = amount;
        if (state.seniorSupply > 0) {
            if (state.waterfall.seniorPrincipal == 0 && state.waterfall.juniorPrincipal == 0) {
                state.waterfall.seniorPrincipal += remaining;
                state.waterfall.seniorHighWaterMark = remaining;
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
        if (state.waterfall.seniorPrincipal + state.waterfall.juniorPrincipal != 0) {
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
