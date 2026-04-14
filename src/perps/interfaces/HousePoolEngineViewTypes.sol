// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolEngineViewTypes {

    struct HousePoolInputSnapshot {
        uint256 physicalAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 supplementalReservedUsdc;
        uint256 unrealizedMtmLiabilityUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 deferredKeeperCreditUsdc;
        uint256 protocolFeesUsdc;
        bool markFreshnessRequired;
        uint256 maxMarkStaleness;
    }

    struct HousePoolStatusSnapshot {
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool degradedMode;
    }

}
