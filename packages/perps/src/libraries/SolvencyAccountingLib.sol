// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title SolvencyAccountingLib
/// @notice Computes the perps pool's side-liability envelope, effective assets, and degraded-mode previews.
/// @dev All monetary values use 6-decimal USDC. Negative asset or trader-claim deltas use saturating subtraction;
///      positive deltas use checked addition. Solvency requires effective assets to be at least maximum liability.
library SolvencyAccountingLib {

    /// @notice Planned changes used to preview solvency after an operation.
    /// @param physicalAssetsDeltaUsdc Signed change to physical pool assets.
    /// @param maxLiabilityAfterUsdc Absolute maximum side-liability envelope after the operation.
    /// @param traderClaimDeltaUsdc Signed change to outstanding trader-claim liabilities.
    /// @param pendingPoolPayoutUsdc Additional payout reserved from effective assets but not included in the physical
    ///        asset delta.
    struct PreviewDelta {
        int256 physicalAssetsDeltaUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 traderClaimDeltaUsdc;
        uint256 pendingPoolPayoutUsdc;
    }

    /// @notice Solvency values and degraded-mode flags after a previewed operation.
    /// @param effectiveAssetsAfterUsdc Physical assets net of trader claims and pending payout, floored at zero.
    /// @param maxLiabilityAfterUsdc Maximum remaining BULL/BEAR liability envelope.
    /// @param triggersDegradedMode Whether `alreadyDegraded` was false and projected effective assets are below liability;
    ///        callers must keep that flag consistent with pre-operation solvency.
    /// @param postOpDegradedMode Whether projected effective assets are below projected maximum liability.
    struct PreviewResult {
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
    }

    /// @notice Current pool asset, liability, reservation, and free-withdrawal accounting.
    /// @param physicalAssetsUsdc Canonical physical pool assets.
    /// @param netPhysicalAssetsUsdc Physical assets used for effective-asset accounting; currently copied directly
    ///        from `physicalAssetsUsdc` by `buildSolvencyState`.
    /// @param maxLiabilityUsdc Larger directional maximum-profit envelope.
    /// @param traderClaimBalanceUsdc Outstanding trader claims senior to LP liability coverage.
    /// @param withdrawalReservedUsdc Sum of maximum liability and trader claims.
    /// @param freeWithdrawableUsdc Physical assets above the withdrawal reservation, floored at zero.
    /// @param effectiveAssetsUsdc Net physical assets after trader claims, floored at zero.
    struct SolvencyState {
        uint256 physicalAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeWithdrawableUsdc;
        uint256 effectiveAssetsUsdc;
    }

    /// @notice Returns the larger BULL or BEAR maximum-profit envelope.
    /// @param bullMaxProfitUsdc Aggregate BULL-side maximum-profit liability.
    /// @param bearMaxProfitUsdc Aggregate BEAR-side maximum-profit liability.
    /// @return Maximum of the two liabilities; equal inputs return that common value.
    function getMaxLiability(
        uint256 bullMaxProfitUsdc,
        uint256 bearMaxProfitUsdc
    ) internal pure returns (uint256) {
        return bullMaxProfitUsdc > bearMaxProfitUsdc ? bullMaxProfitUsdc : bearMaxProfitUsdc;
    }

    /// @notice Returns maximum liability after reducing one side's maximum-profit envelope for a close.
    /// @dev Reverts on subtraction underflow if `maxProfitReductionUsdc` exceeds the selected side's envelope.
    /// @param bullMaxProfitUsdc BULL-side maximum-profit liability before the close.
    /// @param bearMaxProfitUsdc BEAR-side maximum-profit liability before the close.
    /// @param side Side whose position liability is being reduced.
    /// @param maxProfitReductionUsdc Amount removed from the selected side's envelope.
    /// @return Remaining maximum of the two side liabilities.
    function getMaxLiabilityAfterClose(
        uint256 bullMaxProfitUsdc,
        uint256 bearMaxProfitUsdc,
        CfdTypes.Side side,
        uint256 maxProfitReductionUsdc
    ) internal pure returns (uint256) {
        if (side == CfdTypes.Side.BULL) {
            bullMaxProfitUsdc -= maxProfitReductionUsdc;
        } else {
            bearMaxProfitUsdc -= maxProfitReductionUsdc;
        }
        return getMaxLiability(bullMaxProfitUsdc, bearMaxProfitUsdc);
    }

    /// @notice Builds current solvency and withdrawal-reservation accounting.
    /// @dev Both free withdrawal and effective assets saturate at zero. The reservation sum uses checked addition.
    /// @param physicalAssetsUsdc Canonical physical pool assets.
    /// @param maxLiabilityUsdc Current maximum directional liability envelope.
    /// @param traderClaimBalanceUsdc Outstanding trader claims senior to LP value.
    /// @return state Physical/effective assets, reservations, free withdrawal, and liabilities.
    function buildSolvencyState(
        uint256 physicalAssetsUsdc,
        uint256 maxLiabilityUsdc,
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (SolvencyState memory state) {
        state.physicalAssetsUsdc = physicalAssetsUsdc;
        state.netPhysicalAssetsUsdc = physicalAssetsUsdc;
        state.maxLiabilityUsdc = maxLiabilityUsdc;
        state.traderClaimBalanceUsdc = traderClaimBalanceUsdc;

        state.withdrawalReservedUsdc = maxLiabilityUsdc + traderClaimBalanceUsdc;
        state.freeWithdrawableUsdc =
            physicalAssetsUsdc > state.withdrawalReservedUsdc ? physicalAssetsUsdc - state.withdrawalReservedUsdc : 0;
        state.effectiveAssetsUsdc = state.netPhysicalAssetsUsdc > traderClaimBalanceUsdc
            ? state.netPhysicalAssetsUsdc - traderClaimBalanceUsdc
            : 0;
    }

    /// @notice Reserves a pending pool payout from current effective assets.
    /// @dev Subtraction saturates at zero. A zero pending payout returns the stored effective asset value unchanged.
    /// @param state Current solvency state.
    /// @param pendingPoolPayoutUsdc Payout not otherwise reflected in physical assets.
    /// @return Effective assets after reserving the payout.
    function effectiveAssetsAfterPendingPayout(
        SolvencyState memory state,
        uint256 pendingPoolPayoutUsdc
    ) internal pure returns (uint256) {
        if (pendingPoolPayoutUsdc == 0) {
            return state.effectiveAssetsUsdc;
        }
        return state.effectiveAssetsUsdc > pendingPoolPayoutUsdc ? state.effectiveAssetsUsdc - pendingPoolPayoutUsdc : 0;
    }

    /// @notice Tests whether effective assets are strictly below maximum liability.
    /// @param state Solvency state to test.
    /// @return True only when `effectiveAssetsUsdc < maxLiabilityUsdc`; equality is solvent.
    function isInsolvent(
        SolvencyState memory state
    ) internal pure returns (bool) {
        return state.effectiveAssetsUsdc < state.maxLiabilityUsdc;
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
        uint256 physicalAssetsAfterUsdc = currentState.physicalAssetsUsdc;
        if (delta.physicalAssetsDeltaUsdc > 0) {
            physicalAssetsAfterUsdc += uint256(delta.physicalAssetsDeltaUsdc);
        } else if (delta.physicalAssetsDeltaUsdc < 0) {
            uint256 debitUsdc = uint256(-delta.physicalAssetsDeltaUsdc);
            physicalAssetsAfterUsdc = physicalAssetsAfterUsdc > debitUsdc ? physicalAssetsAfterUsdc - debitUsdc : 0;
        }

        uint256 traderClaimBalanceAfterUsdc =
            _applySignedDelta(currentState.traderClaimBalanceUsdc, delta.traderClaimDeltaUsdc);

        SolvencyState memory afterState =
            buildSolvencyState(physicalAssetsAfterUsdc, delta.maxLiabilityAfterUsdc, traderClaimBalanceAfterUsdc);

        result.maxLiabilityAfterUsdc = afterState.maxLiabilityUsdc;
        result.effectiveAssetsAfterUsdc = effectiveAssetsAfterPendingPayout(afterState, delta.pendingPoolPayoutUsdc);
        result.postOpDegradedMode = result.effectiveAssetsAfterUsdc < result.maxLiabilityAfterUsdc;
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
