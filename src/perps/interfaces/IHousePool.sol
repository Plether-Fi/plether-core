// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Two-tranche USDC pool that acts as counterparty to CFD traders.
///         Senior tranche earns fixed yield; junior absorbs first-loss and excess profit.
interface IHousePool {

    /// @notice Total USDC attributed to the senior tranche (6 decimals)
    function seniorPrincipal() external view returns (uint256);
    /// @notice Total USDC attributed to the junior tranche (6 decimals)
    function juniorPrincipal() external view returns (uint256);
    /// @notice Senior high-water mark used to block dilutive recapitalizing deposits.
    function seniorHighWaterMark() external view returns (uint256);
    /// @notice Accounted LP assets currently quarantined pending explicit bootstrap / assignment (6 decimals)
    function unassignedAssets() external view returns (uint256);

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

    /// @notice Explicitly bootstraps quarantined LP assets into a tranche and mints matching shares.
    function assignUnassignedAssets(bool toSenior, address receiver) external;

    /// @notice Seeds a tranche with permanent share-backed minimum ownership using real USDC.
    /// @dev Canonical deployment should initialize both tranche seeds before enabling ordinary LP lifecycle.
    function initializeSeedPosition(bool toSenior, uint256 amount, address receiver) external;

    /// @notice Max withdrawable by senior, capped by free USDC
    function getMaxSeniorWithdraw() external view returns (uint256);
    /// @notice Max withdrawable by junior, subordinated behind senior
    function getMaxJuniorWithdraw() external view returns (uint256);

    /// @notice Read-only tranche state as if `reconcile()` ran immediately with current inputs.
    /// @return seniorPrincipalUsdc Simulated senior principal after reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after reconcile (6 decimals)
    /// @return maxSeniorWithdrawUsdc Simulated senior withdrawal cap after reconcile (6 decimals)
    /// @return maxJuniorWithdrawUsdc Simulated junior withdrawal cap after reconcile (6 decimals)
    function getPendingTrancheState()
        external
        view
        returns (
            uint256 seniorPrincipalUsdc,
            uint256 juniorPrincipalUsdc,
            uint256 maxSeniorWithdrawUsdc,
            uint256 maxJuniorWithdrawUsdc
        );

    /// @notice Settles revenue/loss waterfall between tranches
    function reconcile() external;

    /// @notice Whether withdrawals are currently possible (not degraded, mark is fresh)
    function isWithdrawalLive() external view returns (bool);

    function hasSeedLifecycleStarted() external view returns (bool);

    function canAcceptOrdinaryDeposits() external view returns (bool);

    function canIncreaseRisk() external view returns (bool);

    function isTradingActive() external view returns (bool);

}
