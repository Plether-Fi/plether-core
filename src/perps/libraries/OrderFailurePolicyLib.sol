// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";

library OrderFailurePolicyLib {

    function isPredictablyInvalidOpen(
        CfdEnginePlanTypes.OpenFailurePolicyCategory category
    ) internal pure returns (bool) {
        return category == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable;
    }

}
