// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library PositionRiskAccountingLib {

    struct FundingStepInputs {
        uint256 price;
        uint256 bullOi;
        uint256 bearOi;
        uint256 timeDelta;
        uint256 vaultDepthUsdc;
        CfdTypes.RiskParams riskParams;
    }

    struct FundingStepResult {
        uint256 absSkewUsdc;
        int256 bullFundingIndexDelta;
        int256 bearFundingIndexDelta;
    }

    struct PositionRiskState {
        int256 pendingFundingUsdc;
        int256 unrealizedPnlUsdc;
        int256 equityUsdc;
        uint256 currentNotionalUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    function computeLpBackedNotionalUsdc(
        uint256 size,
        uint256 price,
        uint256 marginUsdc
    ) internal pure returns (uint256 lpBackedNotionalUsdc) {
        uint256 notionalUsdc = (size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        lpBackedNotionalUsdc = notionalUsdc > marginUsdc ? notionalUsdc - marginUsdc : 0;
    }

    function computePendingCarryUsdc(
        uint256 size,
        uint256 price,
        uint256 marginUsdc,
        uint256 baseCarryBps,
        uint256 timeDelta
    ) internal pure returns (uint256 carryUsdc) {
        if (timeDelta == 0 || size == 0 || price == 0 || baseCarryBps == 0) {
            return 0;
        }
        uint256 lpBackedNotionalUsdc = computeLpBackedNotionalUsdc(size, price, marginUsdc);
        carryUsdc = (baseCarryBps * lpBackedNotionalUsdc * timeDelta) / (CfdMath.SECONDS_PER_YEAR * 10_000);
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

        FundingStepResult memory step = computeFundingStep(
            FundingStepInputs({
                price: lastMarkPrice,
                bullOi: bullOi,
                bearOi: bearOi,
                timeDelta: timeDelta,
                vaultDepthUsdc: vaultDepthUsdc,
                riskParams: riskParams
            })
        );
        currentIndex = pos.side == CfdTypes.Side.BULL
            ? currentIndex + step.bullFundingIndexDelta
            : currentIndex + step.bearFundingIndexDelta;

        return getPendingFunding(pos, currentIndex);
    }

    function computeFundingStep(
        FundingStepInputs memory inputs
    ) internal pure returns (FundingStepResult memory result) {
        if (inputs.timeDelta == 0 || inputs.vaultDepthUsdc == 0 || inputs.price == 0) {
            return result;
        }

        uint256 bullUsdc = (inputs.bullOi * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (inputs.bearOi * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE;
        bool bullMajority;

        if (bullUsdc > bearUsdc) {
            result.absSkewUsdc = bullUsdc - bearUsdc;
            bullMajority = true;
        } else {
            result.absSkewUsdc = bearUsdc - bullUsdc;
        }

        if (result.absSkewUsdc == 0) {
            return result;
        }

        uint256 annRate = CfdMath.getAnnualizedFundingRate(result.absSkewUsdc, inputs.vaultDepthUsdc, inputs.riskParams);
        uint256 fundingDelta = (annRate * inputs.timeDelta) / CfdMath.SECONDS_PER_YEAR;
        int256 step = int256((inputs.price * fundingDelta) / 1e8);
        if (step == 0) {
            return result;
        }

        if (bullMajority) {
            result.bullFundingIndexDelta = -step;
            result.bearFundingIndexDelta = step;
        } else {
            result.bearFundingIndexDelta = -step;
            result.bullFundingIndexDelta = step;
        }
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

    function buildPositionRiskStateWithCarry(
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 capPrice,
        uint256 pendingCarryUsdc,
        uint256 reachableCollateralUsdc,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, capPrice);
        state.pendingFundingUsdc = -int256(pendingCarryUsdc);
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc = int256(reachableCollateralUsdc) - int256(pendingCarryUsdc) + state.unrealizedPnlUsdc;
        state.currentNotionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.maintenanceMarginUsdc = (state.currentNotionalUsdc * requiredBps) / 10_000;
        state.liquidatable = state.equityUsdc <= int256(state.maintenanceMarginUsdc);
    }

}
