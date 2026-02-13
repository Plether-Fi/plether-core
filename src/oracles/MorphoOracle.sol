// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";

/// @notice Interface for Morpho-compatible price oracles.
interface IMorphoOracle {

    /// @notice Returns price of 1 collateral unit in loan asset terms (Morpho scale: 36 + loanDec - colDec = 24 decimals).
    function price() external view returns (uint256);

}

/// @title MorphoOracle
/// @custom:security-contact contact@plether.com
/// @notice Adapts BasketOracle price to Morpho Blue's oracle scale (24 decimals for USDC/plDXY).
/// @dev Supports both plDXY-BEAR (direct) and plDXY-BULL (inverse) pricing.
contract MorphoOracle is IMorphoOracle {

    /// @notice Source price feed (BasketOracle).
    AggregatorV3Interface public immutable BASKET_ORACLE;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice If true, returns CAP - Price (for plDXY-BULL).
    bool public immutable IS_INVERSE;

    /// @notice Maximum age for valid oracle price.
    uint256 public constant STALENESS_TIMEOUT = 24 hours;

    /// @notice Thrown when source oracle returns zero or negative price.
    error MorphoOracle__InvalidPrice();

    /// @notice Thrown when source oracle data is stale.
    error MorphoOracle__StalePrice();

    /// @notice Thrown when zero address provided to constructor.
    error MorphoOracle__ZeroAddress();

    /// @notice Creates Morpho-compatible oracle wrapper.
    /// @param _basketOracle BasketOracle address.
    /// @param _cap Protocol CAP (8 decimals, e.g., 2e8 = $2.00).
    /// @param _isInverse True for plDXY-BULL (CAP - Price), false for plDXY-BEAR.
    constructor(
        address _basketOracle,
        uint256 _cap,
        bool _isInverse
    ) {
        if (_basketOracle == address(0)) {
            revert MorphoOracle__ZeroAddress();
        }
        BASKET_ORACLE = AggregatorV3Interface(_basketOracle);
        CAP = _cap;
        IS_INVERSE = _isInverse;
    }

    /// @notice Returns collateral price in Morpho scale (24 decimals for USDC(6)/plDXY(18)).
    /// @dev Morpho expects: 36 + loanDecimals - collateralDecimals = 36 + 6 - 18 = 24.
    ///      BEAR (IS_INVERSE=false): min(basketPrice, CAP) * CHAINLINK_TO_MORPHO_SCALE.
    ///      BULL (IS_INVERSE=true): (CAP - basketPrice) * CHAINLINK_TO_MORPHO_SCALE.
    ///      Returns 1 (not 0) when BULL price would be zero to avoid Morpho division errors.
    /// @return Price of 1 plDXY token in USDC terms (24 decimals).
    function price() external view override returns (uint256) {
        (, int256 rawPrice,, uint256 updatedAt,) = BASKET_ORACLE.latestRoundData();

        if (rawPrice <= 0) {
            revert MorphoOracle__InvalidPrice();
        }
        if (block.timestamp > updatedAt + STALENESS_TIMEOUT) {
            revert MorphoOracle__StalePrice();
        }

        uint256 basketPrice = uint256(rawPrice);
        uint256 finalPrice;

        if (IS_INVERSE) {
            finalPrice = basketPrice >= CAP ? 0 : CAP - basketPrice;
            if (finalPrice == 0) {
                return 1;
            }
        } else {
            finalPrice = basketPrice > CAP ? CAP : basketPrice;
        }

        return finalPrice * DecimalConstants.CHAINLINK_TO_MORPHO_SCALE;
    }

}
