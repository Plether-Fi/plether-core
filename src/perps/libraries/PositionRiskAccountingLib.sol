// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library PositionRiskAccountingLib {

    struct PositionRiskState {
        int256 pendingFundingUsdc;
        int256 unrealizedPnlUsdc;
        int256 equityUsdc;
        uint256 currentNotionalUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    function getPendingFunding(
        CfdTypes.Position memory pos,
        int256 currentIndex
    ) internal pure returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        int256 indexDelta = currentIndex - pos.entryFundingIndex;
        fundingUsdc = (int256(pos.size) * indexDelta) / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function previewPendingFunding(
        CfdTypes.Position memory pos,
        int256 bullFundingIndex,
        int256 bearFundingIndex,
        uint256 lastMarkPrice,
        uint256 bullOi,
        uint256 bearOi,
        uint64 lastFundingTime,
        uint256 currentTimestamp,
        uint256 vaultDepthUsdc,
        CfdTypes.RiskParams memory riskParams
    ) internal pure returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }

        int256 currentIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        uint256 timeDelta = currentTimestamp - lastFundingTime;
        if (timeDelta == 0 || vaultDepthUsdc == 0 || lastMarkPrice == 0) {
            return getPendingFunding(pos, currentIndex);
        }

        uint256 bullUsdc = (bullOi * lastMarkPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOi * lastMarkPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 absSkew;
        bool bullMajority;

        if (bullUsdc > bearUsdc) {
            absSkew = bullUsdc - bearUsdc;
            bullMajority = true;
        } else {
            absSkew = bearUsdc - bullUsdc;
            bullMajority = false;
        }

        if (absSkew > 0) {
            uint256 annRate = CfdMath.getAnnualizedFundingRate(absSkew, vaultDepthUsdc, riskParams);
            uint256 fundingDelta = (annRate * timeDelta) / CfdMath.SECONDS_PER_YEAR;
            int256 step = int256((lastMarkPrice * fundingDelta) / 1e8);
            if (step > 0) {
                if (bullMajority) {
                    currentIndex = pos.side == CfdTypes.Side.BULL ? currentIndex - step : currentIndex + step;
                } else {
                    currentIndex = pos.side == CfdTypes.Side.BEAR ? currentIndex - step : currentIndex + step;
                }
            }
        }

        return getPendingFunding(pos, currentIndex);
    }

    function buildPositionRiskState(
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 capPrice,
        int256 pendingFundingUsdc,
        uint256 reachableCollateralUsdc,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, capPrice);
        state.pendingFundingUsdc = pendingFundingUsdc;
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc = int256(reachableCollateralUsdc) + pendingFundingUsdc + state.unrealizedPnlUsdc;
        state.currentNotionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.maintenanceMarginUsdc = (state.currentNotionalUsdc * requiredBps) / 10_000;
        state.liquidatable = state.equityUsdc <= int256(state.maintenanceMarginUsdc);
    }

}
