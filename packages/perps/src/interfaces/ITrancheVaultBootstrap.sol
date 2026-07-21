// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Pool-facing bootstrap hooks implemented by tranche vaults.
interface ITrancheVaultBootstrap {

    /// @notice Previews shares minted for an asset amount under current vault pricing.
    /// @dev Uses the HousePool's simulated deposit-side reconcile state, deducts the active frozen-oracle LP fee when
    ///      applicable, and rounds down according to ERC4626 deposit-preview semantics.
    /// @param assets USDC asset amount to preview (6 decimals)
    /// @return shares Vault-share amount that would be minted
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Mints bootstrap shares after the pool has assigned matching principal.
    /// @dev Callable only by the bound HousePool. No assets move through the vault; the pool must already have assigned
    ///      matching tranche principal. Starts the receiver's withdrawal cooldown at the current timestamp.
    /// @param shares Vault shares to mint
    /// @param receiver Account receiving minted shares
    function bootstrapMint(
        uint256 shares,
        address receiver
    ) external;

    /// @notice Registers the permanent seed-share floor for a tranche.
    /// @dev Callable only by the bound HousePool. The receiver must already hold at least `floorShares`. After first
    ///      configuration the receiver cannot change and the floor cannot decrease; transfers and redemptions enforce it.
    /// @param receiver Nonzero seed owner account
    /// @param floorShares Positive minimum shares that must remain owned by the seed owner
    function configureSeedPosition(
        address receiver,
        uint256 floorShares
    ) external;

}
