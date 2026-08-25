// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title IHousePoolRedemptionMathSidecar
/// @notice Stateless redemption-pricing helpers used by HousePool epoch settlement.
interface IHousePoolRedemptionMathSidecar {

    /// @notice Returns the fixed implementation identifier validated by HousePool at deployment.
    function implementationId() external pure returns (bytes32);

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
