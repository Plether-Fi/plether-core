// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

library SolvencyAccountingLib {

    struct PreviewDelta {
        int256 physicalAssetsDeltaUsdc;
        uint256 protocolFeesDeltaUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 deferredTraderPayoutDeltaUsdc;
        int256 deferredLiquidationBountyDeltaUsdc;
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
        int256 solvencyFundingPnlUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredClearerBountyUsdc;
        uint256 effectiveAssetsUsdc;
    }

    function getMaxLiability(
        uint256 bullMaxProfitUsdc,
        uint256 bearMaxProfitUsdc
    ) internal pure returns (uint256) {
        return bullMaxProfitUsdc > bearMaxProfitUsdc ? bullMaxProfitUsdc : bearMaxProfitUsdc;
    }

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

    function buildSolvencyState(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 maxLiabilityUsdc,
        int256 solvencyFundingPnlUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (SolvencyState memory state) {
        state.physicalAssetsUsdc = physicalAssetsUsdc;
        state.protocolFeesUsdc = protocolFeesUsdc;
        state.netPhysicalAssetsUsdc = physicalAssetsUsdc > protocolFeesUsdc ? physicalAssetsUsdc - protocolFeesUsdc : 0;
        state.maxLiabilityUsdc = maxLiabilityUsdc;
        state.solvencyFundingPnlUsdc = solvencyFundingPnlUsdc;
        state.deferredTraderPayoutUsdc = deferredTraderPayoutUsdc;
        state.deferredClearerBountyUsdc = deferredClearerBountyUsdc;
        state.effectiveAssetsUsdc = state.netPhysicalAssetsUsdc;

        if (solvencyFundingPnlUsdc > 0) {
            state.effectiveAssetsUsdc = state.effectiveAssetsUsdc > uint256(solvencyFundingPnlUsdc)
                ? state.effectiveAssetsUsdc - uint256(solvencyFundingPnlUsdc)
                : 0;
        } else if (solvencyFundingPnlUsdc < 0) {
            state.effectiveAssetsUsdc += uint256(-solvencyFundingPnlUsdc);
        }

        uint256 deferredLiabilitiesUsdc = deferredTraderPayoutUsdc + deferredClearerBountyUsdc;
        if (deferredLiabilitiesUsdc > 0) {
            state.effectiveAssetsUsdc = state.effectiveAssetsUsdc > deferredLiabilitiesUsdc
                ? state.effectiveAssetsUsdc - deferredLiabilitiesUsdc
                : 0;
        }
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
            _applySignedDelta(currentState.deferredTraderPayoutUsdc, delta.deferredTraderPayoutDeltaUsdc);
        uint256 deferredClearerBountyAfterUsdc =
            _applySignedDelta(currentState.deferredClearerBountyUsdc, delta.deferredLiquidationBountyDeltaUsdc);

        SolvencyState memory afterState = buildSolvencyState(
            physicalAssetsAfterUsdc,
            currentState.protocolFeesUsdc + delta.protocolFeesDeltaUsdc,
            delta.maxLiabilityAfterUsdc,
            currentState.solvencyFundingPnlUsdc,
            deferredTraderPayoutAfterUsdc,
            deferredClearerBountyAfterUsdc
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
