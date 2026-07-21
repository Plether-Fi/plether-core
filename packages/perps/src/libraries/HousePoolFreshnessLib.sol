// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";

/// @title HousePoolFreshnessLib
/// @notice Applies engine-provided mark-freshness policy to HousePool reconcile and withdrawal gates.
library HousePoolFreshnessLib {

    /// @notice Returns whether the cached engine mark is fresh enough for pool reconciliation.
    /// @dev Returns true without inspecting the mark when the accounting snapshot says freshness is not required.
    ///      When freshness is required, a future `lastMarkTime` is treated as age zero and a mark exactly at the age
    ///      limit is accepted by the underlying policy.
    /// @param accountingSnapshot Engine liability and freshness-policy inputs.
    /// @param statusSnapshot Engine mark timestamp and runtime flags.
    /// @param currentTimestamp Timestamp against which mark age is measured.
    /// @return Whether reconciliation may use the current cached mark.
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

    /// @notice Returns whether degraded-mode and mark-freshness gates permit pool withdrawals.
    /// @param accountingSnapshot Engine liability and freshness-policy inputs.
    /// @param statusSnapshot Engine mark timestamp and runtime flags.
    /// @param currentTimestamp Timestamp against which mark age is measured.
    /// @return Whether the pool-level withdrawal gate is live.
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

    /// @notice Product-facing alias for the reconciliation mark-freshness result.
    /// @param accountingSnapshot Engine liability and freshness-policy inputs.
    /// @param statusSnapshot Engine mark timestamp and runtime flags.
    /// @param currentTimestamp Timestamp against which mark age is measured.
    /// @return Whether the cached mark satisfies the current pool policy.
    function markFresh(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        return markIsFreshForReconcile(accountingSnapshot, statusSnapshot, currentTimestamp);
    }

}
