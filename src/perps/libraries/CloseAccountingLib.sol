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
        CfdTypes.Position memory position,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 capPrice,
        uint256 preSkewUsdc,
        uint256 postSkewUsdc,
        uint256 vaultDepthUsdc,
        uint256 vpiFactor,
        uint256 executionFeeBps,
        uint256 unsettledFundingDebt
    ) internal pure returns (CloseState memory state) {
        CfdTypes.Position memory closedPart = position;
        closedPart.size = sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, oraclePrice, capPrice);
        state.realizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        state.marginToFreeUsdc = (position.margin * sizeDelta) / position.size;
        state.remainingMarginUsdc = position.margin - state.marginToFreeUsdc;
        state.remainingSize = position.size - sizeDelta;
        state.maxProfitReductionUsdc = (position.maxProfitUsdc * sizeDelta) / position.size;

        state.vpiDeltaUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, vpiFactor);
        state.proportionalAccrualUsdc = (position.vpiAccrued * int256(sizeDelta)) / int256(position.size);
        if (state.proportionalAccrualUsdc + state.vpiDeltaUsdc < 0) {
            state.vpiDeltaUsdc = -state.proportionalAccrualUsdc;
        }

        uint256 notionalUsdc = (sizeDelta * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (notionalUsdc * executionFeeBps) / 10_000;
        state.netSettlementUsdc =
            state.realizedPnlUsdc - state.vpiDeltaUsdc - int256(state.executionFeeUsdc) - int256(unsettledFundingDebt);
    }

}
