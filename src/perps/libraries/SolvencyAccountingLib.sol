// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

library SolvencyAccountingLib {

    struct SolvencyState {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        int256 solvencyFundingPnlUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredLiquidationBountyUsdc;
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
        uint256 deferredLiquidationBountyUsdc
    ) internal pure returns (SolvencyState memory state) {
        state.physicalAssetsUsdc = physicalAssetsUsdc;
        state.protocolFeesUsdc = protocolFeesUsdc;
        state.netPhysicalAssetsUsdc = physicalAssetsUsdc > protocolFeesUsdc ? physicalAssetsUsdc - protocolFeesUsdc : 0;
        state.maxLiabilityUsdc = maxLiabilityUsdc;
        state.solvencyFundingPnlUsdc = solvencyFundingPnlUsdc;
        state.deferredTraderPayoutUsdc = deferredTraderPayoutUsdc;
        state.deferredLiquidationBountyUsdc = deferredLiquidationBountyUsdc;
        state.effectiveAssetsUsdc = state.netPhysicalAssetsUsdc;

        if (solvencyFundingPnlUsdc > 0) {
            state.effectiveAssetsUsdc = state.effectiveAssetsUsdc > uint256(solvencyFundingPnlUsdc)
                ? state.effectiveAssetsUsdc - uint256(solvencyFundingPnlUsdc)
                : 0;
        } else if (solvencyFundingPnlUsdc < 0) {
            state.effectiveAssetsUsdc += uint256(-solvencyFundingPnlUsdc);
        }

        uint256 deferredLiabilitiesUsdc = deferredTraderPayoutUsdc + deferredLiquidationBountyUsdc;
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
        return state.effectiveAssetsUsdc > pendingVaultPayoutUsdc ? state.effectiveAssetsUsdc - pendingVaultPayoutUsdc : 0;
    }

    function isInsolvent(
        SolvencyState memory state
    ) internal pure returns (bool) {
        return state.effectiveAssetsUsdc < state.maxLiabilityUsdc;
    }

}
