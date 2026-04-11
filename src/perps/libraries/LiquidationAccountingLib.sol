// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngineSettlementLib} from "./CfdEngineSettlementLib.sol";

library LiquidationAccountingLib {

    struct LiquidationState {
        int256 equityUsdc;
        uint256 reachableCollateralUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 keeperBountyUsdc;
    }

    function buildLiquidationState(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralUsdc,
        int256 equityUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 tokenScale
    ) internal pure returns (LiquidationState memory state) {
        state.reachableCollateralUsdc = reachableCollateralUsdc;
        state.equityUsdc = equityUsdc;

        uint256 notionalUsdc = (size * oraclePrice) / tokenScale;
        state.maintenanceMarginUsdc = (notionalUsdc * maintMarginBps) / 10_000;

        uint256 bounty = (notionalUsdc * bountyBps) / 10_000;
        if (bounty < minBountyUsdc) {
            bounty = minBountyUsdc;
        }

        if (state.equityUsdc > 0 && bounty > uint256(state.equityUsdc)) {
            bounty = uint256(state.equityUsdc);
        } else if (state.equityUsdc <= 0 && bounty > reachableCollateralUsdc) {
            bounty = reachableCollateralUsdc;
        }

        state.keeperBountyUsdc = bounty;
    }

    function settlementForState(
        LiquidationState memory state
    ) internal pure returns (CfdEngineSettlementLib.LiquidationSettlementResult memory result) {
        result = CfdEngineSettlementLib.liquidationSettlementResult(
            state.reachableCollateralUsdc, state.equityUsdc - int256(state.keeperBountyUsdc)
        );
    }

}
