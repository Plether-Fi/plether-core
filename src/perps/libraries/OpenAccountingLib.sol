// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library OpenAccountingLib {

    struct OpenInputs {
        uint256 currentSize;
        uint256 currentEntryPrice;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 price;
        uint256 capPrice;
        uint256 preSkewUsdc;
        uint256 postSkewUsdc;
        uint256 vaultDepthUsdc;
        uint256 executionFeeBps;
        int256 currentFundingIndex;
        CfdTypes.RiskParams riskParams;
    }

    struct OpenState {
        uint256 addedMaxProfitUsdc;
        uint256 oldEntryNotional;
        uint256 newEntryPrice;
        uint256 newSize;
        uint256 newEntryNotional;
        uint256 postSkewUsdc;
        int256 positionFundingContribution;
        int256 vpiUsdc;
        uint256 notionalUsdc;
        uint256 executionFeeUsdc;
        int256 tradeCostUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 initialMarginRequirementUsdc;
    }

    function buildOpenState(
        OpenInputs memory inputs
    ) internal pure returns (OpenState memory state) {
        state.addedMaxProfitUsdc =
            CfdMath.calculateMaxProfit(inputs.sizeDelta, inputs.price, inputs.side, inputs.capPrice);
        state.oldEntryNotional = inputs.currentSize * inputs.currentEntryPrice;

        if (inputs.currentSize == 0) {
            state.newEntryPrice = inputs.price;
        } else {
            uint256 totalValue = state.oldEntryNotional + (inputs.sizeDelta * inputs.price);
            state.newEntryPrice = totalValue / (inputs.currentSize + inputs.sizeDelta);
        }

        state.newSize = inputs.currentSize + inputs.sizeDelta;
        state.newEntryNotional = state.newSize * state.newEntryPrice;
        state.postSkewUsdc = inputs.postSkewUsdc;
        state.positionFundingContribution = int256(inputs.sizeDelta) * inputs.currentFundingIndex;

        state.vpiUsdc = CfdMath.calculateVPI(
            inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.vaultDepthUsdc, inputs.riskParams.vpiFactor
        );
        state.notionalUsdc = (inputs.sizeDelta * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (state.notionalUsdc * inputs.executionFeeBps) / 10_000;
        state.tradeCostUsdc = state.vpiUsdc + int256(state.executionFeeUsdc);
        state.maintenanceMarginUsdc =
            (((state.newSize * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE) * inputs.riskParams.maintMarginBps) / 10_000;
        state.initialMarginRequirementUsdc =
            (((state.newSize * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE) * inputs.riskParams.initMarginBps) / 10_000;
        if (state.initialMarginRequirementUsdc < inputs.riskParams.minBountyUsdc) {
            state.initialMarginRequirementUsdc = inputs.riskParams.minBountyUsdc;
        }
    }

    function effectiveMarginAfterTradeCost(
        uint256 marginUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (uint256 effectiveMarginUsdc) {
        effectiveMarginUsdc = marginUsdc;
        if (tradeCostUsdc < 0) {
            uint256 rebateUsdc = uint256(-tradeCostUsdc);
            effectiveMarginUsdc = effectiveMarginUsdc > rebateUsdc ? effectiveMarginUsdc - rebateUsdc : 0;
        }
    }

}
