// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";

/// @notice Stateless wrapper exposing the CfdEngine planning library through an external interface.
contract CfdEnginePlanner is ICfdEnginePlanner {

    /// @inheritdoc ICfdEnginePlanner
    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter) {
        return CfdEnginePlanLib.computeOpenMarginAfter(marginAfterCarry, netMarginChange);
    }

    /// @inheritdoc ICfdEnginePlanner
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        return CfdEnginePlanLib.planOpen(snap, order, executionPrice, publishTime);
    }

    /// @inheritdoc ICfdEnginePlanner
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        return CfdEnginePlanLib.planClose(snap, order, executionPrice, publishTime);
    }

    /// @inheritdoc ICfdEnginePlanner
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        return CfdEnginePlanLib.planLiquidation(snap, executionPrice, publishTime);
    }

    /// @inheritdoc ICfdEnginePlanner
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory) {
        return CfdEnginePlanLib.getOpenFailurePolicyCategory(code);
    }

    /// @inheritdoc ICfdEnginePlanner
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

    /// @inheritdoc ICfdEnginePlanner
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

}
