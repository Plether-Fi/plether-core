// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolEngineViewTypes} from "../interfaces/HousePoolEngineViewTypes.sol";
import {HousePoolAccountingLib} from "./HousePoolAccountingLib.sol";

library HousePoolFreshnessLib {

    function markIsFreshForReconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
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
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        if (statusSnapshot.degradedMode) {
            return false;
        }

        return markIsFreshForReconcile(accountingSnapshot, statusSnapshot, currentTimestamp);
    }

    function markFresh(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        return markIsFreshForReconcile(accountingSnapshot, statusSnapshot, currentTimestamp);
    }

}
