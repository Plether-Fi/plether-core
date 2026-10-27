// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";

interface ICfdEnginePlanningHost {

    function planner() external view returns (ICfdEnginePlanner);
    function settlementSidecar() external view returns (ICfdEngineSettlementSidecar);

}

/// @title CfdEnginePlanningReader
/// @notice Reads the bound engine's canonical snapshot and returns its configured planner's result.
/// @dev Keeps the large snapshot ABI encoding/decoding outside the engine. All entrypoints are read-only;
///      ownership, validation of returned deltas, and settlement remain in the engine.
contract CfdEnginePlanningReader {

    ICfdEnginePlanningHost public immutable ENGINE;
    error CfdEnginePlanningReader__OnlyEngine();

    constructor() {
        ENGINE = ICfdEnginePlanningHost(msg.sender);
    }

    modifier onlyEngine() {
        if (msg.sender != address(ENGINE)) {
            revert CfdEnginePlanningReader__OnlyEngine();
        }
        _;
    }

    function planOpen(
        CfdTypes.Order calldata order,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.OpenDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(order.account, poolDepthAssets);
        return ENGINE.planner().planOpen(snap, order, price);
    }

    function planClose(
        CfdTypes.Order calldata order,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.CloseDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(order.account, poolDepthAssets);
        return ENGINE.planner().planClose(snap, order, price);
    }

    function planLiquidation(
        address account,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.LiquidationDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(account, poolDepthAssets);
        return ENGINE.planner().planLiquidation(snap, price);
    }

}
