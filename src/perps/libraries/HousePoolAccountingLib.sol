// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolEngineViewTypes} from "../interfaces/HousePoolEngineViewTypes.sol";

library HousePoolAccountingLib {

    struct WithdrawalSnapshot {
        uint256 physicalAssets;
        uint256 maxLiability;
        uint256 reserved;
        uint256 freeUsdc;
    }

    struct ReconcileSnapshot {
        uint256 physicalAssets;
        uint256 traderClaimLiabilities;
        uint256 cashAfterTraderClaimLiabilities;
        uint256 mtm;
        uint256 distributable;
    }

    struct MarkFreshnessPolicy {
        bool required;
        uint256 maxStaleness;
    }

    function buildWithdrawalSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (WithdrawalSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.physicalAssetsUsdc;
        snapshot.maxLiability = engineSnapshot.maxLiabilityUsdc;
        snapshot.reserved = engineSnapshot.maxLiabilityUsdc + engineSnapshot.traderClaimBalanceUsdc
            + engineSnapshot.supplementalReservedUsdc;
        snapshot.freeUsdc =
            snapshot.physicalAssets > snapshot.reserved ? snapshot.physicalAssets - snapshot.reserved : 0;
    }

    function buildReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        return _buildReconcileSnapshot(engineSnapshot, engineSnapshot.unrealizedMtmLiabilityUsdc);
    }

    function buildDepositReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        return _buildReconcileSnapshot(engineSnapshot, engineSnapshot.depositMtmLiabilityUsdc);
    }

    function _buildReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot,
        uint256 mtmLiabilityUsdc
    ) private pure returns (ReconcileSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.physicalAssetsUsdc;
        snapshot.traderClaimLiabilities = engineSnapshot.traderClaimBalanceUsdc;
        snapshot.cashAfterTraderClaimLiabilities = engineSnapshot.physicalAssetsUsdc > snapshot.traderClaimLiabilities
            ? engineSnapshot.physicalAssetsUsdc - snapshot.traderClaimLiabilities
            : 0;
        snapshot.mtm = mtmLiabilityUsdc;
        snapshot.distributable = snapshot.cashAfterTraderClaimLiabilities > snapshot.mtm
            ? snapshot.cashAfterTraderClaimLiabilities - snapshot.mtm
            : 0;
    }

    function getMarkFreshnessPolicy(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot
    ) internal pure returns (MarkFreshnessPolicy memory policy) {
        policy.required = accountingSnapshot.markFreshnessRequired;
        if (policy.required) {
            policy.maxStaleness = accountingSnapshot.maxMarkStaleness;
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
