// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";

/// @title CfdEnginePlanner
/// @notice Stateless external wrapper around the deterministic CFD engine planning library.
/// @dev The planner performs no storage reads, authorization, oracle verification, or input authentication. Callers
///      must supply a canonical, internally consistent snapshot and order. Unless stated otherwise, USDC amounts use
///      6 decimals, prices use 8 decimals, sizes use 18 decimals, and timestamps are Unix seconds.
contract CfdEnginePlanner is ICfdEnginePlanner {

    /// @notice Applies a signed open-cost change to position margin after pending carry.
    /// @dev Returns `(true, 0)` only when a negative change is strictly greater than available margin. Exact depletion
    ///      returns `(false, 0)`; the full open plan may reject that result through later risk checks. Meaningful inputs
    ///      require `marginAfterCarry <= type(int256).max`; larger values reinterpret as negative when cast, and signed
    ///      addition reverts if the mathematical result is outside the `int256` range.
    /// @param marginAfterCarry Position margin after pending carry realization, in 6-decimal USDC units.
    /// @param netMarginChange Signed 6-decimal USDC change; positive adds margin and negative removes it.
    /// @return drained Whether the signed result would be negative.
    /// @return marginAfter Resulting nonnegative position margin, or zero when drained.
    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter) {
        return CfdEnginePlanLib.computeOpenMarginAfter(marginAfterCarry, netMarginChange);
    }

    /// @notice Plans an open or same-side increase without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. `publishTime` is retained for interface parity but the
    ///      current pure planner does not use it. Expected business-rule failures are encoded in `delta.revertCode`
    ///      rather than reverted; arithmetic violations or inconsistent inputs can still revert.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot.
    /// @param order Open/increase order. The planner does not require `order.account == snap.account`, nonzero size/price,
    ///        `isClose == false`, valid timestamps/target price, or router authorization; it copies `order.account` to
    ///        the result while using collateral and position state from `snap`.
    /// @param executionPrice Candidate execution price, with 8 decimals.
    /// @param publishTime Oracle publish timestamp in Unix seconds; currently unused by planning calculations.
    /// @return delta Complete open settlement plan or a partially populated typed failure result.
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        return CfdEnginePlanLib.planOpen(snap, order, executionPrice, publishTime);
    }

    /// @notice Plans a close or same-side decrease without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. A zero size against a live position can produce a valid
    ///      no-op plan; the caller must reject that when its entrypoint policy requires it. A zero-size snapshot position
    ///      combined with a zero close size can divide by zero, and other malformed combinations can also revert.
    ///      `publishTime` is retained for interface parity but the current pure planner does not use it.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot.
    /// @param order Close/decrease order. The planner does not require `order.account == snap.account`, `isClose == true`,
    ///        matching side, valid timestamps/target price, or router authorization; it uses `order.account` and size
    ///        while using position and collateral state from `snap`.
    /// @param executionPrice Candidate execution price, with 8 decimals.
    /// @param publishTime Oracle publish timestamp in Unix seconds; currently unused by planning calculations.
    /// @return delta Complete close settlement plan or a partially populated typed failure result.
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        return CfdEnginePlanLib.planClose(snap, order, executionPrice, publishTime);
    }

    /// @notice Plans a full liquidation without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. A snapshot with no position returns a nonliquidatable
    ///      zero/partial delta. `publishTime` is retained for interface parity but is not used by current calculations.
    /// @param snap Trusted account, position, pool, collateral, claim, carry, and risk snapshot.
    /// @param executionPrice Candidate liquidation price, with 8 decimals.
    /// @param publishTime Oracle publish timestamp in Unix seconds; currently unused by planning calculations.
    /// @return delta Liquidation test and, when liquidatable, the complete settlement plan.
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        return CfdEnginePlanLib.planLiquidation(snap, executionPrice, publishTime);
    }

    /// @notice Classifies an open planning code for commit-time router policy.
    /// @param code Open planning result to classify.
    /// @return `CommitTimeRejectable`, an execution-only category, or `None` for `OK`/unmapped values.
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory) {
        return CfdEnginePlanLib.getOpenFailurePolicyCategory(code);
    }

    /// @notice Classifies an open planning code for execution-time router policy.
    /// @param code Open planning result to classify.
    /// @return `None` for `OK`, protocol-state invalidation for degraded/skew/solvency failures, and user invalidation
    ///         for every other open failure.
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

    /// @notice Classifies a close planning code for execution-time router policy.
    /// @param code Close planning result to classify.
    /// @return `None` for `OK`; every close failure is classified as user invalid.
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

}
