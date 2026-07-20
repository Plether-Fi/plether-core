// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title OrderOraclePolicyLib
/// @notice Compact router policy selector for order execution, mark refresh, and liquidation.
library OrderOraclePolicyLib {

    /// @notice Router action whose oracle policy is requested.
    enum OracleAction {
        /// @notice Execute a queued trader order.
        OrderExecution,
        /// @notice Refresh the engine's cached mark.
        MarkRefresh,
        /// @notice Liquidate an unsafe position.
        Liquidation
    }

    /// @notice Router constraints selected for one oracle action.
    /// @param closeOnly Whether the regime prohibits open/increase order execution.
    /// @param maxStaleness Maximum accepted component age in seconds.
    struct OracleExecutionPolicy {
        bool closeOnly;
        uint256 maxStaleness;
    }

    /// @notice Selects router close-only and staleness rules under current calendar state.
    /// @dev FAD alone makes order execution close-only but does not relax age limits. Only `oracleFrozen` selects
    ///      `fadMaxStaleness`; mark refresh uses the order limit and liquidation uses its dedicated live limit.
    /// @param action Router action whose policy is requested.
    /// @param oracleFrozen Whether the frozen-oracle calendar regime is active.
    /// @param isFad Whether FAD controls are active.
    /// @param liveExecutionStaleness Live order/refresh age limit in seconds.
    /// @param liveLiquidationStaleness Live liquidation age limit in seconds.
    /// @param fadMaxStaleness Frozen-regime age limit in seconds.
    /// @return policy Selected router oracle policy.
    function getOracleExecutionPolicy(
        OracleAction action,
        bool oracleFrozen,
        bool isFad,
        uint256 liveExecutionStaleness,
        uint256 liveLiquidationStaleness,
        uint256 fadMaxStaleness
    ) internal pure returns (OracleExecutionPolicy memory policy) {
        if (action == OracleAction.OrderExecution) {
            policy.closeOnly = oracleFrozen || isFad;
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : liveExecutionStaleness;
            return policy;
        }

        if (action == OracleAction.MarkRefresh) {
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : liveExecutionStaleness;
            return policy;
        }

        policy.maxStaleness = oracleFrozen ? fadMaxStaleness : liveLiquidationStaleness;
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

}
