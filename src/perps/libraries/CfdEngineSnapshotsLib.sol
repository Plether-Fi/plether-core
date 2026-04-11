// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CfdEngineSnapshotsLib {

    struct SolvencySnapshot {
        uint256 physicalAssets;
        uint256 protocolFees;
        uint256 netPhysicalAssets;
        uint256 maxLiability;
        uint256 effectiveSolvencyAssets;
    }

}
