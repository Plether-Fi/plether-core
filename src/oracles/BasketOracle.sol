// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";

/// @title BasketOracle
/// @notice Aggregates multiple Chainlink feeds into a weighted DXY basket price.
/// @dev Price = Sum(Price_i * Quantity_i). Includes bound validation against Curve spot.
contract BasketOracle is AggregatorV3Interface {

    /// @notice Component feed with its basket weight.
    struct Component {
        AggregatorV3Interface feed;
        uint256 quantity;
    }

    /// @notice Array of currency components (EUR, JPY, GBP, CAD, SEK, CHF).
    Component[] public components;

    /// @notice Chainlink standard decimals for fiat/USD pairs.
    uint8 public constant DECIMALS = 8;

    /// @notice Oracle description string.
    string public constant DESCRIPTION = "DXY Fixed Basket (Bounded)";

    /// @notice Curve pool for deviation validation (set once).
    ICurvePool public curvePool;

    /// @notice Maximum allowed deviation from Curve spot (basis points).
    uint256 public immutable MAX_DEVIATION_BPS;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice Admin address for setCurvePool.
    address public immutable OWNER;

    /// @notice Thrown when a component feed returns invalid price.
    error BasketOracle__InvalidPrice(address feed);

    /// @notice Thrown when feeds and quantities arrays have different lengths.
    error BasketOracle__LengthMismatch();

    /// @notice Thrown when basket price deviates too far from Curve spot.
    error BasketOracle__PriceDeviation(uint256 theoretical, uint256 spot);

    /// @notice Thrown when non-owner attempts admin action.
    error BasketOracle__Unauthorized();

    /// @notice Thrown when Curve pool is already configured.
    error BasketOracle__AlreadySet();

    /// @notice Creates basket oracle with currency components.
    /// @param _feeds Array of Chainlink feed addresses.
    /// @param _quantities Array of basket weights (1e18 precision).
    /// @param _maxDeviationBps Maximum deviation from Curve (e.g., 200 = 2%).
    /// @param _cap Protocol CAP price (8 decimals).
    /// @param _owner Admin address for setCurvePool.
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
        // slither-disable-next-line missing-zero-check
        OWNER = _owner;
    }

    /// @notice Sets the Curve pool for deviation validation (one-time only).
    /// @param _curvePool Curve USDC/DXY-BEAR pool address.
    function setCurvePool(
        address _curvePool
    ) external {
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

            // Math: Price (8 dec) * Quantity (18 dec) / ONE_WAD = 8 decimals
            int256 value = (price * int256(components[i].quantity)) / int256(DecimalConstants.ONE_WAD);
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

    /// @dev Validates basket price against Curve spot. Reverts on excessive deviation.
    /// @param theoreticalDxy8Dec Computed basket price (8 decimals).
    function _checkDeviation(
        uint256 theoreticalDxy8Dec
    ) internal view {
        ICurvePool pool = curvePool;
        if (address(pool) == address(0)) return;

        uint256 cap18 = CAP * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;
        uint256 dxy18 = theoreticalDxy8Dec * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;
        uint256 theoreticalBear18 = cap18 - dxy18;

        uint256 spotBear18 = pool.price_oracle();
        if (spotBear18 == 0) revert BasketOracle__InvalidPrice(address(pool));

        uint256 diff = theoreticalBear18 > spotBear18 ? theoreticalBear18 - spotBear18 : spotBear18 - theoreticalBear18;
        uint256 basePrice = theoreticalBear18 < spotBear18 ? theoreticalBear18 : spotBear18;
        uint256 threshold = (basePrice * MAX_DEVIATION_BPS) / 10_000;

        if (diff > threshold) {
            revert BasketOracle__PriceDeviation(theoreticalBear18, spotBear18);
        }
    }

    /// @notice Returns oracle decimals (8).
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /// @notice Returns oracle description.
    function description() external pure returns (string memory) {
        return DESCRIPTION;
    }

    /// @notice Returns oracle version (1).
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice Returns latest data for any round ID (delegates to latestRoundData).
    function getRoundData(
        uint80
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        return this.latestRoundData();
    }

}
