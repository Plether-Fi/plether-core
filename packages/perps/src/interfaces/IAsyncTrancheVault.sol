// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC7540} from "@plether/perps/interfaces/IERC7540.sol";
import {IERC7575, IERC7575Share} from "@plether/perps/interfaces/IERC7575.sol";

/// @notice Public integration surface for a fully asynchronous Plether tranche vault.
/// @dev Standard ERC-7540 claims consume the controller's oldest outstanding request. A rejected deposit or refundable
///      redeem head must be cancelled or reclaimed before standard claims advance to a later request; explicit-id claim
///      methods preserve deterministic epoch selection for integrations. Claim operators require controller approval;
///      request authorization follows ERC-7540 owner approval rules. Claims pay from vault escrow and do not depend on
///      a later HousePool call. Deposit claims and redemption cancellations/refunds require receiver == controller,
///      including zero-share acknowledgements, so share delivery cannot impose another account's cooldown or depend
///      on an unsolicited receiver balance. Approved operators may execute these actions for the controller.
///      All four ERC-7575 `max*` claim views take the request controller. Deposit/mint receivers must still be that
///      controller; funded redemption assets may be sent to another receiver. The custom interface id is `0xa4fc3325`;
///      implementations also retain support for the previous custom interface id `0x8f61af3a`.
interface IAsyncTrancheVault is IERC7540, IERC7575Share {

    /// @notice Returns the epoch currently targeted by new requests and the timestamp when that target next changes.
    /// @dev The cutoff timestamp is always in the future. At the exact cutoff, both values roll forward together.
    ///      Deposit and redemption requests use this same window.
    function getRequestEpochWindow() external view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);

    /// @notice Returns the maximum underlying assets currently accepted for a new deposit request by `controller`.
    /// @dev Returns zero for the zero controller. This is a request-capacity view, not the ERC-7575 `maxDeposit`
    ///      claim-capacity view. A request must also satisfy the minimum amount, funding and owner authorization.
    function maxRequestDeposit(
        address controller
    ) external view returns (uint256 maxAssets);

    /// @notice Returns the maximum shares currently accepted for a new redemption request from `owner`.
    /// @dev This is a request-capacity view, not the ERC-7575 `maxRedeem` claim-capacity view. Smaller requests must
    ///      meet the minimum estimated asset value; redeeming this owner's entire available balance permits dust exits.
    function maxRequestRedeem(
        address owner
    ) external view returns (uint256 maxShares);

    /// @notice Estimates shares for a deposit amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewDeposit` to revert for an asynchronous deposit flow; integrations should use this
    ///      explicitly nonbinding estimate when presenting current indicative pricing. Returns zero when projected
    ///      deposit-pricing assets are zero with surviving shares. The request minimum and other admission/settlement
    ///      gates are not encoded; a nonzero quote does not imply the amount can be requested, and
    ///      accepted Senior reservations retain an estimate even when new-deposit capacity is exhausted.
    function estimateDepositShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Estimates assets for a target share amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewMint` to revert for an asynchronous deposit flow. This conversion does not
    ///      enforce the deposit-request minimum or other admission/settlement gates.
    function estimateMintAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Estimates shares for a target withdrawal amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewWithdraw` to revert for an asynchronous redemption flow. This conversion
    ///      includes the active frozen-oracle fee but does not check owner balances, cooldowns or request minimums.
    function estimateWithdrawShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Estimates assets for a redemption amount using current pricing without promising a claim result.
    /// @dev ERC-7540 requires `previewRedeem` to revert for an asynchronous redemption flow; integrations should use
    ///      this explicitly nonbinding estimate when presenting current indicative pricing. Includes the active
    ///      frozen-oracle fee but does not enforce request minimums or owner-specific eligibility. A below-minimum
    ///      request is allowed only when redeeming the owner's entire available balance.
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

    /// @notice Cancels a Junior request or refunds a Senior commitment during a settlement hold or safety exception.
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

    /// @notice Compatibility wrapper that cancels the caller's complete pending redemption request.
    /// @dev The caller is the controller and `receiver` must equal the caller. The request must be unmatured and
    ///      wholly unfunded, as for the three-argument overload.
    function cancelRedeemRequest(
        uint256 requestId,
        address receiver
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
