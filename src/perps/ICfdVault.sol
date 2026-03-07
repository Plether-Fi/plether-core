// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICfdVault {

    /// @notice Total USDC held by the vault (6 decimals)
    function totalAssets() external view returns (uint256);
    /// @notice Transfers USDC from the vault to a recipient
    function payOut(
        address recipient,
        uint256 amount
    ) external;

}
