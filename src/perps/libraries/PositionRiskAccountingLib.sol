// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library PositionRiskAccountingLib {

    uint256 internal constant CARRY_INDEX_SCALE = 1e18;
    uint256 internal constant UTILIZATION_BPS = 10_000;

    struct PositionRiskState {
        int256 unrealizedPnlUsdc;
        int256 equityUsdc;
        uint256 currentNotionalUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    function _vpiClawbackUsdc(
        int256 vpiAccrued
    ) private pure returns (uint256) {
        return vpiAccrued < 0 ? uint256(-vpiAccrued) : 0;
    }

    function computeBorrowBaseUsdc(
        uint256 maxProfitUsdc,
        uint256 marginUsdc
    ) internal pure returns (uint256) {
        return maxProfitUsdc > marginUsdc ? maxProfitUsdc - marginUsdc : 0;
    }

    function computeBorrowUtilizationBps(
        uint256 borrowBaseUsdc,
        uint256 poolAssetsUsdc
    ) internal pure returns (uint256 utilizationBps) {
        if (borrowBaseUsdc == 0) {
            return 0;
        }
        if (poolAssetsUsdc == 0) {
            return UTILIZATION_BPS;
        }
        utilizationBps = (borrowBaseUsdc * UTILIZATION_BPS) / poolAssetsUsdc;
        if (utilizationBps > UTILIZATION_BPS) {
            utilizationBps = UTILIZATION_BPS;
        }
    }

    function computeUtilizedCarryRateBps(
        uint256 baseCarryBps,
        uint256 utilizationBps
    ) internal pure returns (uint256) {
        if (utilizationBps > UTILIZATION_BPS) {
            utilizationBps = UTILIZATION_BPS;
        }
        return (baseCarryBps * utilizationBps) / UTILIZATION_BPS;
    }

    function computeCarryIndexIncrement(
        uint256 carryRateBps,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        if (carryRateBps == 0 || timeDelta == 0) {
            return 0;
        }
        return (carryRateBps * CARRY_INDEX_SCALE * timeDelta) / (CfdMath.SECONDS_PER_YEAR * 10_000);
    }

    function computeCurrentCarryIndex(
        uint256 storedIndex,
        uint64 previousTimestamp,
        uint256 currentTimestamp,
        uint256 borrowBaseUsdc,
        uint256 poolAssetsUsdc,
        uint256 baseCarryBps
    ) internal pure returns (uint256 index) {
        index = storedIndex;
        if (currentTimestamp <= previousTimestamp || borrowBaseUsdc == 0 || baseCarryBps == 0) {
            return index;
        }

        uint256 utilizationBps = computeBorrowUtilizationBps(borrowBaseUsdc, poolAssetsUsdc);
        if (utilizationBps == 0) {
            return index;
        }

        index += (baseCarryBps * utilizationBps * CARRY_INDEX_SCALE * (currentTimestamp - previousTimestamp))
            / (CfdMath.SECONDS_PER_YEAR * UTILIZATION_BPS * 10_000);
    }

    function computeIndexedCarryUsdc(
        uint256 borrowBaseUsdc,
        uint256 carryIndexDelta
    ) internal pure returns (uint256) {
        if (borrowBaseUsdc == 0 || carryIndexDelta == 0) {
            return 0;
        }
        return (borrowBaseUsdc * carryIndexDelta) / CARRY_INDEX_SCALE;
    }

    function buildPositionRiskState(
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, capPrice);
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc =
            int256(reachableCollateralUsdc) - int256(_vpiClawbackUsdc(pos.vpiAccrued)) + state.unrealizedPnlUsdc;
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
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc = int256(reachableCollateralUsdc) - int256(pendingCarryUsdc)
            - int256(_vpiClawbackUsdc(pos.vpiAccrued)) + state.unrealizedPnlUsdc;
        state.currentNotionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.maintenanceMarginUsdc = (state.currentNotionalUsdc * requiredBps) / 10_000;
        state.liquidatable = state.equityUsdc <= int256(state.maintenanceMarginUsdc);
    }

}
