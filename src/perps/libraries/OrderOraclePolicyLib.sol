// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library OrderOraclePolicyLib {

    enum OracleAction {
        OrderExecution,
        MarkRefresh,
        Liquidation
    }

    struct OracleExecutionPolicy {
        bool oracleFrozen;
        bool isFad;
        bool closeOnly;
        bool mevChecks;
        uint256 maxStaleness;
    }

    function getOracleExecutionPolicy(
        OracleAction action,
        bool oracleFrozen,
        bool isFad,
        uint256 fadMaxStaleness
    ) internal pure returns (OracleExecutionPolicy memory policy) {
        policy.oracleFrozen = oracleFrozen;
        policy.isFad = isFad;

        if (action == OracleAction.OrderExecution) {
            policy.closeOnly = oracleFrozen || isFad;
            // During genuine frozen-oracle windows, closes must remain executable against the
            // last valid oracle price. Commit-time MEV ordering stays enforced in live/FAD
            // markets but is intentionally bypassed once the oracle has stopped publishing.
            policy.mevChecks = !oracleFrozen;
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : 60;
            return policy;
        }

        if (action == OracleAction.MarkRefresh) {
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : 60;
            return policy;
        }

        policy.maxStaleness = oracleFrozen ? fadMaxStaleness : 15;
    }

    function isStale(
        uint64 oraclePublishTime,
        uint256 maxStaleness,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        uint256 age = currentTimestamp > oraclePublishTime ? currentTimestamp - oraclePublishTime : 0;
        return age > maxStaleness;
    }

}
