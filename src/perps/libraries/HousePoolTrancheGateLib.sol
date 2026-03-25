// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolTrancheGateLib {

    function trancheDepositsAllowed(
        bool ordinaryDepositsAllowed,
        bool paused,
        uint256 unassignedAssets,
        bool markFreshForReconcile,
        uint256 projectedUnassignedAssets,
        bool isSenior,
        uint256 projectedSeniorPrincipal,
        uint256 projectedSeniorHighWaterMark
    ) internal pure returns (bool) {
        if (!ordinaryDepositsAllowed || paused || unassignedAssets > 0 || !markFreshForReconcile) {
            return false;
        }

        if (projectedUnassignedAssets > 0) {
            return false;
        }

        if (!isSenior) {
            return true;
        }

        return projectedSeniorPrincipal == 0 || projectedSeniorPrincipal >= projectedSeniorHighWaterMark;
    }

}
