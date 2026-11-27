// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

/// @title OrderFailurePolicyLib
/// @notice Classifies planner failures that the router can reject deterministically at commit time.
library OrderFailurePolicyLib {

    // Use masks to keep the shared rejection policy within the Router sidecar's runtime size limit.
    uint256 private constant POOL_AND_NUMERIC_FAILURES = (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED));
    uint256 private constant FRESH_MARK_FAILURES = POOL_AND_NUMERIC_FAILURES
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED))
        | (1 << uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED));

    /// @notice Returns whether an open failure is predictable at commit time under the given mark policy.
    /// @param code Numeric planner failure code.
    /// @param freshMark Whether the order is assessed against a fresh reference mark.
    /// @return Whether the router should reject the order before enqueueing it.
    function isPredictablyInvalidOpen(
        uint8 code,
        bool freshMark
    ) internal pure returns (bool) {
        uint256 failures = freshMark ? FRESH_MARK_FAILURES : POOL_AND_NUMERIC_FAILURES;
        return failures & (uint256(1) << code) != 0;
    }

}
