// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

/// @title OrderFailurePolicyLib
/// @notice Classifies planner failures that the router can reject deterministically at commit time.
library OrderFailurePolicyLib {

    /// @notice Returns whether an open failure category is predictable from commit-time state.
    /// @param category Planner-assigned open failure policy category.
    /// @return Whether the router should reject the order before enqueueing it.
    function isPredictablyInvalidOpen(
        CfdEnginePlanTypes.OpenFailurePolicyCategory category
    ) internal pure returns (bool) {
        return category == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable;
    }

}
