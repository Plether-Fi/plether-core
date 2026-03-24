// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "../interfaces/ICfdEngine.sol";
import {HousePoolAccountingLib} from "./HousePoolAccountingLib.sol";

library HousePoolFreshnessLib {
    function markIsFreshForReconcile(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);
        if (!policy.required) {
            return true;
        }

        return HousePoolAccountingLib.isMarkFresh(statusSnapshot.lastMarkTime, policy.maxStaleness, currentTimestamp);
    }

    function withdrawalsLive(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        if (statusSnapshot.degradedMode) {
            return false;
        }

        return markIsFreshForReconcile(accountingSnapshot, statusSnapshot, currentTimestamp);
    }

    function markFresh(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        return markIsFreshForReconcile(accountingSnapshot, statusSnapshot, currentTimestamp);
    }
}
