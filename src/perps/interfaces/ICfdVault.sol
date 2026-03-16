// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Vault that custodies USDC backing the CFD trading system.
interface ICfdVault {

    /// @notice Total USDC held by the vault (6 decimals)
    function totalAssets() external view returns (uint256);
    /// @notice Transfers USDC from the vault to a recipient
    /// @param recipient Address to receive USDC
    /// @param amount    USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external;

    /// @notice Maximum age for mark price freshness checks outside FAD mode (seconds)
    function markStalenessLimit() external view returns (uint256);

}
