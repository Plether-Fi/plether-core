// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice LP-facing senior/junior tranche action surface.
interface IPerpsLPActions {

    /// @notice Deposits USDC into the senior tranche.
    /// @param amount USDC amount to deposit
    function depositSenior(
        uint256 amount
    ) external;

    /// @notice Withdraws USDC from the senior tranche.
    /// @param amount USDC amount to withdraw
    /// @param receiver Address receiving withdrawn USDC
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Deposits USDC into the junior tranche.
    /// @param amount USDC amount to deposit
    function depositJunior(
        uint256 amount
    ) external;

    /// @notice Withdraws USDC from the junior tranche.
    /// @param amount USDC amount to withdraw
    /// @param receiver Address receiving withdrawn USDC
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

}
