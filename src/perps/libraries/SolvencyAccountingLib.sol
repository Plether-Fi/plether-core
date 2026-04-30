// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library SolvencyAccountingLib {

    struct PreviewDelta {
        int256 physicalAssetsDeltaUsdc;
        uint256 protocolFeesDeltaUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 deferredTraderPayoutDeltaUsdc;
        int256 deferredKeeperCreditDeltaUsdc;
        uint256 pendingVaultPayoutUsdc;
    }

    struct PreviewResult {
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
    }

    struct SolvencyState {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 deferredKeeperCreditUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeWithdrawableUsdc;
        uint256 effectiveAssetsUsdc;
    }

    function getPositionLpBackedRisk(
        uint256 maxProfitUsdc,
        uint256 marginUsdc
    ) internal pure returns (uint256) {
        return maxProfitUsdc > marginUsdc ? maxProfitUsdc - marginUsdc : 0;
    }

    function getMaxLiability(
        uint256 bullMaxProfitUsdc,
        uint256 bearMaxProfitUsdc
    ) internal pure returns (uint256) {
        return bullMaxProfitUsdc > bearMaxProfitUsdc ? bullMaxProfitUsdc : bearMaxProfitUsdc;
    }

    function buildSolvencyState(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 maxLiabilityUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 deferredKeeperCreditUsdc
    ) internal pure returns (SolvencyState memory state) {
        state.physicalAssetsUsdc = physicalAssetsUsdc;
        state.protocolFeesUsdc = protocolFeesUsdc;
        state.netPhysicalAssetsUsdc = physicalAssetsUsdc > protocolFeesUsdc ? physicalAssetsUsdc - protocolFeesUsdc : 0;
        state.maxLiabilityUsdc = maxLiabilityUsdc;
        state.deferredTraderCreditUsdc = deferredTraderCreditUsdc;
        state.deferredKeeperCreditUsdc = deferredKeeperCreditUsdc;

        uint256 deferredLiabilitiesUsdc = deferredTraderCreditUsdc + deferredKeeperCreditUsdc;
        state.withdrawalReservedUsdc = maxLiabilityUsdc + protocolFeesUsdc + deferredLiabilitiesUsdc;
        state.freeWithdrawableUsdc =
            physicalAssetsUsdc > state.withdrawalReservedUsdc ? physicalAssetsUsdc - state.withdrawalReservedUsdc : 0;
        state.effectiveAssetsUsdc = state.netPhysicalAssetsUsdc > deferredLiabilitiesUsdc
            ? state.netPhysicalAssetsUsdc - deferredLiabilitiesUsdc
            : 0;
    }

    function effectiveAssetsAfterPendingPayout(
        SolvencyState memory state,
        uint256 pendingVaultPayoutUsdc
    ) internal pure returns (uint256) {
        if (pendingVaultPayoutUsdc == 0) {
            return state.effectiveAssetsUsdc;
        }
        return
            state.effectiveAssetsUsdc > pendingVaultPayoutUsdc ? state.effectiveAssetsUsdc - pendingVaultPayoutUsdc : 0;
    }

    function isInsolvent(
        SolvencyState memory state
    ) internal pure returns (bool) {
        return state.effectiveAssetsUsdc < state.maxLiabilityUsdc;
    }

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

        uint256 deferredTraderPayoutAfterUsdc =
            _applySignedDelta(currentState.deferredTraderCreditUsdc, delta.deferredTraderPayoutDeltaUsdc);
        uint256 deferredKeeperCreditAfterUsdc =
            _applySignedDelta(currentState.deferredKeeperCreditUsdc, delta.deferredKeeperCreditDeltaUsdc);

        SolvencyState memory afterState = buildSolvencyState(
            physicalAssetsAfterUsdc,
            currentState.protocolFeesUsdc + delta.protocolFeesDeltaUsdc,
            delta.maxLiabilityAfterUsdc,
            deferredTraderPayoutAfterUsdc,
            deferredKeeperCreditAfterUsdc
        );

        result.maxLiabilityAfterUsdc = afterState.maxLiabilityUsdc;
        result.effectiveAssetsAfterUsdc = effectiveAssetsAfterPendingPayout(afterState, delta.pendingVaultPayoutUsdc);
        result.postOpDegradedMode = result.effectiveAssetsAfterUsdc < result.maxLiabilityAfterUsdc;
        result.triggersDegradedMode = !alreadyDegraded && result.postOpDegradedMode;
    }

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
