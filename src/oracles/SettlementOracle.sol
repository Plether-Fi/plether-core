// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/// @title SettlementOracle
/// @custom:security-contact contact@plether.com
/// @notice Pure theoretical oracle for option settlement.
/// @dev Strips out the AMM deviation checks found in BasketOracle to ensure
///      flash-loan resistance during exact-block option expiration.
contract SettlementOracle {

    struct Component {
        AggregatorV3Interface feed;
        uint256 quantity;
        uint256 basePrice;
    }

    Component[] public components;
    uint256 public immutable CAP;

    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 public constant ORACLE_TIMEOUT = 24 hours;

    error SettlementOracle__InvalidPrice(address feed);
    error SettlementOracle__LengthMismatch();
    error SettlementOracle__InvalidBasePrice();
    error SettlementOracle__InvalidWeights();

    constructor(
        address[] memory _feeds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        uint256 _cap,
        address _sequencerUptimeFeed
    ) {
        if (_feeds.length != _quantities.length || _feeds.length != _basePrices.length) {
            revert SettlementOracle__LengthMismatch();
        }

        CAP = _cap;
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _feeds.length; i++) {
            if (_basePrices[i] == 0) {
                revert SettlementOracle__InvalidBasePrice();
            }

            components.push(
                Component({feed: AggregatorV3Interface(_feeds[i]), quantity: _quantities[i], basePrice: _basePrices[i]})
            );
            totalWeight += _quantities[i];
        }

        if (totalWeight != 1e18) {
            revert SettlementOracle__InvalidWeights();
        }
    }

    /// @notice Returns the pure theoretical settlement prices.
    /// @return bearPrice min(BasketPrice, CAP) in 8 decimals
    /// @return bullPrice CAP - bearPrice in 8 decimals
    function getSettlementPrices() external view returns (uint256 bearPrice, uint256 bullPrice) {
        OracleLib.checkSequencer(SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD);

        int256 totalPrice = 0;
        uint256 minUpdatedAt = type(uint256).max;
        uint256 len = components.length;

        for (uint256 i = 0; i < len; i++) {
            (, int256 price,, uint256 updatedAt,) = components[i].feed.latestRoundData();

            if (price <= 0) {
                revert SettlementOracle__InvalidPrice(address(components[i].feed));
            }

            // Weight(18) * Price(8) / BasePrice(8) normalized to 8 decimals
            int256 value = (price * int256(components[i].quantity))
                / int256(components[i].basePrice * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);
            totalPrice += value;

            if (updatedAt < minUpdatedAt) {
                minUpdatedAt = updatedAt;
            }
        }

        OracleLib.checkStaleness(minUpdatedAt, ORACLE_TIMEOUT);

        uint256 theoreticalBear = uint256(totalPrice);

        bearPrice = theoreticalBear > CAP ? CAP : theoreticalBear;
        bullPrice = CAP - bearPrice;
    }

}
