// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library CloseAccountingLib {

    struct CloseInputs {
        CfdTypes.Position position;
        uint256 sizeDelta;
        uint256 oraclePrice;
        uint256 capPrice;
        // Normal close VPI uses absolute skew. Frozen close VPI also needs signed skew to detect zero-crossings.
        uint256 preSkewUsdc;
        uint256 postSkewUsdc;
        int256 preSignedSkewUsdc;
        int256 postSignedSkewUsdc;
        uint256 poolDepthUsdc;
        uint256 vpiFactor;
        uint256 frozenCloseVpiFactor;
        bool oracleFrozen;
        uint256 executionFeeBps;
    }

    struct CloseState {
        int256 realizedPnlUsdc;
        uint256 marginToFreeUsdc;
        uint256 remainingMarginUsdc;
        uint256 remainingSize;
        uint256 maxProfitReductionUsdc;
        int256 proportionalAccrualUsdc;
        int256 vpiDeltaUsdc;
        uint256 executionFeeUsdc;
        int256 netSettlementUsdc;
    }

    function buildCloseState(
        CloseInputs memory inputs
    ) internal pure returns (CloseState memory state) {
        CfdTypes.Position memory closedPart = CfdTypes.Position({
            size: inputs.sizeDelta,
            margin: inputs.position.margin,
            entryPrice: inputs.position.entryPrice,
            maxProfitUsdc: inputs.position.maxProfitUsdc,
            side: inputs.position.side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: inputs.position.vpiAccrued
        });
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, inputs.oraclePrice, inputs.capPrice);
        state.realizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        state.marginToFreeUsdc = (inputs.position.margin * inputs.sizeDelta) / inputs.position.size;
        state.remainingMarginUsdc = inputs.position.margin - state.marginToFreeUsdc;
        state.remainingSize = inputs.position.size - inputs.sizeDelta;
        state.maxProfitReductionUsdc = (inputs.position.maxProfitUsdc * inputs.sizeDelta) / inputs.position.size;

        state.proportionalAccrualUsdc =
            (inputs.position.vpiAccrued * int256(inputs.sizeDelta)) / int256(inputs.position.size);
        if (inputs.oracleFrozen) {
            state.vpiDeltaUsdc = int256(
                CfdMath.calculateOneWayVPI(
                    inputs.preSignedSkewUsdc,
                    inputs.postSignedSkewUsdc,
                    inputs.poolDepthUsdc,
                    inputs.frozenCloseVpiFactor
                )
            );
        } else {
            state.vpiDeltaUsdc =
                CfdMath.calculateVPI(inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.vpiFactor);
            // Clamp so lifetime VPI (accrued + delta) never goes negative. Prevents LP sandwich attacks
            // where an attacker opens at high depth, donates to shrink depth, then closes to extract a
            // net-negative VPI rebate. Trade-off: market makers who heal skew on both open and close
            // receive $0 net VPI rebate — they must profit from directional price movement instead.
            if (state.proportionalAccrualUsdc + state.vpiDeltaUsdc < 0) {
                state.vpiDeltaUsdc = -state.proportionalAccrualUsdc;
            }
        }

        uint256 notionalUsdc = (inputs.sizeDelta * inputs.oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (notionalUsdc * inputs.executionFeeBps) / 10_000;
        state.netSettlementUsdc = state.realizedPnlUsdc - state.vpiDeltaUsdc - int256(state.executionFeeUsdc);
    }

}
