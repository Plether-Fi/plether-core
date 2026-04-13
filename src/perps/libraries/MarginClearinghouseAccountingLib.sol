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
        uint256 positionMarginUnlockedUsdc;
        uint256 otherLockedMarginUnlockedUsdc;
    }

    struct OpenCostPlan {
        int256 netMarginChangeUsdc;
        uint256 settlementCreditUsdc;
        uint256 settlementDebitUsdc;
        uint256 positionMarginUnlockedUsdc;
        uint256 positionMarginLockedUsdc;
        uint256 resultingSettlementBalanceUsdc;
        uint256 resultingPositionMarginUsdc;
        uint256 resultingFreeSettlementUsdc;
        bool insufficientFreeEquity;
        bool insufficientPositionMargin;
    }

    struct LiquidationResidualPlan {
        uint256 settlementRetainedUsdc;
        uint256 settlementSeizedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 badDebtUsdc;
        BucketMutation mutation;
    }

    function buildAccountUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets.settlementBalanceUsdc = settlementBalanceUsdc;
        buckets.activePositionMarginUsdc = positionMarginUsdc;
        buckets.otherLockedMarginUsdc = committedOrderMarginUsdc + reservedSettlementUsdc;
        buckets.totalLockedMarginUsdc = positionMarginUsdc + committedOrderMarginUsdc + reservedSettlementUsdc;

        uint256 encumberedUsdc = buckets.totalLockedMarginUsdc;
        buckets.freeSettlementUsdc =
            buckets.settlementBalanceUsdc > encumberedUsdc ? buckets.settlementBalanceUsdc - encumberedUsdc : 0;
    }

    function buildPartialCloseUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        uint256 excludedOtherLocked = committedOrderMarginUsdc + reservedSettlementUsdc;
        uint256 effectiveSettlementBalance =
            settlementBalanceUsdc > excludedOtherLocked ? settlementBalanceUsdc - excludedOtherLocked : 0;

        return buildAccountUsdcBuckets(effectiveSettlementBalance, positionMarginUsdc, 0, 0);
    }

    function getGenericReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets
    ) internal pure returns (uint256 reachableUsdc) {
        reachableUsdc = buckets.settlementBalanceUsdc > buckets.otherLockedMarginUsdc
            ? buckets.settlementBalanceUsdc - buckets.otherLockedMarginUsdc
            : 0;
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

    function planOpenCostApplication(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (OpenCostPlan memory plan) {
        plan.netMarginChangeUsdc = int256(marginDeltaUsdc) - tradeCostUsdc;

        uint256 settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        uint256 positionMarginUsdc = buckets.activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;

        if (tradeCostUsdc < 0) {
            plan.settlementCreditUsdc = uint256(-tradeCostUsdc);
            settlementBalanceUsdc += plan.settlementCreditUsdc;
        }

        if (plan.netMarginChangeUsdc < 0) {
            plan.positionMarginUnlockedUsdc = uint256(-plan.netMarginChangeUsdc);
            if (plan.positionMarginUnlockedUsdc > positionMarginUsdc) {
                plan.insufficientPositionMargin = true;
                return plan;
            }
            positionMarginUsdc -= plan.positionMarginUnlockedUsdc;
        }

        uint256 totalLockedMarginUsdc = positionMarginUsdc + otherLockedMarginUsdc;
        uint256 freeSettlementUsdc = settlementBalanceUsdc > totalLockedMarginUsdc
            ? settlementBalanceUsdc - totalLockedMarginUsdc
            : 0;

        if (tradeCostUsdc > 0) {
            plan.settlementDebitUsdc = uint256(tradeCostUsdc);
            if (plan.settlementDebitUsdc > freeSettlementUsdc) {
                plan.insufficientFreeEquity = true;
                return plan;
            }
            settlementBalanceUsdc -= plan.settlementDebitUsdc;
            freeSettlementUsdc -= plan.settlementDebitUsdc;
        }

        if (plan.netMarginChangeUsdc > 0) {
            plan.positionMarginLockedUsdc = uint256(plan.netMarginChangeUsdc);
            if (plan.positionMarginLockedUsdc > freeSettlementUsdc) {
                plan.insufficientFreeEquity = true;
                return plan;
            }
            positionMarginUsdc += plan.positionMarginLockedUsdc;
            freeSettlementUsdc -= plan.positionMarginLockedUsdc;
        }

        plan.resultingSettlementBalanceUsdc = settlementBalanceUsdc;
        plan.resultingPositionMarginUsdc = positionMarginUsdc;
        plan.resultingFreeSettlementUsdc = freeSettlementUsdc;
    }

    function getTerminalReachableUsdc(
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
        IMarginClearinghouse.AccountUsdcBuckets memory,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.positionMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
    }

    function applyTerminalLossMutation(
        IMarginClearinghouse.AccountUsdcBuckets memory,
        uint256,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.positionMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
        mutation.otherLockedMarginUnlockedUsdc = consumption.otherLockedMarginConsumedUsdc;
    }

    function planLiquidationResidual(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        int256 residualUsdc
    ) internal pure returns (LiquidationResidualPlan memory plan) {
        uint256 reachableUsdc = getTerminalReachableUsdc(buckets);

        if (residualUsdc >= 0) {
            plan.settlementRetainedUsdc = reachableUsdc > uint256(residualUsdc) ? uint256(residualUsdc) : reachableUsdc;
            plan.settlementSeizedUsdc = reachableUsdc - plan.settlementRetainedUsdc;
            plan.freshTraderPayoutUsdc = uint256(residualUsdc) - plan.settlementRetainedUsdc;
        } else {
            plan.settlementRetainedUsdc = 0;
            plan.settlementSeizedUsdc = reachableUsdc;
            plan.badDebtUsdc = uint256(-residualUsdc);
        }

        plan.mutation.settlementDebitUsdc = plan.settlementSeizedUsdc;
        plan.mutation.positionMarginUnlockedUsdc = buckets.activePositionMarginUsdc;
        plan.mutation.otherLockedMarginUnlockedUsdc = plan.settlementSeizedUsdc
            > buckets.freeSettlementUsdc + buckets.activePositionMarginUsdc
            ? plan.settlementSeizedUsdc - buckets.freeSettlementUsdc - buckets.activePositionMarginUsdc
            : 0;
    }

}
