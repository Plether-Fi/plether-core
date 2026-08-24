// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice HousePool LP reservation surface used by the configured senior tranche vault.
/// @dev Settlement is coordinated separately through the Router-facing `IHousePool` entrypoints.
interface IPerpsLPActions {

    /// @notice Reserves governed senior capacity for a delayed deposit request.
    /// @param amount Gross USDC request amount to reserve (6 decimals)
    function reserveSeniorDeposit(
        uint256 amount
    ) external;

    /// @notice Releases governed senior capacity after a delayed request is cancelled.
    /// @param amount Gross USDC request amount to release (6 decimals)
    function releaseSeniorDepositReservation(
        uint256 amount
    ) external;

}
