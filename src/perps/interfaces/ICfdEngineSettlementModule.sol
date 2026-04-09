// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./CfdEngineSettlementTypes.sol";
import {ICfdEngineSettlementHost} from "./ICfdEngineSettlementHost.sol";

interface ICfdEngineSettlementModule {

    function buildOpenApplyPlan(
        CfdEngineSettlementTypes.OpenApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan);

    function buildCloseApplyPlan(
        CfdEngineSettlementTypes.CloseApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan);

    function buildLiquidationApplyPlan(
        CfdEngineSettlementTypes.LiquidationApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan);

    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime
    ) external returns (uint256 keeperBountyUsdc);
}
