// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";

/// @title IHousePoolRedemptionMathSidecar
/// @notice Stateless redemption-pricing and claimant-accounting helpers used by HousePool epoch settlement.
interface IHousePoolRedemptionMathSidecar {

    /// @notice Returns the fixed implementation identifier validated by HousePool at deployment.
    function implementationId() external pure returns (bytes32);

    /// @notice Previews coupon, waterfall reconciliation, and pending claimant bucket settlement.
    function previewPendingAccountingState(
        HousePoolPendingPreviewLib.PendingAccountingState calldata state,
        HousePoolAccountingLib.ReconcileSnapshot calldata snapshot,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets calldata settleableClaimantBuckets,
        uint256 seniorRateBps,
        uint256 couponElapsed,
        bool markFresh
    ) external pure returns (HousePoolPendingPreviewLib.PendingAccountingState memory pendingState);

    /// @notice Caps pending revenue to backing and settleable claimant value above the unassigned reserve.
    /// @dev Positive terminal receivables back claimant intent. Trader claims and terminal payables defer settlement
    ///      without writing off otherwise backed revenue. Recapitalization retains priority and its full intent.
    function capPendingClaimantBuckets(
        uint256 physicalAssets,
        int256 terminalLpPriceDeltaAssets,
        uint256 distributableAssets,
        uint256 unassignedAssets,
        uint256 recapitalizationAssets,
        uint256 revenueAssets
    ) external pure returns (uint256 backedRevenue, uint256 settleableRecapitalization, uint256 settleableRevenue);

    /// @notice Returns the net assets paid for an exact share redemption.
    function netAssetsForShares(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 netAssets);

    /// @notice Returns the greatest positive-payout share fill whose net assets do not exceed a budget.
    function maxSharesForNetBudget(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 fundedShares, uint256 netAssets);

}
