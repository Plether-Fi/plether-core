// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC7540} from "@plether/perps/interfaces/IERC7540.sol";
import {IERC7575, IERC7575Share} from "@plether/perps/interfaces/IERC7575.sol";

/// @notice Public integration surface for a fully asynchronous Plether tranche vault.
/// @dev Standard ERC-7540 claims consume the controller's oldest outstanding request. A rejected deposit or refundable
///      redeem head must be cancelled or reclaimed before standard claims advance to a later request; explicit-id claim
///      methods preserve deterministic epoch selection for integrations. Claim operators require controller approval;
///      request authorization follows ERC-7540 owner approval rules. Claims pay from vault escrow and do not depend on
///      a later HousePool call. To prevent unsolicited dust from resetting an existing holder's whole-balance cooldown,
///      a share-delivering claim, cancellation, or refund may use a third-party receiver only when its share balance is
///      zero; self-receipt by the controller is always permitted. `maxDeposit` and `maxMint` are receiver-independent
///      controller limits and therefore do not certify that a particular third-party receiver is eligible.
interface IAsyncTrancheVault is IERC7540, IERC7575Share {

    /// @notice Returns the maximum underlying assets currently accepted for a new deposit request by `controller`.
    /// @dev This is a request-capacity view, not the ERC-7575 `maxDeposit` claim-capacity view.
    function maxRequestDeposit(
        address controller
    ) external view returns (uint256 maxAssets);

    /// @notice Returns the maximum shares currently accepted for a new redemption request from `owner`.
    /// @dev This is a request-capacity view, not the ERC-7575 `maxRedeem` claim-capacity view.
    function maxRequestRedeem(
        address owner
    ) external view returns (uint256 maxShares);

    /// @notice Estimates shares for a deposit amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewDeposit` to revert for an asynchronous deposit flow; integrations should use this
    ///      explicitly nonbinding estimate when presenting current indicative pricing.
    function estimateDepositShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Estimates assets for a target share amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewMint` to revert for an asynchronous deposit flow.
    function estimateMintAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Estimates shares for a target withdrawal amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewWithdraw` to revert for an asynchronous redemption flow.
    function estimateWithdrawShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Estimates assets for a redemption amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewRedeem` to revert for an asynchronous redemption flow; integrations should use
    ///      this explicitly nonbinding estimate when presenting current indicative pricing.
    function estimateRedeemAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Returns finalized shares available to claim from one deposit request.
    /// @dev Complements ERC-7540's asset-denominated `claimableDepositRequest` view.
    function claimableDepositShares(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    /// @notice Returns rejected deposit assets available to recover through cancellation.
    /// @dev Complements ERC-7540's pending/claimable states for a terminal request rejected at settlement.
    function refundableDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    /// @notice Returns funded assets available to claim from one redemption request.
    /// @dev Complements ERC-7540's share-denominated `claimableRedeemRequest` view.
    function claimableRedeemAssets(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    /// @notice Returns unburned shares available to reclaim after settlement rejects a zero-output redeem remainder.
    /// @dev A refundable remainder is terminal and no longer participates in the funding queue. Previously funded
    ///      assets for the same request remain independently claimable through the redemption claim surface.
    function refundableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    /// @notice Whether a terminal redeem refund still requires acknowledgement by this controller.
    /// @dev May be true when `refundableRedeemRequest` is zero because pro-rata rounding assigned no return shares.
    function redeemRefundPending(
        uint256 requestId,
        address controller
    ) external view returns (bool pending);

    /// @notice Claims a specified asset amount from one finalized deposit request.
    /// @param requestId Deposit request epoch to claim.
    /// @param assets Claimable contribution basis to consume.
    /// @param receiver Account receiving vault shares.
    /// @param controller Account controlling the request.
    /// @return shares Vault shares transferred from claim escrow.
    function claimDeposit(
        uint256 requestId,
        uint256 assets,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    /// @notice Claims a specified share amount from one funded redemption request.
    /// @param requestId Redemption request epoch to claim.
    /// @param shares Claimable request shares to consume.
    /// @param receiver Account receiving underlying assets.
    /// @param controller Account controlling the request.
    /// @return assets Underlying assets transferred from claim escrow.
    function claimRedeem(
        uint256 requestId,
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets);

    /// @notice Reclaims all of a controller's unburned shares after a zero-output redeem remainder is rejected.
    /// @dev This is a settlement refund, not voluntary cancellation. The caller must be the controller or its
    ///      approved operator. A nonzero share return restarts the receiver's transfer cooldown; a zero-share
    ///      acknowledgement advances terminal accounting without changing any cooldown.
    /// @param requestId Redemption request epoch containing the refundable remainder.
    /// @param receiver Account receiving the returned vault shares.
    /// @param controller Account controlling the request.
    /// @return shares Vault shares returned from request escrow.
    function claimRedeemRefund(
        uint256 requestId,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    /// @notice Cancels a pending deposit request and returns its escrowed assets.
    /// @param requestId Pending deposit request epoch to cancel.
    /// @param receiver Account receiving the refunded underlying assets.
    /// @param controller Account controlling the request.
    /// @return assets Underlying assets returned from request escrow.
    function cancelPendingDeposit(
        uint256 requestId,
        address receiver,
        address controller
    ) external returns (uint256 assets);

    /// @notice Cancels a pending, unmatured, and wholly unfunded redemption request.
    /// @param requestId Pending redemption request epoch to cancel.
    /// @param receiver Account receiving the returned vault shares.
    /// @param controller Account controlling the request.
    /// @return shares Vault shares returned from request escrow.
    function cancelRedeemRequest(
        uint256 requestId,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    /// @notice Compatibility wrapper that requests a deposit funded by the caller and controlled by `receiver`.
    function requestDeposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 requestId);

    /// @notice Compatibility wrapper that cancels the caller's complete pending balance for `requestId`.
    function cancelPendingDeposit(
        uint256 requestId
    ) external returns (uint256 assets);

    /// @notice Compatibility wrapper that claims the caller's complete deposit balance for `requestId`.
    function claimDepositShares(
        uint256 requestId
    ) external returns (uint256 shares);

}
