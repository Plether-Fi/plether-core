// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IHousePoolRedemptionMathSidecar} from "@plether/perps/interfaces/IHousePoolRedemptionMathSidecar.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolReconcilePlanLib} from "@plether/perps/libraries/HousePoolReconcilePlanLib.sol";
import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";

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
    function planReconcile(
        HousePoolPendingPreviewLib.PendingAccountingState calldata state,
        HousePoolAccountingLib.ReconcileSnapshot calldata snapshot,
        uint256 pendingBucketAssets,
        uint256 seniorRateBps,
        uint256 couponElapsed,
        bool markFresh
    ) external pure returns (HousePoolReconcilePlanLib.ReconcilePlan memory) {
        return HousePoolReconcilePlanLib.planReconcile(
            state, snapshot, pendingBucketAssets, seniorRateBps, couponElapsed, markFresh
        );
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
