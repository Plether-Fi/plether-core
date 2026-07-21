// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title OracleFreshnessPolicyLib
/// @notice Selects close-only and mark-age rules for each perps action and calendar regime.
library OracleFreshnessPolicyLib {

    /// @notice Action whose oracle freshness policy is being requested.
    enum Mode {
        /// @notice Delayed open or increase execution.
        OpenExecution,
        /// @notice Delayed voluntary close execution.
        CloseExecution,
        /// @notice Position liquidation.
        Liquidation,
        /// @notice HousePool reconciliation or withdrawal accounting.
        PoolReconcile,
        /// @notice Close commit using a cached mark when a fresh update is unavailable.
        CloseCommitFallback,
        /// @notice Permissionless refresh of the cached engine mark.
        MarkRefresh
    }

    /// @notice Selected constraints for one action.
    /// @param closeOnly Whether the regime prohibits opens and increases.
    /// @param requireStoredMark Whether the action requires a nonzero cached engine mark.
    /// @param allowAnyStoredMark Whether the cached mark may be used without an age limit.
    /// @param maxStaleness Maximum accepted mark age in seconds when age is enforced.
    struct Policy {
        bool closeOnly;
        bool requireStoredMark;
        bool allowAnyStoredMark;
        uint256 maxStaleness;
    }

    /// @notice Selects the oracle policy for an action under current calendar state.
    /// @dev FAD alone makes open execution close-only but does not relax mark age. Only `oracleFrozen` selects
    ///      `fadMaxStaleness`. Outside frozen mode, pool reconciliation uses the engine limit when the pool limit is
    ///      zero and otherwise uses the smaller limit.
    /// @param mode Action whose policy is requested.
    /// @param oracleFrozen Whether the frozen-oracle calendar regime is active.
    /// @param isFad Whether FAD controls are active.
    /// @param engineMarkStalenessLimit Engine live-mark age limit in seconds.
    /// @param poolMarkStalenessLimit HousePool live-mark age limit in seconds, or zero to defer to the engine.
    /// @param routerOrderExecutionStalenessLimit Router order/refresh age limit in seconds.
    /// @param routerLiquidationStalenessLimit Router liquidation age limit in seconds.
    /// @param fadMaxStaleness Frozen-regime mark age limit in seconds.
    /// @return policy Selected action policy.
    function getPolicy(
        Mode mode,
        bool oracleFrozen,
        bool isFad,
        uint256 engineMarkStalenessLimit,
        uint256 poolMarkStalenessLimit,
        uint256 routerOrderExecutionStalenessLimit,
        uint256 routerLiquidationStalenessLimit,
        uint256 fadMaxStaleness
    ) internal pure returns (Policy memory policy) {
        if (mode == Mode.OpenExecution) {
            policy.closeOnly = oracleFrozen || isFad;
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : routerOrderExecutionStalenessLimit;
            return policy;
        }

        if (mode == Mode.CloseExecution || mode == Mode.MarkRefresh) {
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : routerOrderExecutionStalenessLimit;
            return policy;
        }

        if (mode == Mode.Liquidation) {
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : routerLiquidationStalenessLimit;
            return policy;
        }

        if (mode == Mode.CloseCommitFallback) {
            policy.requireStoredMark = true;
            policy.allowAnyStoredMark = true;
            return policy;
        }

        policy.maxStaleness =
            oracleFrozen ? fadMaxStaleness : _effectiveLiveMarkLimit(engineMarkStalenessLimit, poolMarkStalenessLimit);
    }

    /// @notice Returns whether a publish time is in the future or older than the allowed age.
    /// @dev A mark exactly `maxStaleness` seconds old is accepted.
    /// @param oraclePublishTime Oracle publish timestamp.
    /// @param maxStaleness Maximum accepted age in seconds.
    /// @param currentTimestamp Timestamp against which age is measured.
    /// @return Whether the mark is invalid for age or future dating.
    function isStale(
        uint256 oraclePublishTime,
        uint256 maxStaleness,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        if (oraclePublishTime > currentTimestamp) {
            return true;
        }
        return currentTimestamp - oraclePublishTime > maxStaleness;
    }

    /// @notice Returns the engine live-mark limit when the pool limit is zero, otherwise the smaller limit.
    /// @param engineMarkStalenessLimit Engine live-mark age limit in seconds.
    /// @param poolMarkStalenessLimit Pool live-mark age limit in seconds, or zero to defer to the engine.
    /// @return Effective live-mark age limit in seconds; this can be zero when the engine limit is zero.
    function _effectiveLiveMarkLimit(
        uint256 engineMarkStalenessLimit,
        uint256 poolMarkStalenessLimit
    ) private pure returns (uint256) {
        if (poolMarkStalenessLimit == 0) {
            return engineMarkStalenessLimit;
        }
        return engineMarkStalenessLimit < poolMarkStalenessLimit ? engineMarkStalenessLimit : poolMarkStalenessLimit;
    }

}
