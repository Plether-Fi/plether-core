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
/// @dev Supports both plDXY-BEAR (direct) and plDXY-BULL (inverse) pricing.
contract MorphoOracle is IMorphoOracle {

    /// @notice Source price feed (BasketOracle).
    AggregatorV3Interface public immutable BASKET_ORACLE;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice If true, returns CAP - Price (for plDXY-BULL).
    bool public immutable IS_INVERSE;

    /// @notice Maximum age for valid oracle price.
    uint256 public constant STALENESS_TIMEOUT = 8 hours;

    /// @notice Thrown when source oracle returns zero or negative price.
    error MorphoOracle__InvalidPrice();

    /// @notice Thrown when source oracle data is stale.
    error MorphoOracle__StalePrice();

    /// @notice Thrown when basket price exceeds protocol CAP (liquidation state).
    error MorphoOracle__PriceExceedsCap();

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

    /// @notice Returns collateral price scaled to 1e36.
    /// @return Price of 1 plDXY token in USDC terms (1e36 scale).
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
            if (basketPrice > CAP) {
                revert MorphoOracle__PriceExceedsCap();
            }
            finalPrice = CAP - basketPrice;
            if (finalPrice == 0) {
                return 1;
            }
        } else {
            finalPrice = basketPrice;
        }

        return finalPrice * DecimalConstants.CHAINLINK_TO_MORPHO_SCALE;
    }

}
