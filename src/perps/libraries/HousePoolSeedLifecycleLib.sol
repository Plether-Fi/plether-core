// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolSeedLifecycleLib {

    function isSeedLifecycleComplete(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return seniorSeedInitialized && juniorSeedInitialized;
    }

    function hasSeedLifecycleStarted(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return seniorSeedInitialized || juniorSeedInitialized;
    }

    function canAcceptOrdinaryDeposits(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized,
        bool isTradingActive
    ) internal pure returns (bool) {
        return isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized) && isTradingActive;
    }

    function canIncreaseRisk(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized,
        bool isTradingActive
    ) internal pure returns (bool) {
        return canAcceptOrdinaryDeposits(seniorSeedInitialized, juniorSeedInitialized, isTradingActive);
    }

    function tradingActivationReady(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized);
    }

    function hasPendingBootstrap(
        uint256 unassignedAssets
    ) internal pure returns (bool) {
        return unassignedAssets > 0;
    }

}
