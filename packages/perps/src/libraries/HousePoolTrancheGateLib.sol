// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title HousePoolTrancheGateLib
/// @notice Evaluates the common lifecycle, freshness, and impairment gates for tranche deposits.
/// @dev Instant-deposit open-interest checks and caller, vault, and amount authorization are applied elsewhere.
library HousePoolTrancheGateLib {

    /// @notice Evaluates the lifecycle, pause, freshness, unassigned-asset, and senior-impairment inputs supplied.
    /// @param ordinaryDepositsAllowed Whether seed and trading-activation prerequisites are satisfied.
    /// @param paused Whether HousePool is paused.
    /// @param unassignedAssets Current unassigned pool assets (6 decimals).
    /// @param markFreshForReconcile Whether the cached mark is fresh enough to reconcile.
    /// @param projectedUnassignedAssets Projected unassigned assets plus residual unapplied claimant buckets after
    ///        pending accounting (6 decimals).
    /// @param projectedSeniorPrincipal Senior principal after pending reconciliation (6 decimals).
    /// @param projectedSeniorHighWaterMark Senior high-water mark after pending reconciliation (6 decimals).
    /// @return Whether all gates represented by the supplied inputs pass.
    function trancheDepositsAllowed(
        bool ordinaryDepositsAllowed,
        bool paused,
        uint256 unassignedAssets,
        bool markFreshForReconcile,
        uint256 projectedUnassignedAssets,
        uint256 projectedSeniorPrincipal,
        uint256 projectedSeniorHighWaterMark
    ) internal pure returns (bool) {
        if (!ordinaryDepositsAllowed || paused || unassignedAssets > 0 || !markFreshForReconcile) {
            return false;
        }

        if (projectedUnassignedAssets > 0) {
            return false;
        }

        if (projectedSeniorPrincipal < projectedSeniorHighWaterMark) {
            return false;
        }

        return true;
    }

}
