// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";

library OrderFailurePolicyLib {

    enum FailedOrderBountyPolicy {
        None,
        ClearerFull,
        RefundUser
    }

    function isPredictablyInvalidOpen(
        CfdEnginePlanTypes.OpenFailurePolicyCategory category
    ) internal pure returns (bool) {
        return category == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable;
    }

}
