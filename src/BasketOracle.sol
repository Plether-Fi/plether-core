// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title BasketOracle
 * @notice Aggregates multiple Chainlink feeds into a single "Basket" price.
 * @dev Uses Arithmetic Sum: Price = Sum(Price_i * Quantity_i)
 */
contract BasketOracle is AggregatorV3Interface {
    struct Component {
        AggregatorV3Interface feed;
        uint256 quantity; // The fixed amount of units (1e18 precision)
    }

    Component[] public components;
    uint8 public constant DECIMALS = 8; // Chainlink Standard for Fiat/USD
    string public constant DESCRIPTION = "DXY Fixed Basket";

    error BasketOracle__InvalidPrice(address feed);
    error BasketOracle__LengthMismatch();

    constructor(address[] memory _feeds, uint256[] memory _quantities) {
        if (_feeds.length != _quantities.length) revert BasketOracle__LengthMismatch();

        for (uint256 i = 0; i < _feeds.length; i++) {
            components.push(Component({feed: AggregatorV3Interface(_feeds[i]), quantity: _quantities[i]}));
        }
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        int256 totalPrice = 0;
        uint256 minUpdatedAt = type(uint256).max;

        for (uint256 i = 0; i < components.length; i++) {
            (, int256 price,, uint256 updatedAt,) = components[i].feed.latestRoundData();

            // Safety: Price must be positive
            if (price <= 0) revert BasketOracle__InvalidPrice(address(components[i].feed));

            // Math: Price (8 dec) * Quantity (18 dec) = 26 decimals
            // We divide by 1e18 to return to 8 decimals
            int256 value = (price * int256(components[i].quantity)) / 1e18;
            totalPrice += value;

            // The basket is only as fresh as its oldest component
            if (updatedAt < minUpdatedAt) {
                minUpdatedAt = updatedAt;
            }
        }

        return (
            uint80(1), // Mock Round ID
            totalPrice, // The calculated Basket Price
            minUpdatedAt, // StartedAt
            minUpdatedAt, // UpdatedAt (Weakest Link)
            uint80(1) // Mock AnsweredInRound
        );
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
