// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";

library PositionRiskAccountingLib {

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

    function computeLpBackedNotionalUsdc(
        uint256 size,
        uint256 price,
        uint256 reachableCollateralUsdc
    ) internal pure returns (uint256 lpBackedNotionalUsdc) {
        uint256 notionalUsdc = (size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        lpBackedNotionalUsdc = notionalUsdc > reachableCollateralUsdc ? notionalUsdc - reachableCollateralUsdc : 0;
    }

    function computePendingCarryUsdc(
        uint256 lpBackedNotionalUsdc,
        uint256 baseCarryBps,
        uint256 timeDelta
    ) internal pure returns (uint256 carryUsdc) {
        if (timeDelta == 0 || lpBackedNotionalUsdc == 0 || baseCarryBps == 0) {
            return 0;
        }
        carryUsdc = (baseCarryBps * lpBackedNotionalUsdc * timeDelta) / (CfdMath.SECONDS_PER_YEAR * 10_000);
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
