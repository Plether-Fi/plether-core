// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolAccountingLib {

    struct WithdrawalSnapshot {
        uint256 physicalAssets;
        uint256 maxLiability;
        uint256 protocolFees;
        uint256 reserved;
        uint256 freeUsdc;
    }

    struct ReconcileSnapshot {
        uint256 physicalAssets;
        uint256 protocolFees;
        uint256 cashMinusFees;
        int256 mtm;
        uint256 distributable;
    }

    struct MarkFreshnessPolicy {
        bool required;
        uint256 maxStaleness;
    }

    function buildWithdrawalSnapshot(
        uint256 physicalAssets,
        uint256 maxLiability,
        uint256 protocolFees,
        uint256 reserved
    ) internal pure returns (WithdrawalSnapshot memory snapshot) {
        snapshot.physicalAssets = physicalAssets;
        snapshot.maxLiability = maxLiability;
        snapshot.protocolFees = protocolFees;
        snapshot.reserved = reserved;
        snapshot.freeUsdc = physicalAssets > reserved ? physicalAssets - reserved : 0;
    }

    function buildReconcileSnapshot(
        uint256 physicalAssets,
        uint256 protocolFees,
        int256 mtm
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        snapshot.physicalAssets = physicalAssets;
        snapshot.protocolFees = protocolFees;
        snapshot.cashMinusFees = physicalAssets > protocolFees ? physicalAssets - protocolFees : 0;
        snapshot.mtm = mtm;
        if (mtm >= 0) {
            snapshot.distributable = snapshot.cashMinusFees > uint256(mtm) ? snapshot.cashMinusFees - uint256(mtm) : 0;
        } else {
            snapshot.distributable = snapshot.cashMinusFees + uint256(-mtm);
        }
    }

    function getMarkFreshnessPolicy(
        bool required,
        bool oracleFrozen,
        uint256 fadMaxStaleness,
        uint256 markStalenessLimit
    ) internal pure returns (MarkFreshnessPolicy memory policy) {
        policy.required = required;
        if (required) {
            policy.maxStaleness = oracleFrozen ? fadMaxStaleness : markStalenessLimit;
        }
    }

    function isMarkFresh(
        uint64 lastMarkTime,
        uint256 limit,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        uint256 age = currentTimestamp > lastMarkTime ? currentTimestamp - lastMarkTime : 0;
        return age <= limit;
    }

}
