// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title AggregatorV3Interface
/// @notice Chainlink price feed interface.
/// @dev Standard interface for Chainlink oracles. See https://docs.chain.link/data-feeds.
interface AggregatorV3Interface {
    /// @notice Returns the number of decimals in the price.
    function decimals() external view returns (uint8);

    /// @notice Returns a human-readable description of the feed.
    function description() external view returns (string memory);

    /// @notice Returns the feed version number.
    function version() external view returns (uint256);

    /// @notice Returns historical round data.
    /// @param _roundId The round ID to query.
    /// @return roundId The round ID.
    /// @return answer The price answer.
    /// @return startedAt Timestamp when round started.
    /// @return updatedAt Timestamp of last update.
    /// @return answeredInRound The round in which answer was computed.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Returns the latest round data.
    /// @return roundId The current round ID.
    /// @return answer The latest price.
    /// @return startedAt Timestamp when round started.
    /// @return updatedAt Timestamp of last update.
    /// @return answeredInRound The round in which answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
