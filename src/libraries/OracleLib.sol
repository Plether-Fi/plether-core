// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title OracleLib
/// @notice Library for common oracle validation patterns.
/// @dev Provides reusable functions for sequencer checks, staleness validation, and price validation.
library OracleLib {

    // Errors
    error OracleLib__SequencerDown();
    error OracleLib__SequencerGracePeriod();
    error OracleLib__StalePrice();
    error OracleLib__InvalidPrice();
    error OracleLib__NoPriceAtExpiry();

    /// @notice Check if the L2 sequencer is up and grace period has passed.
    /// @param sequencerFeed The Chainlink sequencer uptime feed.
    /// @param gracePeriod The grace period in seconds after sequencer comes back up.
    /// @dev Skips check if sequencerFeed is address(0) (e.g., on L1 or testnets).
    function checkSequencer(
        AggregatorV3Interface sequencerFeed,
        uint256 gracePeriod
    ) internal view {
        // Skip check if no feed address is provided
        if (address(sequencerFeed) == address(0)) {
            return;
        }

        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();

        // Answer == 0: Sequencer is UP
        // Answer == 1: Sequencer is DOWN
        if (answer != 0) {
            revert OracleLib__SequencerDown();
        }

        // Check if grace period has passed since sequencer came back up
        if (block.timestamp - startedAt < gracePeriod) {
            revert OracleLib__SequencerGracePeriod();
        }
    }

    /// @notice Check if the oracle price is stale.
    /// @param updatedAt The timestamp when the price was last updated.
    /// @param timeout The maximum age in seconds for a valid price.
    function checkStaleness(
        uint256 updatedAt,
        uint256 timeout
    ) internal view {
        if (updatedAt < block.timestamp - timeout) {
            revert OracleLib__StalePrice();
        }
    }

    /// @notice Check staleness relative to a specific reference timestamp instead of block.timestamp.
    /// @param updatedAt The timestamp when the price was last updated.
    /// @param timeout The maximum age in seconds for a valid price.
    /// @param referenceTime The timestamp to measure staleness against.
    function checkStalenessAt(
        uint256 updatedAt,
        uint256 timeout,
        uint256 referenceTime
    ) internal pure {
        if (updatedAt < referenceTime - timeout) {
            revert OracleLib__StalePrice();
        }
    }

    /// @notice Walks backwards through Chainlink rounds to find the price at a target timestamp.
    /// @param feed The Chainlink price feed.
    /// @param targetTimestamp The timestamp to look up the price for.
    /// @param maxTraversal Maximum number of rounds to walk backwards.
    /// @return price The price at the target timestamp.
    /// @return updatedAt The timestamp of the round found.
    function getHistoricalPrice(
        AggregatorV3Interface feed,
        uint256 targetTimestamp,
        uint256 maxTraversal
    ) internal view returns (int256 price, uint256 updatedAt) {
        (uint80 roundId, int256 latestPrice,, uint256 latestUpdatedAt,) = feed.latestRoundData();

        if (latestUpdatedAt <= targetTimestamp) {
            return (latestPrice, latestUpdatedAt);
        }

        for (uint256 i = 0; i < maxTraversal; i++) {
            if (roundId == 0) {
                break;
            }
            roundId--;

            try feed.getRoundData(roundId) returns (uint80, int256 p, uint256, uint256 u, uint80) {
                if (u <= targetTimestamp) {
                    return (p, u);
                }
            } catch {
                continue;
            }
        }

        revert OracleLib__NoPriceAtExpiry();
    }

    /// @notice Get a validated price from an oracle with staleness and sequencer checks.
    /// @param oracle The price oracle.
    /// @param sequencerFeed The sequencer uptime feed (can be address(0) to skip).
    /// @param gracePeriod The sequencer grace period in seconds.
    /// @param timeout The staleness timeout in seconds.
    /// @return price The validated price.
    /// @dev Reverts on zero or negative prices to prevent operations during oracle failures.
    function getValidatedPrice(
        AggregatorV3Interface oracle,
        AggregatorV3Interface sequencerFeed,
        uint256 gracePeriod,
        uint256 timeout
    ) internal view returns (uint256 price) {
        checkSequencer(sequencerFeed, gracePeriod);

        (, int256 rawPrice,, uint256 updatedAt,) = oracle.latestRoundData();

        checkStaleness(updatedAt, timeout);

        // Revert on invalid prices - broken oracle should halt operations
        if (rawPrice <= 0) {
            revert OracleLib__InvalidPrice();
        }

        return uint256(rawPrice);
    }

}
