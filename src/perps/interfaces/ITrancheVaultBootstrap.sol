// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Pool-facing bootstrap hooks implemented by tranche vaults.
interface ITrancheVaultBootstrap {

    /// @notice Previews shares minted for an asset amount under current vault pricing.
    /// @param assets USDC asset amount to preview
    /// @return shares Vault shares that would be minted
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Mints bootstrap shares after the pool has assigned matching principal.
    /// @param shares Shares to mint
    /// @param receiver Account receiving minted shares
    function bootstrapMint(
        uint256 shares,
        address receiver
    ) external;

    /// @notice Registers the permanent seed-share floor for a tranche.
    /// @param receiver Seed owner account
    /// @param floorShares Minimum shares that must remain owned by the seed owner
    function configureSeedPosition(
        address receiver,
        uint256 floorShares
    ) external;

}
