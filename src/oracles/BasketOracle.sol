// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";

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
    ICurvePool public curvePool;
    uint256 public immutable MAX_DEVIATION_BPS; // e.g. 200 = 2%
    uint256 public immutable CAP; // Price cap in 8 decimals (e.g., 2e8 = $2.00)
    address public immutable OWNER;

    error BasketOracle__InvalidPrice(address feed);
    error BasketOracle__LengthMismatch();
    error BasketOracle__PriceDeviation(uint256 theoretical, uint256 spot);
    error BasketOracle__Unauthorized();
    error BasketOracle__AlreadySet();

    constructor(
        address[] memory _feeds,
        uint256[] memory _quantities,
        uint256 _maxDeviationBps,
        uint256 _cap,
        address _owner
    ) {
        if (_feeds.length != _quantities.length) revert BasketOracle__LengthMismatch();

        for (uint256 i = 0; i < _feeds.length; i++) {
            AggregatorV3Interface feed = AggregatorV3Interface(_feeds[i]);
            if (feed.decimals() != DECIMALS) revert BasketOracle__InvalidPrice(address(feed));

            components.push(Component({feed: feed, quantity: _quantities[i]}));
        }

        MAX_DEVIATION_BPS = _maxDeviationBps;
        CAP = _cap;
        OWNER = _owner;
    }

    /// @notice Sets the Curve pool address for price deviation checks. Can only be called once.
    /// @param _curvePool The Curve pool address
    function setCurvePool(address _curvePool) external {
        if (msg.sender != OWNER) revert BasketOracle__Unauthorized();
        if (address(curvePool) != address(0)) revert BasketOracle__AlreadySet();
        curvePool = ICurvePool(_curvePool);
    }

    /// @notice Returns the aggregated basket price from all component feeds.
    /// @return roundId Mock round ID (always 1).
    /// @return answer The calculated basket price in 8 decimals.
    /// @return startedAt Timestamp of oldest component update.
    /// @return updatedAt Timestamp of oldest component update (weakest link).
    /// @return answeredInRound Mock answered round (always 1).
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
     * @notice Compares Theoretical DXY-BEAR price with Curve spot price.
     * @dev Curve pool returns DXY-BEAR price, so we convert theoretical DXY to DXY-BEAR: CAP - DXY.
     * @dev Reverts if the difference exceeds MAX_DEVIATION_BPS.
     * @dev Skips check if Curve pool is not yet configured.
     */
    function _checkDeviation(uint256 theoreticalDxy8Dec) internal view {
        ICurvePool pool = curvePool;
        if (address(pool) == address(0)) return;

        uint256 cap18 = CAP * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;
        uint256 dxy18 = theoreticalDxy8Dec * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;
        uint256 theoreticalBear18 = cap18 - dxy18;

        uint256 spotBear18 = pool.price_oracle();
        if (spotBear18 == 0) revert BasketOracle__InvalidPrice(address(pool));

        uint256 diff = theoreticalBear18 > spotBear18 ? theoreticalBear18 - spotBear18 : spotBear18 - theoreticalBear18;
        uint256 basePrice = theoreticalBear18 < spotBear18 ? theoreticalBear18 : spotBear18;
        uint256 threshold = (basePrice * MAX_DEVIATION_BPS) / 10000;

        if (diff > threshold) {
            revert BasketOracle__PriceDeviation(theoreticalBear18, spotBear18);
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
