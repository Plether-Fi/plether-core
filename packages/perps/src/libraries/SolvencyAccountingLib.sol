// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title SolvencyAccountingLib
/// @notice Computes the perps pool's side-liability envelope, effective assets, and degraded-mode previews.
/// @dev All monetary values use 6-decimal settlement token. Negative asset or trader-claim deltas use saturating subtraction;
///      positive deltas use checked addition. Solvency requires effective assets to be at least maximum liability.
library SolvencyAccountingLib {

    uint256 internal constant BPS = 10_000;

    /// @notice Planned changes used to preview solvency after an operation.
    /// @param physicalAssetsDeltaAssets Signed change to physical pool assets.
    /// @param maxLiabilityAfterAssets Absolute maximum side-liability envelope after the operation.
    /// @param traderClaimDeltaAssets Signed change to outstanding trader-claim liabilities.
    /// @param pendingPoolPayoutAssets Additional payout reserved from effective assets but not included in the physical
    ///        asset delta.
    struct PreviewDelta {
        int256 physicalAssetsDeltaAssets;
        uint256 maxLiabilityAfterAssets;
        int256 traderClaimDeltaAssets;
        uint256 pendingPoolPayoutAssets;
    }

    /// @notice Solvency values and degraded-mode flags after a previewed operation.
    /// @param effectiveAssetsAfterAssets Physical assets net of trader claims and pending payout, floored at zero.
    /// @param maxLiabilityAfterAssets Maximum remaining LONG/SHORT liability envelope.
    /// @param triggersDegradedMode Whether `alreadyDegraded` was false and projected effective assets are below liability;
    ///        callers must keep that flag consistent with pre-operation solvency.
    /// @param postOpDegradedMode Whether projected effective assets are below projected maximum liability.
    struct PreviewResult {
        uint256 effectiveAssetsAfterAssets;
        uint256 maxLiabilityAfterAssets;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
    }

    /// @notice Current pool asset, liability, reservation, and free-withdrawal accounting.
    /// @param physicalAssets Canonical physical pool assets.
    /// @param netPhysicalAssets Physical assets used for effective-asset accounting; currently copied directly
    ///        from `physicalAssets` by `buildSolvencyState`.
    /// @param maxLiabilityAssets Larger directional maximum-profit envelope.
    /// @param traderClaimBalanceAssets Outstanding trader claims senior to LP liability coverage.
    /// @param withdrawalReservedAssets Sum of maximum liability and trader claims.
    /// @param freeWithdrawableAssets Physical assets above the withdrawal reservation, floored at zero.
    /// @param effectiveAssets Net physical assets after trader claims, floored at zero.
    struct SolvencyState {
        uint256 physicalAssets;
        uint256 netPhysicalAssets;
        uint256 maxLiabilityAssets;
        uint256 traderClaimBalanceAssets;
        uint256 withdrawalReservedAssets;
        uint256 freeWithdrawableAssets;
        uint256 effectiveAssets;
    }

    /// @notice Returns the larger LONG or SHORT maximum-profit envelope.
    /// @param longMaxProfitAssets Aggregate LONG-side maximum-profit liability.
    /// @param shortMaxProfitAssets Aggregate SHORT-side maximum-profit liability.
    /// @return Maximum of the two liabilities; equal inputs return that common value.
    function getMaxLiability(
        uint256 longMaxProfitAssets,
        uint256 shortMaxProfitAssets
    ) internal pure returns (uint256) {
        return longMaxProfitAssets > shortMaxProfitAssets ? longMaxProfitAssets : shortMaxProfitAssets;
    }

    /// @notice Returns the protected settlement headroom required for a maximum directional liability.
    /// @dev Rounds up so every nonzero liability and nonzero rate reserves at least one settlement token atom. A zero liability or
    ///      zero rate returns zero. This buffer is an admission and withdrawal constraint, not an economic liability.
    /// @param maxLiabilityAssets Current or projected maximum directional liability.
    /// @param settlementBufferBps Settlement-buffer rate with a 10,000 basis-point denominator.
    /// @return bufferAssets Required protected headroom in 6-decimal settlement token units.
    function settlementBufferTargetAssets(
        uint256 maxLiabilityAssets,
        uint256 settlementBufferBps
    ) internal pure returns (uint256 bufferAssets) {
        if (maxLiabilityAssets == 0 || settlementBufferBps == 0) {
            return 0;
        }
        return Math.mulDiv(maxLiabilityAssets, settlementBufferBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Tests whether raw solvency headroom covers the configured settlement buffer.
    /// @dev The subtraction form avoids overflowing `maxLiabilityAssets + buffer`. Equality passes.
    /// @param effectiveAssets Physical pool assets net of outstanding trader claims.
    /// @param maxLiabilityAssets Current or projected maximum directional liability.
    /// @param settlementBufferBps Settlement-buffer rate with a 10,000 basis-point denominator.
    /// @return True when effective assets cover both liability and protected headroom.
    function hasRequiredSettlementBuffer(
        uint256 effectiveAssets,
        uint256 maxLiabilityAssets,
        uint256 settlementBufferBps
    ) internal pure returns (bool) {
        if (effectiveAssets < maxLiabilityAssets) {
            return false;
        }
        return
            effectiveAssets - maxLiabilityAssets
                >= settlementBufferTargetAssets(maxLiabilityAssets, settlementBufferBps);
    }

    /// @notice Returns maximum liability after reducing one side's maximum-profit envelope for a close.
    /// @dev Reverts on subtraction underflow if `maxProfitReductionAssets` exceeds the selected side's envelope.
    /// @param longMaxProfitAssets LONG-side maximum-profit liability before the close.
    /// @param shortMaxProfitAssets SHORT-side maximum-profit liability before the close.
    /// @param side Side whose position liability is being reduced.
    /// @param maxProfitReductionAssets Amount removed from the selected side's envelope.
    /// @return Remaining maximum of the two side liabilities.
    function getMaxLiabilityAfterClose(
        uint256 longMaxProfitAssets,
        uint256 shortMaxProfitAssets,
        CfdTypes.Side side,
        uint256 maxProfitReductionAssets
    ) internal pure returns (uint256) {
        if (side == CfdTypes.Side.LONG) {
            longMaxProfitAssets -= maxProfitReductionAssets;
        } else {
            shortMaxProfitAssets -= maxProfitReductionAssets;
        }
        return getMaxLiability(longMaxProfitAssets, shortMaxProfitAssets);
    }

    /// @notice Builds current solvency and withdrawal-reservation accounting.
    /// @dev Both free withdrawal and effective assets saturate at zero. The reservation sum uses checked addition.
    /// @param physicalAssets Canonical physical pool assets.
    /// @param maxLiabilityAssets Current maximum directional liability envelope.
    /// @param traderClaimBalanceAssets Outstanding trader claims senior to LP value.
    /// @return state Physical/effective assets, reservations, free withdrawal, and liabilities.
    function buildSolvencyState(
        uint256 physicalAssets,
        uint256 maxLiabilityAssets,
        uint256 traderClaimBalanceAssets
    ) internal pure returns (SolvencyState memory state) {
        state.physicalAssets = physicalAssets;
        state.netPhysicalAssets = physicalAssets;
        state.maxLiabilityAssets = maxLiabilityAssets;
        state.traderClaimBalanceAssets = traderClaimBalanceAssets;

        state.withdrawalReservedAssets = maxLiabilityAssets + traderClaimBalanceAssets;
        state.freeWithdrawableAssets =
            physicalAssets > state.withdrawalReservedAssets ? physicalAssets - state.withdrawalReservedAssets : 0;
        state.effectiveAssets =
            state.netPhysicalAssets > traderClaimBalanceAssets ? state.netPhysicalAssets - traderClaimBalanceAssets : 0;
    }

    /// @notice Reserves a pending pool payout from current effective assets.
    /// @dev Subtraction saturates at zero. A zero pending payout returns the stored effective asset value unchanged.
    /// @param state Current solvency state.
    /// @param pendingPoolPayoutAssets Payout not otherwise reflected in physical assets.
    /// @return Effective assets after reserving the payout.
    function effectiveAssetsAfterPendingPayout(
        SolvencyState memory state,
        uint256 pendingPoolPayoutAssets
    ) internal pure returns (uint256) {
        if (pendingPoolPayoutAssets == 0) {
            return state.effectiveAssets;
        }
        return state.effectiveAssets > pendingPoolPayoutAssets ? state.effectiveAssets - pendingPoolPayoutAssets : 0;
    }

    /// @notice Previews effective assets, maximum liability, and degraded-mode state after an operation.
    /// @dev Negative physical-asset and trader-claim deltas saturate at zero. The pending payout is deducted after
    ///      rebuilding state and does not alter the previewed physical-asset field. `alreadyDegraded` affects only
    ///      `triggersDegradedMode`, not the post-operation insolvency test. Negating `type(int256).min` reverts.
    /// @param currentState Current pool solvency accounting.
    /// @param delta Planned physical-asset, liability, trader-claim, and pending-payout changes.
    /// @param alreadyDegraded Whether degraded mode was active before the operation.
    /// @return result Projected effective assets, liability, and degraded-mode transition flags.
    function previewPostOpSolvency(
        SolvencyState memory currentState,
        PreviewDelta memory delta,
        bool alreadyDegraded
    ) internal pure returns (PreviewResult memory result) {
        uint256 physicalAssetsAfterAssets = currentState.physicalAssets;
        if (delta.physicalAssetsDeltaAssets > 0) {
            physicalAssetsAfterAssets += uint256(delta.physicalAssetsDeltaAssets);
        } else if (delta.physicalAssetsDeltaAssets < 0) {
            uint256 debitAssets = uint256(-delta.physicalAssetsDeltaAssets);
            physicalAssetsAfterAssets =
                physicalAssetsAfterAssets > debitAssets ? physicalAssetsAfterAssets - debitAssets : 0;
        }

        uint256 traderClaimBalanceAfterAssets =
            _applySignedDelta(currentState.traderClaimBalanceAssets, delta.traderClaimDeltaAssets);

        SolvencyState memory afterState =
            buildSolvencyState(physicalAssetsAfterAssets, delta.maxLiabilityAfterAssets, traderClaimBalanceAfterAssets);

        result.maxLiabilityAfterAssets = afterState.maxLiabilityAssets;
        result.effectiveAssetsAfterAssets = effectiveAssetsAfterPendingPayout(afterState, delta.pendingPoolPayoutAssets);
        result.postOpDegradedMode = result.effectiveAssetsAfterAssets < result.maxLiabilityAfterAssets;
        result.triggersDegradedMode = !alreadyDegraded && result.postOpDegradedMode;
    }

    /// @notice Applies a signed delta to an unsigned value with saturating subtraction.
    /// @dev Positive changes use checked addition. Negative changes floor at zero; `type(int256).min` cannot be negated.
    /// @param value Starting unsigned value.
    /// @param delta Signed change to apply.
    /// @return updatedValue Result after checked addition or saturating subtraction.
    function _applySignedDelta(
        uint256 value,
        int256 delta
    ) private pure returns (uint256 updatedValue) {
        updatedValue = value;
        if (delta > 0) {
            updatedValue += uint256(delta);
        } else if (delta < 0) {
            uint256 decrease = uint256(-delta);
            updatedValue = updatedValue > decrease ? updatedValue - decrease : 0;
        }
    }

}
