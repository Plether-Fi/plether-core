// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Pool-facing bootstrap hooks implemented by tranche vaults.
interface ITrancheVaultBootstrap {

    /// @notice Quotes bootstrap shares for an asset amount under current vault pricing.
    /// @dev Dedicated bootstrap hook because an asynchronous ERC-7540 vault's public `previewDeposit` must revert. Uses
    ///      the HousePool's simulated deposit-side reconcile state and rounds down according to fee-free deposit
    ///      conversion semantics. Bootstrap callers separately require the oracle not to be frozen.
    /// @param assets USDC asset amount to quote (6 decimals)
    /// @return shares Vault-share amount that would be minted
    function quoteBootstrapDeposit(
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
