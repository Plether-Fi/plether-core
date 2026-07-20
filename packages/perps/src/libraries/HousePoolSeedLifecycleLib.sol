// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title HousePoolSeedLifecycleLib
/// @notice Pure predicates for HousePool tranche seeding and trading activation.
library HousePoolSeedLifecycleLib {

    /// @notice Returns whether both tranche seed positions have been initialized.
    /// @param seniorSeedInitialized Whether the senior seed exists.
    /// @param juniorSeedInitialized Whether the junior seed exists.
    /// @return Whether the seed lifecycle is complete.
    function isSeedLifecycleComplete(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return seniorSeedInitialized && juniorSeedInitialized;
    }

    /// @notice Returns whether at least one tranche seed position has been initialized.
    /// @param seniorSeedInitialized Whether the senior seed exists.
    /// @param juniorSeedInitialized Whether the junior seed exists.
    /// @return Whether the seed lifecycle has started.
    function hasSeedLifecycleStarted(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return seniorSeedInitialized || juniorSeedInitialized;
    }

    /// @notice Returns whether both seeds exist and live trading has been activated.
    /// @param seniorSeedInitialized Whether the senior seed exists.
    /// @param juniorSeedInitialized Whether the junior seed exists.
    /// @param isTradingActive Whether governance has activated trading.
    /// @return Whether the lifecycle permits ordinary LP deposits.
    function canAcceptOrdinaryDeposits(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized,
        bool isTradingActive
    ) internal pure returns (bool) {
        return isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized) && isTradingActive;
    }

    /// @notice Returns whether the lifecycle permits new trader risk.
    /// @dev The current lifecycle uses the same predicate for risk increases and ordinary LP deposits.
    /// @param seniorSeedInitialized Whether the senior seed exists.
    /// @param juniorSeedInitialized Whether the junior seed exists.
    /// @param isTradingActive Whether governance has activated trading.
    /// @return Whether the engine may increase risk.
    function canIncreaseRisk(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized,
        bool isTradingActive
    ) internal pure returns (bool) {
        return canAcceptOrdinaryDeposits(seniorSeedInitialized, juniorSeedInitialized, isTradingActive);
    }

    /// @notice Returns whether both seeds exist, satisfying the seed prerequisite for trading activation.
    /// @param seniorSeedInitialized Whether the senior seed exists.
    /// @param juniorSeedInitialized Whether the junior seed exists.
    /// @return Whether the seed prerequisite for trading activation is satisfied.
    function tradingActivationReady(
        bool seniorSeedInitialized,
        bool juniorSeedInitialized
    ) internal pure returns (bool) {
        return isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized);
    }

    /// @notice Returns whether unassigned assets remain to be explicitly bootstrapped.
    /// @param unassignedAssets Quarantined, unassigned pool assets (6 decimals).
    /// @return Whether a bootstrap assignment remains pending.
    function hasPendingBootstrap(
        uint256 unassignedAssets
    ) internal pure returns (bool) {
        return unassignedAssets > 0;
    }

}
