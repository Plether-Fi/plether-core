// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Two-tranche USDC pool that acts as counterparty to CFD traders.
///         Senior tranche earns fixed yield; junior absorbs first-loss and excess profit.
interface IHousePool {

    /// @notice Total USDC attributed to the senior tranche (6 decimals)
    function seniorPrincipal() external view returns (uint256);
    /// @notice Total USDC attributed to the junior tranche (6 decimals)
    function juniorPrincipal() external view returns (uint256);

    function depositSenior(
        uint256 amount
    ) external;
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;
    function depositJunior(
        uint256 amount
    ) external;
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Max withdrawable by senior, capped by free USDC
    function getMaxSeniorWithdraw() external view returns (uint256);
    /// @notice Max withdrawable by junior, subordinated behind senior
    function getMaxJuniorWithdraw() external view returns (uint256);

    /// @notice Settles revenue/loss waterfall between tranches
    function reconcile() external;

    /// @notice Whether withdrawals are currently possible (not degraded, mark is fresh)
    function isWithdrawalLive() external view returns (bool);

}
