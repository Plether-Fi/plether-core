// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title HousePoolRedemptionMathLib
/// @notice Exact ERC-4626 redemption pricing and budget-capped share funding helpers.
/// @dev Applies the virtual offsets before the frozen-oracle fee, matching `TrancheVault.previewRedeem` rounding.
///      Canonical principal and supply are bounded protocol accounting values, so adding their configured offsets must
///      fit `uint256`, just as it must in the underlying ERC-4626 conversion. The partial-fill branch proves
///      `budget < type(uint256).max` before evaluating `budget + 1` because the full quote is strictly greater.
library HousePoolRedemptionMathLib {

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice A fee greater than 100% cannot produce a valid redemption quote.
    error HousePoolRedemptionMathLib__InvalidFeeBps();

    /// @notice Returns the net assets paid for an exact share redemption.
    /// @dev Gross assets and the fee are independently rounded down. A 100% fee therefore returns zero.
    /// @param shares Shares priced against the pre-burn supply.
    /// @param principal Tranche principal priced as ERC-4626 total assets.
    /// @param supply Pre-burn tranche share supply.
    /// @param virtualAssets ERC-4626 virtual asset offset.
    /// @param virtualShares ERC-4626 virtual share offset.
    /// @param feeBps Exit fee retained in the tranche, in basis points.
    /// @return netAssets Assets payable after the exit fee.
    function netAssetsForShares(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) internal pure returns (uint256 netAssets) {
        if (feeBps > BPS) {
            revert HousePoolRedemptionMathLib__InvalidFeeBps();
        }
        if (shares == 0 || feeBps == BPS) {
            return 0;
        }

        uint256 grossAssets =
            Math.mulDiv(shares, principal + virtualAssets, supply + virtualShares, Math.Rounding.Floor);
        return Math.mulDiv(grossAssets, BPS - feeBps, BPS, Math.Rounding.Floor);
    }

    /// @notice Returns the greatest positive-payout share fill whose net assets do not exceed a budget.
    /// @dev Exactly inverts both nested floor operations in `netAssetsForShares` in constant time, clamps the result
    ///      to `maxShares`, and recomputes the canonical payout. Returns `(0, 0)` rather than burning shares for no
    ///      payout, including when the fee is 100% or all candidate fills round to zero.
    /// @param budget Maximum net assets available for this redemption.
    /// @param maxShares Maximum shares eligible to be funded.
    /// @param principal Tranche principal priced as ERC-4626 total assets.
    /// @param supply Pre-burn tranche share supply.
    /// @param virtualAssets ERC-4626 virtual asset offset.
    /// @param virtualShares ERC-4626 virtual share offset.
    /// @param feeBps Exit fee retained in the tranche, in basis points.
    /// @return fundedShares Greatest eligible share amount with a positive payout not exceeding `budget`.
    /// @return netAssets Exact net payout for `fundedShares`.
    function maxSharesForNetBudget(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) internal pure returns (uint256 fundedShares, uint256 netAssets) {
        if (feeBps > BPS) {
            revert HousePoolRedemptionMathLib__InvalidFeeBps();
        }
        if (budget == 0 || maxShares == 0 || feeBps == BPS) {
            return (0, 0);
        }

        uint256 maxNetAssets = netAssetsForShares(maxShares, principal, supply, virtualAssets, virtualShares, feeBps);
        if (maxNetAssets == 0) {
            return (0, 0);
        }
        if (maxNetAssets <= budget) {
            return (maxShares, maxNetAssets);
        }

        uint256 feeAdjustedBps = BPS - feeBps;
        uint256 grossAssetCap = Math.mulDiv(budget + 1, BPS, feeAdjustedBps, Math.Rounding.Ceil) - 1;
        uint256 adjustedAssets = principal + virtualAssets;
        uint256 adjustedSupply = supply + virtualShares;
        fundedShares = Math.mulDiv(grossAssetCap + 1, adjustedSupply, adjustedAssets, Math.Rounding.Ceil) - 1;
        if (fundedShares > maxShares) {
            fundedShares = maxShares;
        }

        netAssets = netAssetsForShares(fundedShares, principal, supply, virtualAssets, virtualShares, feeBps);
        if (netAssets == 0) {
            return (0, 0);
        }

        assert(netAssets <= budget);
        assert(
            fundedShares == maxShares
                || netAssetsForShares(fundedShares + 1, principal, supply, virtualAssets, virtualShares, feeBps)
                    > budget
        );
    }

}
