// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IPyth, PythStructs} from "../interfaces/IPyth.sol";

/// @title PythAdapter
/// @custom:security-contact contact@plether.com
/// @notice Adapts Pyth Network price feeds to Chainlink's AggregatorV3Interface.
/// @dev Pyth is pull-based: prices must be pushed on-chain before reading.
///      This adapter reads the latest price and converts it to 8 decimals.
///      Supports price inversion for feeds like USD/SEK → SEK/USD.
contract PythAdapter is AggregatorV3Interface {

    IPyth public immutable PYTH;
    bytes32 public immutable PRICE_ID;
    uint256 public immutable MAX_STALENESS;
    bool public immutable INVERSE;

    uint8 public constant DECIMALS = 8;
    string public DESCRIPTION;

    error PythAdapter__StalePrice(uint256 publishTime, uint256 maxAge);
    error PythAdapter__InvalidPrice();
    error PythAdapter__InvalidRoundId();

    /// @param pyth_ Pyth contract address on this chain.
    /// @param priceId_ Pyth price feed ID (e.g., USD/SEK).
    /// @param maxStaleness_ Maximum age of price in seconds before considered stale.
    /// @param description_ Human-readable description (e.g., "SEK / USD").
    /// @param inverse_ If true, inverts the price (e.g., USD/SEK → SEK/USD).
    constructor(
        address pyth_,
        bytes32 priceId_,
        uint256 maxStaleness_,
        string memory description_,
        bool inverse_
    ) {
        PYTH = IPyth(pyth_);
        PRICE_ID = priceId_;
        MAX_STALENESS = maxStaleness_;
        DESCRIPTION = description_;
        INVERSE = inverse_;
    }

    /// @notice Returns the latest price data in Chainlink-compatible format.
    /// @dev Converts Pyth's variable exponent to fixed 8 decimals.
    /// @return roundId Always returns 1 (Pyth doesn't use rounds).
    /// @return answer Price in 8 decimals.
    /// @return startedAt Pyth publish time.
    /// @return updatedAt Pyth publish time.
    /// @return answeredInRound Always returns 1.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        PythStructs.Price memory price = PYTH.getPriceUnsafe(PRICE_ID);

        if (price.publishTime == 0 || block.timestamp - price.publishTime > MAX_STALENESS) {
            revert PythAdapter__StalePrice(price.publishTime, MAX_STALENESS);
        }

        if (price.price <= 0) {
            revert PythAdapter__InvalidPrice();
        }

        int256 answer;
        if (INVERSE) {
            answer = _invertTo8Decimals(price.price, price.expo);
        } else {
            answer = _convertTo8Decimals(price.price, price.expo);
        }

        return (1, answer, price.publishTime, price.publishTime, 1);
    }

    /// @notice Returns data for a specific round ID.
    /// @dev Only round ID 1 is supported (Pyth doesn't use rounds).
    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (_roundId != 1) {
            revert PythAdapter__InvalidRoundId();
        }
        return this.latestRoundData();
    }

    /// @notice Returns the number of decimals (always 8 for compatibility).
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /// @notice Returns the price feed description.
    function description() external view returns (string memory) {
        return DESCRIPTION;
    }

    /// @notice Returns the adapter version.
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice Updates the Pyth price feed with new data.
    /// @dev Anyone can call this to push fresh prices on-chain.
    /// @param updateData Price update data from Pyth's Hermes API.
    function updatePrice(
        bytes[] calldata updateData
    ) external payable {
        uint256 fee = PYTH.getUpdateFee(updateData);
        PYTH.updatePriceFeeds{value: fee}(updateData);
    }

    /// @notice Returns the fee required to update the price.
    /// @param updateData Price update data to calculate fee for.
    /// @return fee Fee in wei.
    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256 fee) {
        return PYTH.getUpdateFee(updateData);
    }

    /// @notice Converts Pyth price to 8 decimals.
    /// @dev Pyth uses variable exponents (e.g., -8, -6). This normalizes to -8.
    /// @param price Pyth price value.
    /// @param expo Pyth exponent (negative for decimal places).
    /// @return Normalized price in 8 decimals.
    function _convertTo8Decimals(
        int64 price,
        int32 expo
    ) internal pure returns (int256) {
        // Target: 8 decimals (10^-8)
        // Pyth: price * 10^expo
        // Result: price * 10^(expo + 8)

        int256 expoAdjustment = int256(expo) + 8;

        if (expoAdjustment >= 0) {
            return int256(price) * int256(10 ** uint256(expoAdjustment));
        } else {
            return int256(price) / int256(10 ** uint256(-expoAdjustment));
        }
    }

    /// @notice Inverts Pyth price and converts to 8 decimals.
    /// @dev For converting USD/SEK to SEK/USD: 1 / (price * 10^expo) * 10^8
    /// @param price Pyth price value.
    /// @param expo Pyth exponent (negative for decimal places).
    /// @return Inverted price in 8 decimals.
    function _invertTo8Decimals(
        int64 price,
        int32 expo
    ) internal pure returns (int256) {
        // Pyth gives: price * 10^expo (e.g., 894849 * 10^-5 = 8.94849 USD/SEK)
        // We need: 1 / (price * 10^expo) in 8 decimals
        // Formula: 10^(8 - expo) / price

        int256 expoAdjustment = 8 - int256(expo);

        // expoAdjustment will be positive for typical FX feeds (expo is negative)
        // e.g., expo = -5 → expoAdjustment = 8 - (-5) = 13
        return int256(10 ** uint256(expoAdjustment)) / int256(price);
    }

}
