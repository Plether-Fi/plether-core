// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library CloseAccountingLib {

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
        uint256 positionSize,
        uint256 positionMarginUsdc,
        uint256 entryPrice,
        uint256 maxProfitUsdc,
        int256 vpiAccrued,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 capPrice,
        uint256 preSkewUsdc,
        uint256 postSkewUsdc,
        uint256 vaultDepthUsdc,
        uint256 vpiFactor,
        uint256 executionFeeBps,
        int256 fundingSettlementUsdc
    ) internal pure returns (CloseState memory state) {
        CfdTypes.Position memory closedPart = CfdTypes.Position({
            size: sizeDelta,
            margin: positionMarginUsdc,
            entryPrice: entryPrice,
            maxProfitUsdc: maxProfitUsdc,
            entryFundingIndex: 0,
            side: side,
            lastUpdateTime: 0,
            vpiAccrued: vpiAccrued
        });
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, oraclePrice, capPrice);
        state.realizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        state.marginToFreeUsdc = (positionMarginUsdc * sizeDelta) / positionSize;
        state.remainingMarginUsdc = positionMarginUsdc - state.marginToFreeUsdc;
        state.remainingSize = positionSize - sizeDelta;
        state.maxProfitReductionUsdc = (maxProfitUsdc * sizeDelta) / positionSize;

        state.vpiDeltaUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, vpiFactor);
        state.proportionalAccrualUsdc = (vpiAccrued * int256(sizeDelta)) / int256(positionSize);
        // Clamp so lifetime VPI (accrued + delta) never goes negative. Prevents LP sandwich attacks
        // where an attacker opens at high depth, donates to shrink depth, then closes to extract a
        // net-negative VPI rebate. Trade-off: market makers who heal skew on both open and close
        // receive $0 net VPI rebate — they must profit from directional price movement instead.
        if (state.proportionalAccrualUsdc + state.vpiDeltaUsdc < 0) {
            state.vpiDeltaUsdc = -state.proportionalAccrualUsdc;
        }

        uint256 notionalUsdc = (sizeDelta * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (notionalUsdc * executionFeeBps) / 10_000;
        state.netSettlementUsdc =
            state.realizedPnlUsdc - state.vpiDeltaUsdc - int256(state.executionFeeUsdc) + fundingSettlementUsdc;
    }

}
