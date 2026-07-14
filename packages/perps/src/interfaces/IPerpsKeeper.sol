// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Keeper-facing execution and liquidation surface for the simplified product API.
interface IPerpsKeeper {

    /// @notice Executes the next eligible delayed order using fresh oracle data.
    /// @param orderId Order id that must match the current global queue head
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Executes a bounded batch of eligible delayed orders using a shared oracle update.
    /// @param maxOrderId Inclusive upper bound on committed order ids the batch may begin processing from
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Liquidates an unsafe account using fresh oracle data.
    /// @param account Account to liquidate
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable;

}
