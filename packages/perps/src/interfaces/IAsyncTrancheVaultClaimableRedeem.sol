// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Additive interface for routing finalized deposit shares directly into asynchronous redemption.
/// @dev This extension deliberately remains separate from `IAsyncTrancheVault` so its existing ERC-165 interface id
///      remains stable. The source deposit controller also controls the resulting redemption request.
interface IAsyncTrancheVaultClaimableRedeem {

    /// @notice Emitted when finalized deposit entitlement is consumed into a new or existing redemption request.
    /// @param controller Controller shared by the source deposit and destination redemption positions.
    /// @param depositRequestId Finalized deposit request whose entitlement supplied the shares.
    /// @param redeemRequestId Current redemption request epoch that received the shares.
    /// @param sender Controller or approved operator that submitted the request.
    /// @param assets Consumed contribution basis associated with `shares`.
    /// @param shares Vault shares routed between the two escrow classifications.
    event ClaimableDepositRedeemRequest(
        address indexed controller,
        uint256 indexed depositRequestId,
        uint256 indexed redeemRequestId,
        address sender,
        uint256 assets,
        uint256 shares
    );

    /// @notice Timestamp when a finalized deposit request became active pool capital.
    /// @return activationTime Successful settlement time, or zero while the request has not been activated.
    function depositEpochActivationTime(
        uint256 requestId
    ) external view returns (uint256 activationTime);

    /// @notice Finalized shares from one deposit request currently eligible for direct redemption.
    /// @dev Returns zero until the source request's activation-aged deposit cooldown has elapsed.
    function maxRequestRedeemFromClaimableDeposit(
        uint256 depositRequestId,
        address controller
    ) external view returns (uint256 maxShares);

    /// @notice Routes finalized deposit shares directly from claim escrow into the current redemption request.
    /// @dev No ERC-20 share transfer occurs. The caller must be `controller` or its approved operator, and the
    ///      destination redemption request remains controlled by `controller`.
    function requestRedeemFromClaimableDeposit(
        uint256 depositRequestId,
        uint256 shares,
        address controller
    ) external returns (uint256 redeemRequestId);

}
