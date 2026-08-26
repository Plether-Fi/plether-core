// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @title ICfdOrderPolicyEvaluator
/// @notice Stateless authoritative planning, normalization, and financial-policy checks for V2 delayed orders.
/// @dev `assessOrder` reconstructs the Engine snapshot. The pure entrypoints accept a supplied snapshot and delta for
///      deterministic simulation. Planner business-rule failures retain the existing `CfdEngine__TypedOrderFailure`
///      selector so Router classification remains stable. USDC values use 6 decimals, prices use 8 decimals, and
///      position sizes use 18 decimals.
interface ICfdOrderPolicyEvaluator {

    /// @notice A planner returned `OK` without producing a valid delta.
    error CfdOrderPolicyEvaluator__InvalidPlannerResult();

    /// @notice Authoritative market state selected a regime outside the order's allowed mode mask.
    /// @param mode Actual execution regime.
    /// @param allowedExecutionModes Caller-authorized LIVE=1, FAD=2, FROZEN=4 mask.
    error CfdOrderPolicyEvaluator__ExecutionModeDisallowed(
        OrderV2Types.ExecutionMode mode, uint8 allowedExecutionModes
    );

    /// @notice A normalized value violated the inclusive maximum or minimum identified by `constraint`.
    /// @dev Maximum kinds fail when `actual > limit`; minimum kinds fail when `actual < limit`. Negative position
    ///      equity always fails `PostPositionEquity` with zero-valued evidence. Exact zero can pass a zero equity floor
    ///      but then fails `PostLeverage` while a position remains.
    error CfdOrderPolicyEvaluator__ConstraintViolation(
        OrderV2Types.ConstraintKind constraint, uint256 actual, uint256 limit
    );

    /// @notice Rebuilds authoritative Engine state, calls one open/close planning entrypoint, and enforces bounds.
    /// @dev `executor` is explicit because a bounty paid back to `order.account` is a gross debit but has no net effect
    ///      on that account's settlement balance. The supplied Engine and its configured dependencies are read-only;
    ///      this evaluator has no storage and performs no writes. Before assessing a pending open, the caller must
    ///      release that order's committed-margin classification through a no-carry path so the planner does not
    ///      require the same `marginDelta` twice. A caller that subsequently asks the Engine to apply the order must
    ///      preserve the same price, depth, publish time, and protocol state between both calls.
    function assessOrder(
        address engine,
        CfdTypes.Order calldata order,
        address executor,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external view returns (OrderV2Types.ExecutionAssessment memory assessment);

    /// @notice Normalizes and validates a successful open/increase plan.
    /// @dev Treats the bounty as leaving the account. Use `assessOrder` when the executor may equal the account.
    function evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment);

    /// @notice Normalizes and validates a successful close/decrease plan.
    /// @dev Treats the bounty as leaving the account. Use `assessOrder` when the executor may equal the account.
    function evaluateClose(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment);

}
