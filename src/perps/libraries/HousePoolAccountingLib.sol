// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "../interfaces/ICfdEngine.sol";

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
        uint256 deferredLiabilities;
        uint256 cashMinusFees;
        int256 mtm;
        uint256 distributable;
    }

    struct MarkFreshnessPolicy {
        bool required;
        uint256 maxStaleness;
    }

    function buildWithdrawalSnapshot(
        ICfdEngine.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (WithdrawalSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.netPhysicalAssetsUsdc + engineSnapshot.protocolFeesUsdc;
        snapshot.maxLiability = engineSnapshot.maxLiabilityUsdc;
        snapshot.protocolFees = engineSnapshot.protocolFeesUsdc;
        snapshot.reserved = engineSnapshot.maxLiabilityUsdc + engineSnapshot.protocolFeesUsdc
            + engineSnapshot.deferredTraderPayoutUsdc + engineSnapshot.deferredLiquidationBountyUsdc;
        if (engineSnapshot.withdrawalFundingLiabilityUsdc > 0) {
            snapshot.reserved += uint256(engineSnapshot.withdrawalFundingLiabilityUsdc);
        }
        snapshot.freeUsdc =
            snapshot.physicalAssets > snapshot.reserved ? snapshot.physicalAssets - snapshot.reserved : 0;
    }

    function buildReconcileSnapshot(
        ICfdEngine.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.netPhysicalAssetsUsdc + engineSnapshot.protocolFeesUsdc;
        snapshot.protocolFees = engineSnapshot.protocolFeesUsdc;
        snapshot.deferredLiabilities =
            engineSnapshot.deferredTraderPayoutUsdc + engineSnapshot.deferredLiquidationBountyUsdc;
        snapshot.cashMinusFees = engineSnapshot.netPhysicalAssetsUsdc > snapshot.deferredLiabilities
            ? engineSnapshot.netPhysicalAssetsUsdc - snapshot.deferredLiabilities
            : 0;
        snapshot.mtm = engineSnapshot.unrealizedMtmLiabilityUsdc;
        if (snapshot.mtm >= 0) {
            snapshot.distributable =
                snapshot.cashMinusFees > uint256(snapshot.mtm) ? snapshot.cashMinusFees - uint256(snapshot.mtm) : 0;
        } else {
            snapshot.distributable = snapshot.cashMinusFees + uint256(-snapshot.mtm);
        }
    }

    function getMarkFreshnessPolicy(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot
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
