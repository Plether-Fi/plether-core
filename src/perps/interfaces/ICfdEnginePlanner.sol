// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEnginePlanner {

    function computeOpenMarginAfter(
        uint256 marginAfterFunding,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter);

    function planGlobalFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.GlobalFundingDelta memory gfd);

    function planFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime,
        bool isClose,
        bool isFullClose
    ) external pure returns (CfdEnginePlanTypes.FundingDelta memory fd);

    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta);

    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta);

    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta);

    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory);

    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

}
