// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Keeper-facing execution and liquidation surface for the simplified product API.
interface IPerpsKeeper {

    /// @notice Executes the next eligible delayed order using fresh oracle data.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Executes a bounded batch of eligible delayed orders using a shared oracle update.
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable;

    /// @notice Liquidates an unsafe account using fresh oracle data.
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable;

}
