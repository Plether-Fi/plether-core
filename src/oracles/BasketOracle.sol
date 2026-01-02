// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";

/**
 * @title BasketOracle
 * @notice Aggregates multiple Chainlink feeds into a single "Basket" price.
 * @dev Uses Arithmetic Sum: Price = Sum(Price_i * Quantity_i)
 * @dev Includes Bound Validator: Reverts if Basket Price deviates from Curve Spot Price.
 */
contract BasketOracle is AggregatorV3Interface {
    struct Component {
        AggregatorV3Interface feed;
        uint256 quantity; // The fixed amount of units (1e18 precision)
    }

    Component[] public components;
    uint8 public constant DECIMALS = 8; // Chainlink Standard for Fiat/USD
    string public constant DESCRIPTION = "DXY Fixed Basket (Bounded)";

    // ==========================================
    // BOUND VALIDATOR CONFIG
    // ==========================================
    ICurvePool public immutable CURVE_POOL;
    uint256 public immutable MAX_DEVIATION_BPS; // e.g. 200 = 2%

    error BasketOracle__InvalidPrice(address feed);
    error BasketOracle__LengthMismatch();
    error BasketOracle__PriceDeviation(uint256 theoretical, uint256 spot);
    error BasketOracle__ZeroAddress();

    constructor(address[] memory _feeds, uint256[] memory _quantities, address _curvePool, uint256 _maxDeviationBps) {
        if (_feeds.length != _quantities.length) revert BasketOracle__LengthMismatch();
        if (_curvePool == address(0)) revert BasketOracle__ZeroAddress();

        for (uint256 i = 0; i < _feeds.length; i++) {
            AggregatorV3Interface feed = AggregatorV3Interface(_feeds[i]);
            // SAFETY CHECK: Ensure feed uses expected precision
            if (feed.decimals() != DECIMALS) revert BasketOracle__InvalidPrice(address(feed));

            components.push(Component({feed: feed, quantity: _quantities[i]}));
        }

        CURVE_POOL = ICurvePool(_curvePool);
        MAX_DEVIATION_BPS = _maxDeviationBps;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        int256 totalPrice = 0;
        uint256 minUpdatedAt = type(uint256).max;
        uint256 len = components.length;

        // 1. Calculate Theoretical Price (Basket Sum)
        for (uint256 i = 0; i < len; i++) {
            (, int256 price,, uint256 updatedAt,) = components[i].feed.latestRoundData();

            // Safety: Price must be positive
            if (price <= 0) revert BasketOracle__InvalidPrice(address(components[i].feed));

            // Math: Price (8 dec) * Quantity (18 dec) / 1e18 = 8 decimals
            int256 value = (price * int256(components[i].quantity)) / 1e18;
            totalPrice += value;

            // The basket is only as fresh as its oldest component
            if (updatedAt < minUpdatedAt) {
                minUpdatedAt = updatedAt;
            }
        }

        // 2. Bound Check: Compare Theoretical vs Curve Spot
        // Only run check if we have a valid price
        if (totalPrice > 0) {
            _checkDeviation(uint256(totalPrice));
        }

        return (
            uint80(1), // Mock Round ID
            totalPrice, // The calculated Basket Price
            minUpdatedAt, // StartedAt
            minUpdatedAt, // UpdatedAt (Weakest Link)
            uint80(1) // Mock AnsweredInRound
        );
    }

    /**
     * @notice Compares Theoretical Price (Chainlink) with Spot Price (Curve).
     * @dev Reverts if the difference exceeds MAX_DEVIATION_BPS.
     */
    function _checkDeviation(uint256 theoreticalPrice8Dec) internal view {
        // Curve returns 18 decimals usually. Chainlink is 8.
        // Scale Theoretical to 18 decimals for comparison.
        uint256 theoretical18 = theoreticalPrice8Dec * 1e10;

        // Get Spot Price (EMA) from Curve V2
        // Note: Assumes Curve Pool is [USDC, TOKEN] or similar where price_oracle returns
        // the TOKEN price in USDC (1e18 precision).
        uint256 spot18 = CURVE_POOL.price_oracle();

        // Safety: Spot price must be positive
        if (spot18 == 0) revert BasketOracle__InvalidPrice(address(CURVE_POOL));

        // Calculate difference
        uint256 diff = theoretical18 > spot18 ? theoretical18 - spot18 : spot18 - theoretical18;

        // Threshold: Use min of theoretical and spot to prevent manipulation
        // If attacker inflates Chainlink, they can't inflate the threshold
        uint256 basePrice = theoretical18 < spot18 ? theoretical18 : spot18;
        uint256 threshold = (basePrice * MAX_DEVIATION_BPS) / 10000;

        if (diff > threshold) {
            revert BasketOracle__PriceDeviation(theoretical18, spot18);
        }
    }

    // ==========================================
    // Boilerplate for Interface Compliance
    // ==========================================
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function description() external pure returns (string memory) {
        return DESCRIPTION;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return this.latestRoundData();
    }
}
