// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";

/// @notice Read-only operational and security-monitoring surface for synchronized LP epoch settlement.
interface ISettlementMonitorLens {

    /// @notice Returns bounded queue, cutoff, and execution-path status for one explicitly observed epoch.
    /// @dev HousePool processes FIFO heads rather than this selected epoch. The result is advisory and must be paired
    ///      with an `eth_call` of the exact settlement transaction before broadcast.
    function getSettlementStatus(
        uint256 observedEpoch
    ) external view returns (SettlementMonitorViewTypes.SettlementStatus memory status);

    /// @notice Returns bounded structural, NAV-aggregate, and custody checks with tri-state health.
    function getSettlementHealth() external view returns (SettlementMonitorViewTypes.SettlementHealth memory health);

    /// @notice Returns the current validated PoolReconcile feed observation or fail-soft oracle diagnostics.
    function getPoolReconcileOracleStatus()
        external
        view
        returns (SettlementMonitorViewTypes.OracleStatus memory oracleStatus);

    /// @notice Returns one single-block composite observation and unauthenticated content digests.
    function getSettlementObservation(
        uint256 observedEpoch
    ) external view returns (SettlementMonitorViewTypes.SettlementObservation memory observation);

    /// @notice Hashes accessible active settlement configuration and bound dependency identities.
    /// @dev This is not a monotonic version and cannot enumerate the Engine's full override-day set or Oracle basket.
    function observableConfigDigest() external view returns (bytes32 digest);

}
