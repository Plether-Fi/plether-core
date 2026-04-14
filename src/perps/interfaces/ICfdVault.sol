// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Vault that custodies USDC backing the CFD trading system.
interface ICfdVault {

    enum ClaimantInflowKind {
        Revenue,
        Recapitalization
    }

    enum ClaimantInflowCashMode {
        CashArrived,
        AlreadyRetained
    }

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

    /// @notice Records claimant-owned value that should ultimately flow through the tranche waterfall.
    /// @dev `CashArrived` increments canonical accounted assets because raw USDC arrived in this flow.
    ///      `AlreadyRetained` only routes ownership for value already retained physically by the vault.
    function recordClaimantInflow(
        uint256 amount,
        ClaimantInflowKind kind,
        ClaimantInflowCashMode cashMode
    ) external;

    /// @notice Maximum age for mark price freshness checks outside FAD mode (seconds)
    function markStalenessLimit() external view returns (uint256);

    /// @notice Returns true once both tranche seed positions exist.
    function isSeedLifecycleComplete() external view returns (bool);

    /// @notice Returns true if bootstrap seeding has started for either tranche.
    function hasSeedLifecycleStarted() external view returns (bool);

    /// @notice Returns true once ordinary LP deposits are allowed.
    function canAcceptOrdinaryDeposits() external view returns (bool);

    /// @notice Returns true once risk-increasing trader actions are allowed.
    function canIncreaseRisk() external view returns (bool);

    /// @notice Returns true if owner has activated trading after seed completion.
    function isTradingActive() external view returns (bool);

}
