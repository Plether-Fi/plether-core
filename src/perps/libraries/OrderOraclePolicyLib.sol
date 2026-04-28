// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library OrderOraclePolicyLib {

    enum OracleAction {
        OrderExecution,
        MarkRefresh,
        Liquidation
    }

    struct OracleExecutionPolicy {
        bool closeOnly;
        uint256 maxStaleness;
    }

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
