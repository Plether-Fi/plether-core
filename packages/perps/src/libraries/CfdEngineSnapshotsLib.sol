// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CfdEngineSnapshotsLib
/// @notice Shared compact snapshots used by CFD engine solvency calculations.
library CfdEngineSnapshotsLib {

    /// @notice Physical-asset and maximum-liability snapshot for a solvency check.
    /// @dev All fields are USDC amounts with 6 decimals.
    /// @param physicalAssets Canonical pool assets supplied to the solvency builder.
    /// @param netPhysicalAssets Current net-asset field, equal to `physicalAssets` in the active builder.
    /// @param maxLiability Larger of the bull-side and bear-side maximum-profit envelopes.
    /// @param effectiveSolvencyAssets Physical assets less aggregate trader claims, floored at zero.
    struct SolvencySnapshot {
        uint256 physicalAssets;
        uint256 netPhysicalAssets;
        uint256 maxLiability;
        uint256 effectiveSolvencyAssets;
    }

}
