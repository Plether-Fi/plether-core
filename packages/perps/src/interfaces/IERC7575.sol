// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice ERC-7575 vault entry-point interface: ERC-4626 without the inherited ERC-20 surface, plus `share()`.
/// @dev Implementations must report support for the canonical ERC-7575 interface id `0x2f0a18c5` and ERC-165.
///      A single-token ERC-4626-compatible vault may return its own address from `share()`.
interface IERC7575 is IERC165 {

    /// @notice Emitted when assets enter the vault and shares are assigned to `receiver`.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when shares are consumed and assets are assigned to `receiver`.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Returns the ERC-20 token representing shares in this vault.
    function share() external view returns (address shareTokenAddress);

    /// @notice Returns the underlying asset token used by this vault entry point.
    function asset() external view returns (address assetTokenAddress);

    /// @notice Returns the total underlying assets managed by this vault entry point.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Converts an asset amount to shares without applying caller-specific limits.
    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Converts a share amount to assets without applying caller-specific limits.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Returns the maximum assets that `receiver` may deposit through the synchronous or claim surface.
    function maxDeposit(
        address receiver
    ) external view returns (uint256 maxAssets);

    /// @notice Previews shares returned for a deposit when the active flow permits previews.
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Deposits or claims `assets` for `receiver`, depending on the active vault flow.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Returns the maximum shares that `receiver` may mint through the synchronous or claim surface.
    function maxMint(
        address receiver
    ) external view returns (uint256 maxShares);

    /// @notice Previews assets required to mint shares when the active flow permits previews.
    function previewMint(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Mints or claims `shares` for `receiver`, depending on the active vault flow.
    function mint(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    /// @notice Returns the maximum assets withdrawable for `owner` through the synchronous or claim surface.
    function maxWithdraw(
        address owner
    ) external view returns (uint256 maxAssets);

    /// @notice Previews shares consumed by a withdrawal when the active flow permits previews.
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Withdraws or claims `assets` from `owner` or its asynchronous controller.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /// @notice Returns the maximum shares redeemable for `owner` through the synchronous or claim surface.
    function maxRedeem(
        address owner
    ) external view returns (uint256 maxShares);

    /// @notice Previews assets returned by redemption when the active flow permits previews.
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Redeems or claims `shares` from `owner` or its asynchronous controller.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

}

/// @notice ERC-7575 share-token lookup fragment for mapping an asset back to its vault entry point.
/// @dev Share tokens implementing this optional fragment report interface id `0xf815c03d` through ERC-165.
interface IERC7575Share is IERC165 {

    /// @notice Emitted if the vault linked to an asset changes.
    event VaultUpdate(address indexed asset, address vault);

    /// @notice Returns the vault entry point associated with `asset`, or the zero address if none is configured.
    function vault(
        address asset
    ) external view returns (address vaultAddress);

}
