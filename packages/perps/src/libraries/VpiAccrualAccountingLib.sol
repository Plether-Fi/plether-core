// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

/// @title VpiAccrualAccountingLib
/// @notice Tracks deferred positive VPI and reserve-backed negative VPI across live positions.
/// @dev All values use settlement token atoms with 6 decimals. Separate unsigned totals avoid signed aggregate overflow.
library VpiAccrualAccountingLib {

    /// @notice Returns one position's contribution to each gross VPI aggregate.
    /// @dev Supports the entire int256 domain, including its minimum value.
    function contribution(
        int256 accruedAssets
    ) internal pure returns (uint256 positiveAssets, uint256 negativeAssets) {
        if (accruedAssets > 0) {
            positiveAssets = uint256(accruedAssets);
        } else if (accruedAssets < 0) {
            negativeAssets = uint256(-(accruedAssets + 1)) + 1;
        }
    }

    /// @notice Preflights replacing one position's signed VPI contribution in the gross aggregates.
    /// @dev Returns false if the prior contribution is absent or either resulting total overflows uint256.
    function tryReplace(
        uint256 positiveTotalAssets,
        uint256 negativeTotalAssets,
        int256 previousAccruedAssets,
        int256 nextAccruedAssets
    ) internal pure returns (bool valid, uint256 nextPositiveTotalAssets, uint256 nextNegativeTotalAssets) {
        (uint256 previousPositiveAssets, uint256 previousNegativeAssets) = contribution(previousAccruedAssets);
        (uint256 nextPositiveAssets, uint256 nextNegativeAssets) = contribution(nextAccruedAssets);
        if (positiveTotalAssets < previousPositiveAssets || negativeTotalAssets < previousNegativeAssets) {
            return (false, 0, 0);
        }
        unchecked {
            uint256 remainingPositiveAssets = positiveTotalAssets - previousPositiveAssets;
            uint256 remainingNegativeAssets = negativeTotalAssets - previousNegativeAssets;
            nextPositiveTotalAssets = remainingPositiveAssets + nextPositiveAssets;
            nextNegativeTotalAssets = remainingNegativeAssets + nextNegativeAssets;
            valid = nextPositiveTotalAssets >= remainingPositiveAssets
                && nextNegativeTotalAssets >= remainingNegativeAssets;
        }
    }

}
