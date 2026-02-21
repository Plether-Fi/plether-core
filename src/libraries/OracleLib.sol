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

    /// @notice Verifies a caller-provided hint round is the correct price at a target timestamp.
    /// @dev Avoids backward traversal that breaks on Chainlink phase boundaries.
    /// @param feed The Chainlink price feed.
    /// @param targetTimestamp The timestamp to look up the price for.
    /// @param hintRoundId The round ID that the caller claims was active at targetTimestamp.
    /// @return price The price at the target timestamp.
    /// @return updatedAt The timestamp of the round found.
    function verifyHistoricalPrice(
        AggregatorV3Interface feed,
        uint256 targetTimestamp,
        uint80 hintRoundId
    ) internal view returns (int256 price, uint256 updatedAt) {
        (uint80 latestRoundId, int256 latestPrice,, uint256 latestUpdatedAt,) = feed.latestRoundData();
        if (latestUpdatedAt <= targetTimestamp) {
            return (latestPrice, latestUpdatedAt);
        }

        (, int256 hintPrice,, uint256 hintUpdatedAt,) = feed.getRoundData(hintRoundId);
        if (hintUpdatedAt == 0 || hintUpdatedAt > targetTimestamp) {
            revert OracleLib__NoPriceAtExpiry();
        }

        uint16 hintPhase = uint16(hintRoundId >> 64);
        uint80 searchRoundId = hintRoundId + 1;
        bool foundNextValid = false;

        for (uint256 i = 0; i < 50; i++) {
            if (uint16(searchRoundId >> 64) != hintPhase) {
                break;
            }
            try feed.getRoundData(searchRoundId) returns (uint80, int256, uint256, uint256 nextUpdatedAt, uint80) {
                if (nextUpdatedAt != 0) {
                    if (nextUpdatedAt <= targetTimestamp) {
                        revert OracleLib__NoPriceAtExpiry();
                    }
                    foundNextValid = true;
                    break;
                }
            } catch {}
            searchRoundId++;
        }

        if (!foundNextValid) {
            uint16 latestPhase = uint16(latestRoundId >> 64);
            for (uint16 p = hintPhase + 1; p <= latestPhase && !foundNextValid; p++) {
                for (uint256 j = 1; j <= 50 && !foundNextValid; j++) {
                    uint80 phaseRound = (uint80(p) << 64) | uint80(j);
                    try feed.getRoundData(phaseRound) returns (uint80, int256, uint256, uint256 npUpdatedAt, uint80) {
                        if (npUpdatedAt != 0) {
                            if (npUpdatedAt <= targetTimestamp) {
                                revert OracleLib__NoPriceAtExpiry();
                            }
                            foundNextValid = true;
                        }
                    } catch {
                        continue;
                    }
                }
            }
        }

        if (!foundNextValid) {
            revert OracleLib__NoPriceAtExpiry();
        }

        return (hintPrice, hintUpdatedAt);
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
