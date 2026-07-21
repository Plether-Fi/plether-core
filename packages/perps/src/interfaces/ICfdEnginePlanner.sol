// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Pure planning surface that converts engine snapshots into settlement deltas.
/// @dev The planner performs no storage reads, authorization, oracle verification, or input authentication. Callers
///      must supply a canonical, internally consistent snapshot and order. USDC amounts use 6 decimals, prices use
///      8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEnginePlanner {

    /// @notice Applies a signed margin change to post-carry margin and reports whether it drains the position.
    /// @dev Exact depletion returns `(false, 0)`; only a mathematically negative result reports `drained`.
    ///      Meaningful inputs require `marginAfterCarry <= type(int256).max`; larger values reinterpret as negative on
    ///      explicit conversion, and signed addition reverts if the result falls outside the `int256` range.
    /// @param marginAfterCarry Position margin after pending carry realization, in USDC
    /// @param netMarginChange Signed margin change, where positive adds margin and negative removes it
    /// @return drained Whether the signed result would be negative
    /// @return marginAfter Resulting nonnegative margin in USDC, or zero when drained
    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter);

    /// @notice Plans an open or increase order from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. Expected business failures are encoded in the returned delta;
    ///      arithmetic violations or inconsistent inputs can still revert. `publishTime` is currently unused.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot
    /// @param order Open/increase order; the planner does not authenticate router-level flags or timing
    /// @param executionPrice Candidate execution price used for notional and PnL math (8 decimals)
    /// @param publishTime Oracle publish timestamp retained for interface parity; currently unused
    /// @return delta Complete open settlement plan or a partially populated typed failure result
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta);

    /// @notice Plans a close or decrease order from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. A zero close size against a live position can produce a valid
    ///      no-op plan, which entrypoint policy must reject when required. A zero-size snapshot position paired with a
    ///      zero close size can divide by zero, and other malformed inputs can also revert. `publishTime` is unused.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot
    /// @param order Close/decrease order; the planner does not authenticate router-level flags or timing
    /// @param executionPrice Candidate execution price used for realized PnL math (8 decimals)
    /// @param publishTime Oracle publish timestamp retained for interface parity; currently unused
    /// @return delta Complete close settlement plan or a partially populated typed failure result
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta);

    /// @notice Plans liquidation from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. A snapshot without a position returns a nonliquidatable
    ///      zero/partial delta. `publishTime` is currently unused.
    /// @param snap Trusted account, position, pool, collateral, claim, carry, and risk snapshot
    /// @param executionPrice Candidate liquidation execution price (8 decimals)
    /// @param publishTime Oracle publish timestamp retained for interface parity; currently unused
    /// @return delta Liquidation test and, when liquidatable, the complete settlement plan
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta);

    /// @notice Maps an open planning revert code to its commit-time failure category.
    /// @param code Open revert code to classify
    /// @return Commit-time category, or `None` for `OK` and unmapped values
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory);

    /// @notice Maps an open execution revert code to its router failure policy category.
    /// @param code Open revert code to classify
    /// @return Execution-time user/protocol-state category, or `None` for `OK`
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

    /// @notice Maps a close execution revert code to its router failure policy category.
    /// @param code Close revert code to classify
    /// @return `None` for `OK`; every mapped close failure is user-invalid
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

}
