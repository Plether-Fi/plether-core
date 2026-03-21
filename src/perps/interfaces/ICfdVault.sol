// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Vault that custodies USDC backing the CFD trading system.
interface ICfdVault {

    /// @notice Canonical economic USDC backing recognized by the vault (6 decimals).
    ///         Ignores unsolicited positive token transfers until explicitly accounted, but
    ///         still reflects raw-balance shortfalls if assets leave the vault unexpectedly.
    function totalAssets() external view returns (uint256);
    /// @notice Transfers USDC from the vault to a recipient
    /// @param recipient Address to receive USDC
    /// @param amount    USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external;

    /// @notice Increases canonical vault assets to recognize a legitimate protocol-owned inflow.
    /// @dev This is the controlled accounting path for endogenous protocol gains that should
    ///      increase economic vault depth. It does not require raw excess to be present and may
    ///      also be used to restore canonical accounting after a raw-balance shortfall has already
    ///      reduced `totalAssets()` via the `min(rawBalance, accountedAssets)` boundary.
    ///      Reverts if the caller is unauthorized.
    function recordProtocolInflow(
        uint256 amount
    ) external;

    /// @notice Records an explicit recapitalization inflow intended to restore senior first.
    function recordRecapitalizationInflow(uint256 amount) external;

    /// @notice Records LP-owned trading revenue and directly attaches it to seeded claimants when both tranches are otherwise at zero principal.
    function recordTradingRevenueInflow(uint256 amount) external;

    /// @notice Maximum age for mark price freshness checks outside FAD mode (seconds)
    function markStalenessLimit() external view returns (uint256);

    /// @notice Returns true once both tranche seed positions exist.
    function isSeedLifecycleComplete() external view returns (bool);

    /// @notice Returns true if bootstrap seeding has started for either tranche.
    function hasSeedLifecycleStarted() external view returns (bool);

    /// @notice Returns true if owner has activated trading after seed completion.
    function isTradingActive() external view returns (bool);

}
