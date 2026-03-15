// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IMarginClearinghouse} from "../interfaces/IMarginClearinghouse.sol";

library MarginClearinghouseAccountingLib {

    struct SettlementConsumption {
        uint256 freeSettlementConsumedUsdc;
        uint256 activeMarginConsumedUsdc;
        uint256 otherLockedMarginConsumedUsdc;
        uint256 totalConsumedUsdc;
        uint256 uncoveredUsdc;
    }

    struct BucketMutation {
        uint256 settlementDebitUsdc;
        uint256 resultingLockedMarginUsdc;
        uint256 activeMarginUnlockedUsdc;
        uint256 otherLockedMarginUnlockedUsdc;
    }

    struct LiquidationResidualPlan {
        uint256 seizedUsdc;
        uint256 payoutUsdc;
        uint256 badDebtUsdc;
        BucketMutation mutation;
    }

    function buildAccountUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 totalLockedMarginUsdc,
        uint256 activePositionMarginUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets.settlementBalanceUsdc = settlementBalanceUsdc;
        buckets.totalLockedMarginUsdc = totalLockedMarginUsdc;
        buckets.activePositionMarginUsdc =
            activePositionMarginUsdc > totalLockedMarginUsdc ? totalLockedMarginUsdc : activePositionMarginUsdc;
        buckets.otherLockedMarginUsdc = buckets.totalLockedMarginUsdc - buckets.activePositionMarginUsdc;

        uint256 encumberedUsdc = buckets.totalLockedMarginUsdc;
        buckets.freeSettlementUsdc =
            buckets.settlementBalanceUsdc > encumberedUsdc ? buckets.settlementBalanceUsdc - encumberedUsdc : 0;
    }

    function planFundingLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        consumption.freeSettlementConsumedUsdc =
            buckets.freeSettlementUsdc > lossUsdc ? lossUsdc : buckets.freeSettlementUsdc;

        uint256 remainingLossUsdc = lossUsdc - consumption.freeSettlementConsumedUsdc;
        consumption.activeMarginConsumedUsdc =
            buckets.activePositionMarginUsdc > remainingLossUsdc ? remainingLossUsdc : buckets.activePositionMarginUsdc;
        consumption.totalConsumedUsdc = consumption.freeSettlementConsumedUsdc + consumption.activeMarginConsumedUsdc;
        consumption.uncoveredUsdc = remainingLossUsdc - consumption.activeMarginConsumedUsdc;
    }

    function getLiquidationReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets
    ) internal pure returns (uint256 reachableUsdc) {
        reachableUsdc = getSettlementReachableUsdc(buckets, 0);
    }

    function getSettlementReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc
    ) internal pure returns (uint256 reachableUsdc) {
        uint256 protectedBalance = protectedLockedMarginUsdc;
        reachableUsdc =
            buckets.settlementBalanceUsdc > protectedBalance ? buckets.settlementBalanceUsdc - protectedBalance : 0;
    }

    function planTerminalLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        uint256 reachableUsdc = getSettlementReachableUsdc(buckets, protectedLockedMarginUsdc);
        consumption.totalConsumedUsdc = reachableUsdc > lossUsdc ? lossUsdc : reachableUsdc;
        consumption.uncoveredUsdc = lossUsdc - consumption.totalConsumedUsdc;
        consumption.freeSettlementConsumedUsdc = buckets.freeSettlementUsdc > consumption.totalConsumedUsdc
            ? consumption.totalConsumedUsdc
            : buckets.freeSettlementUsdc;

        uint256 remainingConsumedUsdc = consumption.totalConsumedUsdc - consumption.freeSettlementConsumedUsdc;
        uint256 consumableActiveMarginUsdc = buckets.activePositionMarginUsdc > protectedLockedMarginUsdc
            ? buckets.activePositionMarginUsdc - protectedLockedMarginUsdc
            : 0;
        consumption.activeMarginConsumedUsdc =
            consumableActiveMarginUsdc > remainingConsumedUsdc ? remainingConsumedUsdc : consumableActiveMarginUsdc;
        consumption.otherLockedMarginConsumedUsdc = remainingConsumedUsdc - consumption.activeMarginConsumedUsdc;
    }

    function applyFundingLossMutation(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.activeMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
        mutation.resultingLockedMarginUsdc =
            buckets.otherLockedMarginUsdc + (buckets.activePositionMarginUsdc - consumption.activeMarginConsumedUsdc);
    }

    function applyTerminalLossMutation(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        protectedLockedMarginUsdc;
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.activeMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
        mutation.otherLockedMarginUnlockedUsdc = consumption.otherLockedMarginConsumedUsdc;
        mutation.resultingLockedMarginUsdc = buckets.totalLockedMarginUsdc - consumption.activeMarginConsumedUsdc
            - consumption.otherLockedMarginConsumedUsdc;
    }

    function planLiquidationResidual(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        int256 residualUsdc
    ) internal pure returns (LiquidationResidualPlan memory plan) {
        uint256 reachableUsdc = getLiquidationReachableUsdc(buckets);

        if (residualUsdc >= 0) {
            uint256 targetBalanceUsdc = uint256(residualUsdc);
            if (reachableUsdc > targetBalanceUsdc) {
                plan.seizedUsdc = reachableUsdc - targetBalanceUsdc;
            } else if (targetBalanceUsdc > reachableUsdc) {
                plan.payoutUsdc = targetBalanceUsdc - reachableUsdc;
            }
        } else {
            plan.seizedUsdc = reachableUsdc;
            plan.badDebtUsdc = uint256(-residualUsdc);
        }

        plan.mutation.settlementDebitUsdc = plan.seizedUsdc;
        plan.mutation.activeMarginUnlockedUsdc = buckets.activePositionMarginUsdc;
        if (plan.seizedUsdc > buckets.freeSettlementUsdc + buckets.activePositionMarginUsdc) {
            plan.mutation.otherLockedMarginUnlockedUsdc =
                plan.seizedUsdc - buckets.freeSettlementUsdc - buckets.activePositionMarginUsdc;
        }
        plan.mutation.resultingLockedMarginUsdc =
            buckets.otherLockedMarginUsdc - plan.mutation.otherLockedMarginUnlockedUsdc;
    }

}
