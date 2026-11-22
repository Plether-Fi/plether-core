// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHousePoolRedemptionMathSidecar} from "@plether/perps/interfaces/IHousePoolRedemptionMathSidecar.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";
import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";

/// @title HousePoolRedemptionMathSidecar
/// @notice Stateless redemption-pricing and claimant-accounting helpers extracted for deployable HousePool runtime size.
/// @dev HousePool validates `implementationId()` once and stores this contract as an immutable dependency. The
///      sidecar has no storage, privileged caller, upgrade path, or ability to mutate protocol state.
contract HousePoolRedemptionMathSidecar is IHousePoolRedemptionMathSidecar {

    bytes32 internal constant IMPLEMENTATION_ID = keccak256("Plether.HousePoolRedemptionMathSidecar.v2");

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function implementationId() external pure returns (bytes32) {
        return IMPLEMENTATION_ID;
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function previewPendingAccountingState(
        HousePoolPendingPreviewLib.PendingAccountingState calldata state,
        HousePoolAccountingLib.ReconcileSnapshot calldata snapshot,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets calldata settleableClaimantBuckets,
        uint256 seniorRateBps,
        uint256 couponElapsed,
        bool markFresh
    ) external pure returns (HousePoolPendingPreviewLib.PendingAccountingState memory pendingState) {
        pendingState = state;
        uint256 allocatedAssets = HousePoolPendingPreviewLib.claimantBucketAssets(settleableClaimantBuckets);
        if (couponElapsed > 0 && pendingState.juniorSupply > 0) {
            (pendingState.waterfall,) =
                HousePoolWaterfallAccountingLib.paySeniorCoupon(pendingState.waterfall, seniorRateBps, couponElapsed);
        }
        uint256 claimedBeforeRecap = pendingState.waterfall.seniorPrincipal + pendingState.waterfall.juniorPrincipal;
        uint256 ordinaryRevenue;
        if (markFresh) {
            uint256 distributable =
                snapshot.distributable > allocatedAssets ? snapshot.distributable - allocatedAssets : 0;
            pendingState.unassignedAssets = Math.min(pendingState.unassignedAssets, distributable);
            uint256 distributableToClaims = distributable - pendingState.unassignedAssets;
            if (distributableToClaims < claimedBeforeRecap) {
                pendingState.waterfall = HousePoolWaterfallAccountingLib.absorbLoss(
                    pendingState.waterfall, claimedBeforeRecap - distributableToClaims
                );
            } else {
                ordinaryRevenue = distributableToClaims - claimedBeforeRecap;
            }
        }

        // Losses precede the recap; the recap precedes ordinary gains so Senior's gap is filled only once.
        HousePoolPendingPreviewLib.applyClaimantRecapitalizationIntent(
            pendingState, settleableClaimantBuckets.recapitalizationAssets
        );
        if (ordinaryRevenue > 0) {
            if (claimedBeforeRecap == 0) {
                HousePoolPendingPreviewLib.applyRevenueIntent(pendingState, ordinaryRevenue);
            } else {
                uint256 juniorBeforeRevenue = pendingState.waterfall.juniorPrincipal;
                pendingState.waterfall =
                    HousePoolWaterfallAccountingLib.distributeRevenue(pendingState.waterfall, ordinaryRevenue);
                if (pendingState.juniorSupply == 0) {
                    pendingState.unassignedAssets += pendingState.waterfall.juniorPrincipal - juniorBeforeRevenue;
                    pendingState.waterfall.juniorPrincipal = juniorBeforeRevenue;
                }
            }
        }
        HousePoolPendingPreviewLib.applyRevenueIntent(pendingState, settleableClaimantBuckets.revenueAssets);
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function capPendingClaimantBuckets(
        uint256 physicalAssets,
        int256 terminalLpPriceDeltaAssets,
        uint256 distributableAssets,
        uint256 unassignedAssets,
        uint256 recapitalizationAssets,
        uint256 revenueAssets
    ) external pure returns (uint256 backedRevenue, uint256 settleableRecapitalization, uint256 settleableRevenue) {
        uint256 backing = physicalAssets;
        if (terminalLpPriceDeltaAssets > 0) {
            backing += uint256(terminalLpPriceDeltaAssets);
        }
        backing = backing > unassignedAssets ? backing - unassignedAssets : 0;
        backing = backing > recapitalizationAssets ? backing - recapitalizationAssets : 0;
        backedRevenue = revenueAssets > backing ? backing : revenueAssets;

        uint256 distributableToClaims =
            distributableAssets > unassignedAssets ? distributableAssets - unassignedAssets : 0;
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleable =
            HousePoolPendingPreviewLib.capClaimantBuckets(
                HousePoolPendingPreviewLib.ClaimantPendingBuckets(recapitalizationAssets, backedRevenue),
                distributableToClaims
            );
        return (backedRevenue, settleable.recapitalizationAssets, settleable.revenueAssets);
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function netAssetsForShares(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 netAssets) {
        return
            HousePoolRedemptionMathLib.netAssetsForShares(
                shares, principal, supply, virtualAssets, virtualShares, feeBps
            );
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function maxSharesForNetBudget(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 fundedShares, uint256 netAssets) {
        return HousePoolRedemptionMathLib.maxSharesForNetBudget(
            budget, maxShares, principal, supply, virtualAssets, virtualShares, feeBps
        );
    }

}
