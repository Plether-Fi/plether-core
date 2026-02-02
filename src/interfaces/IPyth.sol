// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title Pyth Price Structs
library PythStructs {

    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

}

/// @title Pyth Network Interface (minimal)
/// @notice Minimal interface for reading Pyth price feeds.
interface IPyth {

    /// @notice Returns the price without staleness checks.
    /// @param id The Pyth price feed ID.
    /// @return price The price data.
    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the price if it's no older than `age` seconds.
    /// @param id The Pyth price feed ID.
    /// @param age Maximum acceptable age in seconds.
    /// @return price The price data.
    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view returns (PythStructs.Price memory price);

    /// @notice Updates price feeds with signed data from Pyth.
    /// @param updateData Array of price update data.
    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable;

    /// @notice Returns the fee required to update price feeds.
    /// @param updateData Array of price update data.
    /// @return feeAmount The required fee in wei.
    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256 feeAmount);

}
