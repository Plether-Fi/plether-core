// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IMorpho, MarketParams} from "../interfaces/IMorpho.sol";

/// @title IIrm
/// @notice Minimal interface for Morpho Blue Interest Rate Models.
interface IIrm {

    /// @notice Returns the borrow rate per second (scaled by 1e18).
    function borrowRateView(
        MarketParams memory marketParams,
        IMorpho.MarketState memory market
    ) external view returns (uint256);

}

/// @title MorphoBalancesLib
/// @notice Library to compute expected Morpho balances including pending interest.
/// @dev Mirrors Morpho Blue's internal interest accrual logic for accurate view functions.
library MorphoBalancesLib {

    uint256 internal constant WAD = 1e18;

    /// @notice Computes expected total supply assets including pending interest.
    /// @param morpho Morpho Blue contract.
    /// @param marketParams Market parameters.
    /// @return expectedSupplyAssets Total supply assets after pending interest accrual.
    function expectedTotalSupplyAssets(
        IMorpho morpho,
        MarketParams memory marketParams
    ) internal view returns (uint256 expectedSupplyAssets) {
        bytes32 marketId = keccak256(abi.encode(marketParams));

        (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        ) = morpho.market(marketId);

        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0 || totalBorrowAssets == 0) {
            return totalSupplyAssets;
        }

        // Get borrow rate from IRM
        uint256 borrowRate = IIrm(marketParams.irm)
            .borrowRateView(
                marketParams,
                IMorpho.MarketState({
                    totalSupplyAssets: totalSupplyAssets,
                    totalSupplyShares: totalSupplyShares,
                    totalBorrowAssets: totalBorrowAssets,
                    totalBorrowShares: totalBorrowShares,
                    lastUpdate: lastUpdate,
                    fee: fee
                })
            );

        // Interest = borrowAssets * rate * elapsed (using linear approximation)
        // Note: Morpho uses wTaylorCompounded for precision, but linear is sufficient for short periods
        uint256 interest = (uint256(totalBorrowAssets) * borrowRate * elapsed) / WAD;

        // Fee goes to feeRecipient, rest goes to suppliers
        uint256 feeAmount = (interest * fee) / WAD;
        uint256 supplyInterest = interest - feeAmount;

        return totalSupplyAssets + supplyInterest;
    }

    /// @notice Converts supply shares to expected assets including pending interest.
    /// @param morpho Morpho Blue contract.
    /// @param marketParams Market parameters.
    /// @param shares Supply shares to convert.
    /// @return assets Expected asset amount.
    function expectedSupplyAssets(
        IMorpho morpho,
        MarketParams memory marketParams,
        uint256 shares
    ) internal view returns (uint256 assets) {
        if (shares == 0) {
            return 0;
        }

        bytes32 marketId = keccak256(abi.encode(marketParams));
        (, uint128 totalSupplyShares,,,,) = morpho.market(marketId);

        if (totalSupplyShares == 0) {
            return shares;
        }

        uint256 expectedTotal = expectedTotalSupplyAssets(morpho, marketParams);
        return (shares * expectedTotal) / totalSupplyShares;
    }

}
