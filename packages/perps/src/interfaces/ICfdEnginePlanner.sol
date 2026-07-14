// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Pure planning surface that converts engine snapshots into settlement deltas.
interface ICfdEnginePlanner {

    /// @notice Applies a signed margin change to post-carry margin and reports whether it drains the position.
    /// @param marginAfterCarry Position margin after pending carry realization
    /// @param netMarginChange Signed margin change from the order
    /// @return drained True when a negative change exceeds available margin
    /// @return marginAfter Resulting margin when not drained, otherwise zero
    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter);

    /// @notice Plans an open or increase order from a raw engine snapshot.
    /// @param snap Raw account, side, pool, and risk snapshot
    /// @param order Order being planned
    /// @param executionPrice Execution price used for notional and PnL math
    /// @param publishTime Oracle publish timestamp to store on the resulting position
    /// @return delta Complete open settlement delta or typed failure code
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta);

    /// @notice Plans a close or decrease order from a raw engine snapshot.
    /// @param snap Raw account, side, pool, and risk snapshot
    /// @param order Order being planned
    /// @param executionPrice Execution price used for realized PnL math
    /// @param publishTime Oracle publish timestamp to store on the resulting position
    /// @return delta Complete close settlement delta or typed failure code
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta);

    /// @notice Plans liquidation from a raw engine snapshot.
    /// @param snap Raw account, side, pool, and risk snapshot
    /// @param executionPrice Liquidation execution price
    /// @param publishTime Oracle publish timestamp to store as the latest mark
    /// @return delta Complete liquidation settlement delta
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta);

    /// @notice Maps an open planning revert code to its commit-time failure category.
    /// @param code Open revert code to classify
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory);

    /// @notice Maps an open execution revert code to its router failure policy category.
    /// @param code Open revert code to classify
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

    /// @notice Maps a close execution revert code to its router failure policy category.
    /// @param code Close revert code to classify
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

}
