// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BasketOracle
/// @notice Aggregates multiple Chainlink feeds into a normalized weighted plDXY basket price.
/// @dev Price = Sum(Weight_i * Price_i / BasePrice_i). Normalization preserves intended currency weights.
contract BasketOracle is AggregatorV3Interface, Ownable2Step {

    /// @notice Component feed with its basket weight and base price for normalization.
    struct Component {
        AggregatorV3Interface feed;
        uint256 quantity;
        uint256 basePrice;
    }

    /// @notice Array of currency components (EUR, JPY, GBP, CAD, SEK, CHF).
    Component[] public components;

    /// @notice Chainlink standard decimals for fiat/USD pairs.
    uint8 public constant DECIMALS = 8;

    /// @notice Oracle description string.
    string public constant DESCRIPTION = "plDXY Fixed Basket (Bounded)";

    /// @notice Curve pool for deviation validation.
    ICurvePool public curvePool;

    /// @notice Pending Curve pool for timelock-protected updates.
    address public pendingCurvePool;

    /// @notice Timestamp when pending Curve pool can be finalized.
    uint256 public curvePoolActivationTime;

    /// @notice Timelock delay for Curve pool updates (7 days).
    uint256 public constant TIMELOCK_DELAY = 7 days;

    /// @notice Maximum allowed deviation from Curve spot (basis points).
    uint256 public immutable MAX_DEVIATION_BPS;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice Thrown when a component feed returns invalid price.
    error BasketOracle__InvalidPrice(address feed);

    /// @notice Thrown when feeds and quantities arrays have different lengths.
    error BasketOracle__LengthMismatch();

    /// @notice Thrown when basket price deviates too far from Curve spot.
    error BasketOracle__PriceDeviation(uint256 theoretical, uint256 spot);

    /// @notice Thrown when Curve pool is already configured.
    error BasketOracle__AlreadySet();

    /// @notice Thrown when timelock period has not elapsed.
    error BasketOracle__TimelockActive();

    /// @notice Thrown when no pending proposal exists.
    error BasketOracle__InvalidProposal();

    /// @notice Emitted when a new Curve pool is proposed.
    event CurvePoolProposed(address indexed newPool, uint256 activationTime);

    /// @notice Emitted when Curve pool is updated.
    event CurvePoolUpdated(address indexed oldPool, address indexed newPool);

    /// @notice Thrown when max deviation is zero.
    error BasketOracle__InvalidDeviation();

    /// @notice Thrown when a base price is zero.
    error BasketOracle__InvalidBasePrice();

    /// @notice Creates basket oracle with currency components.
    /// @param _feeds Array of Chainlink feed addresses.
    /// @param _quantities Array of basket weights (1e18 precision).
    /// @param _basePrices Array of base prices for normalization (8 decimals).
    /// @param _maxDeviationBps Maximum deviation from Curve (e.g., 200 = 2%).
    /// @param _cap Protocol CAP price (8 decimals).
    /// @param _owner Admin address for Curve pool management.
    constructor(
        address[] memory _feeds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        uint256 _maxDeviationBps,
        uint256 _cap,
        address _owner
    ) Ownable(_owner) {
        if (_feeds.length != _quantities.length) revert BasketOracle__LengthMismatch();
        if (_feeds.length != _basePrices.length) revert BasketOracle__LengthMismatch();
        if (_maxDeviationBps == 0) revert BasketOracle__InvalidDeviation();

        for (uint256 i = 0; i < _feeds.length; i++) {
            AggregatorV3Interface feed = AggregatorV3Interface(_feeds[i]);
            if (feed.decimals() != DECIMALS) revert BasketOracle__InvalidPrice(address(feed));
            if (_basePrices[i] == 0) revert BasketOracle__InvalidBasePrice();

            components.push(Component({feed: feed, quantity: _quantities[i], basePrice: _basePrices[i]}));
        }

        MAX_DEVIATION_BPS = _maxDeviationBps;
        CAP = _cap;
    }

    /// @notice Sets the Curve pool for deviation validation (initial setup only).
    /// @param _curvePool Curve USDC/plDXY-BEAR pool address.
    function setCurvePool(
        address _curvePool
    ) external onlyOwner {
        if (address(curvePool) != address(0)) revert BasketOracle__AlreadySet();
        curvePool = ICurvePool(_curvePool);
        emit CurvePoolUpdated(address(0), _curvePool);
    }

    /// @notice Proposes a new Curve pool (requires 7-day timelock).
    /// @param _newPool New Curve pool address.
    function proposeCurvePool(
        address _newPool
    ) external onlyOwner {
        if (address(curvePool) == address(0)) revert BasketOracle__InvalidProposal();
        // slither-disable-next-line missing-zero-check
        pendingCurvePool = _newPool;
        curvePoolActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit CurvePoolProposed(_newPool, curvePoolActivationTime);
    }

    /// @notice Finalizes the Curve pool update after timelock expires.
    function finalizeCurvePool() external onlyOwner {
        if (pendingCurvePool == address(0)) revert BasketOracle__InvalidProposal();
        if (block.timestamp < curvePoolActivationTime) revert BasketOracle__TimelockActive();

        address oldPool = address(curvePool);
        curvePool = ICurvePool(pendingCurvePool);
        emit CurvePoolUpdated(oldPool, pendingCurvePool);
        pendingCurvePool = address(0);
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

            // Normalized: Weight (18 dec) * Price (8 dec) / (BasePrice (8 dec) * 1e10) = 8 decimals
            // This preserves intended currency weights regardless of absolute FX rate scales
            int256 value = (price * int256(components[i].quantity))
                / int256(components[i].basePrice * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);
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
        uint256 basePrice = theoreticalBear18 > spotBear18 ? theoreticalBear18 : spotBear18;
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
