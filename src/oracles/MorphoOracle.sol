// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";

/// @notice Interface for Morpho-compatible price oracles.
interface IMorphoOracle {
    /// @notice Returns price of 1 collateral unit in loan asset terms (1e36 scale).
    function price() external view returns (uint256);
}

/// @title MorphoOracle
/// @notice Adapts BasketOracle price to Morpho Blue's 1e36 scale format.
/// @dev Supports both DXY-BEAR (direct) and DXY-BULL (inverse) pricing.
contract MorphoOracle is IMorphoOracle {
    /// @notice Source price feed (BasketOracle).
    AggregatorV3Interface public immutable BASKET_ORACLE;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice If true, returns CAP - Price (for DXY-BULL).
    bool public immutable IS_INVERSE;

    /// @notice Thrown when source oracle returns zero or negative price.
    error MorphoOracle__InvalidPrice();

    /// @notice Creates Morpho-compatible oracle wrapper.
    /// @param _basketOracle BasketOracle address.
    /// @param _cap Protocol CAP (8 decimals, e.g., 2e8 = $2.00).
    /// @param _isInverse True for DXY-BULL (CAP - Price), false for DXY-BEAR.
    constructor(address _basketOracle, uint256 _cap, bool _isInverse) {
        BASKET_ORACLE = AggregatorV3Interface(_basketOracle);
        CAP = _cap;
        IS_INVERSE = _isInverse;
    }

    /// @notice Returns collateral price scaled to 1e36.
    /// @return Price of 1 DXY token in USDC terms (1e36 scale).
    function price() external view override returns (uint256) {
        // 1. Get Price from Basket (8 decimals)
        (, int256 rawPrice,,,) = BASKET_ORACLE.latestRoundData();

        // Safety: Valid price and not stale (simple check, consumer can add strict staleness)
        if (rawPrice <= 0) revert MorphoOracle__InvalidPrice();

        uint256 basketPrice = uint256(rawPrice);
        uint256 finalPrice;

        // 2. Calculate Token Value
        if (IS_INVERSE) {
            // Logic for DXY-BULL - inverse token
            // Value = Cap - Basket

            if (basketPrice >= CAP) {
                // Scenario: Dollar crashed hard, or Basket pumped hard.
                // The Bull token is effectively worthless (or negative, which implies 0).
                // We return 0 so the lending market knows the collateral is dead.
                return 0;
            }
            finalPrice = CAP - basketPrice;
        } else {
            // Logic for DXY-BEAR - direct token
            // Value = Basket
            finalPrice = basketPrice;
        }

        // 3. Scale Up to 1e36
        // Example: Price $1.00 (10^8) * 10^28 = 10^36
        return finalPrice * DecimalConstants.CHAINLINK_TO_MORPHO_SCALE;
    }
}
