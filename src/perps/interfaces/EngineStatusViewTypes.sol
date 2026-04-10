// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library EngineStatusViewTypes {

    struct ProtocolStatus {
        uint8 phase;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool fadWindow;
        uint256 fadMaxStaleness;
    }

}
