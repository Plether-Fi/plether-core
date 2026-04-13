// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library OracleFreshnessPolicyLib {

    enum Mode {
        OpenExecution,
        CloseExecution,
        Liquidation,
        PoolReconcile,
        CloseCommitFallback,
        MarkRefresh
    }

    struct Policy {
        bool closeOnly;
        bool requireStoredMark;
        bool allowAnyStoredMark;
        uint256 maxStaleness;
    }

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

        policy.maxStaleness = oracleFrozen ? fadMaxStaleness : _effectiveLiveMarkLimit(engineMarkStalenessLimit, poolMarkStalenessLimit);
    }

    function isStale(
        uint64 oraclePublishTime,
        uint256 maxStaleness,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        uint256 age = currentTimestamp > oraclePublishTime ? currentTimestamp - oraclePublishTime : 0;
        return age > maxStaleness;
    }

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
