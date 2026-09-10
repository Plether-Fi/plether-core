// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

/// @title MarginClearinghouseAccountingLib
/// @notice Pure plans for classifying account USDC, applying open costs, consuming losses, and settling liquidations.
/// @dev All amounts use 6-decimal USDC. A clearinghouse settlement balance includes its locked margin; bucket helpers
///      classify portions of that balance rather than adding independent assets. Callers must supply internally
///      consistent snapshots and apply returned mutations atomically.
library MarginClearinghouseAccountingLib {

    /// @notice Priority breakdown for a requested settlement loss.
    /// @param freeSettlementConsumedUsdc Portion consumed from unlocked settlement under the selected loss policy.
    /// @param activeMarginConsumedUsdc Portion consumed from active-position margin under the selected loss policy.
    /// @param otherLockedMarginConsumedUsdc Portion consumed from other locked margin; zero on the carry-loss path.
    /// @param totalConsumedUsdc Total settlement balance to debit.
    /// @param uncoveredUsdc Requested loss not covered by eligible settlement balance.
    struct SettlementConsumption {
        uint256 freeSettlementConsumedUsdc;
        uint256 activeMarginConsumedUsdc;
        uint256 otherLockedMarginConsumedUsdc;
        uint256 totalConsumedUsdc;
        uint256 uncoveredUsdc;
    }

    /// @notice Clearinghouse mutation corresponding to a consumption plan.
    /// @param settlementDebitUsdc Total account settlement balance to remove.
    /// @param positionMarginUnlockedUsdc Active-position margin removed from lock classification; loss paths consume it
    ///        toward the debit, while liquidation may leave some unlocked settlement retained by the account.
    /// @param otherLockedMarginUnlockedUsdc Other locked margin consumed and removed from lock classification.
    struct BucketMutation {
        uint256 settlementDebitUsdc;
        uint256 positionMarginUnlockedUsdc;
        uint256 otherLockedMarginUnlockedUsdc;
    }

    /// @notice Planned settlement and position-margin mutations for an open or increase.
    /// @dev Resulting balances are populated only when both insufficiency flags are false. Mutation fields populated
    ///      before a failing check are diagnostic and must not be applied.
    /// @param netMarginChangeUsdc Nonnegative PnL-pledge increase funded by this action's margin contribution after
    ///        its positive trade cost; rebates never increase pledge and costs never decrease pre-existing pledge.
    /// @param settlementCreditUsdc Rebate credited when trade cost is negative.
    /// @param settlementDebitUsdc Positive trade cost debited from settlement.
    /// @param positionMarginUnlockedUsdc Retained compatibility field; always zero under V2 pledge isolation.
    /// @param positionMarginLockedUsdc Active margin added when net margin change is positive.
    /// @param resultingSettlementBalanceUsdc Settlement balance after rebate or positive-cost debit.
    /// @param resultingPositionMarginUsdc Active-position margin after unlock or lock.
    /// @param resultingFreeSettlementUsdc Free settlement after every planned mutation.
    /// @param insufficientFreeEquity Whether a debit or margin lock exceeds free settlement.
    /// @param insufficientPositionMargin Whether a requested margin unlock exceeds active-position margin.
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

    /// @notice Planned account disposition after removing a liquidated position and reserving its total charge.
    /// @param liquidationChargeUsdc Total keeper, protocol, and LP charge reserved from the liquidated account.
    /// @param settlementRetainedUsdc Existing settlement left in the account toward positive residual equity.
    /// @param settlementSeizedUsdc Existing settlement transferred away after the charge reserve and retained equity;
    ///        the LP-owned charge is added by the liquidation planner before live settlement.
    /// @param freshTraderPayoutUsdc New value required to satisfy positive residual equity.
    /// @param badDebtUsdc Magnitude of negative residual equity; seizure is not subtracted from this field.
    /// @param mutation Settlement debit and locked-margin consumption required to apply the plan.
    struct LiquidationResidualPlan {
        uint256 liquidationChargeUsdc;
        uint256 settlementRetainedUsdc;
        uint256 settlementSeizedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 badDebtUsdc;
        BucketMutation mutation;
    }

    /// @notice Classifies settlement under the V2 PnL-isolation bucket model.
    /// @dev `pnlPledgeUsdc` is the only active margin reachable by position price-loss paths. Liquidation, order, and
    ///      action reserves are all reported in `otherLockedMarginUsdc` and remain excluded unless a dedicated path
    ///      explicitly consumes them.
    function buildIsolatedAccountUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 pnlPledgeUsdc,
        uint256 liquidationReserveUsdc,
        uint256 orderMarginUsdc,
        uint256 actionReserveUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets.settlementBalanceUsdc = settlementBalanceUsdc;
        buckets.activePositionMarginUsdc = pnlPledgeUsdc;
        buckets.otherLockedMarginUsdc = liquidationReserveUsdc + orderMarginUsdc + actionReserveUsdc;
        buckets.totalLockedMarginUsdc = pnlPledgeUsdc + liquidationReserveUsdc + orderMarginUsdc + actionReserveUsdc;

        uint256 encumberedUsdc = buckets.totalLockedMarginUsdc;
        buckets.freeSettlementUsdc =
            buckets.settlementBalanceUsdc > encumberedUsdc ? buckets.settlementBalanceUsdc - encumberedUsdc : 0;
    }

    /// @notice Plans carry-loss collection from active position margin, then free settlement.
    /// @dev Other locked buckets and trader claims remain protected. Uncovered carry is retained until collection or
    ///      terminal recovery/waiver; it is never converted into position price-loss debt.
    /// @param buckets Account bucket snapshot.
    /// @param lossUsdc Carry loss requested for collection.
    /// @return consumption Free/active consumption, total debit, and uncovered remainder.
    function planCarryLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        consumption.activeMarginConsumedUsdc =
            buckets.activePositionMarginUsdc < lossUsdc ? buckets.activePositionMarginUsdc : lossUsdc;
        uint256 remainderUsdc = lossUsdc - consumption.activeMarginConsumedUsdc;
        consumption.freeSettlementConsumedUsdc =
            buckets.freeSettlementUsdc < remainderUsdc ? buckets.freeSettlementUsdc : remainderUsdc;
        consumption.totalConsumedUsdc = consumption.activeMarginConsumedUsdc + consumption.freeSettlementConsumedUsdc;
        consumption.uncoveredUsdc = lossUsdc - consumption.totalConsumedUsdc;
    }

    /// @notice Projects carry allocation and the resulting account collateral without changing the input snapshot.
    /// @dev Requires canonical, internally consistent buckets. Returns a fresh bucket object: callers can retain raw
    ///      custody for diagnostics while using projected margin for price equity and projected free cash for actions.
    ///      Claims and other locked buckets are not carry funding sources. Uncovered carry remains an obligation.
    function projectCarryLoss(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 pendingCarryUsdc
    )
        internal
        pure
        returns (SettlementConsumption memory consumption, IMarginClearinghouse.AccountUsdcBuckets memory afterBuckets)
    {
        consumption = planCarryLossConsumption(buckets, pendingCarryUsdc);
        afterBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: buckets.settlementBalanceUsdc - consumption.totalConsumedUsdc,
            totalLockedMarginUsdc: buckets.totalLockedMarginUsdc - consumption.activeMarginConsumedUsdc,
            activePositionMarginUsdc: buckets.activePositionMarginUsdc - consumption.activeMarginConsumedUsdc,
            otherLockedMarginUsdc: buckets.otherLockedMarginUsdc,
            freeSettlementUsdc: buckets.freeSettlementUsdc - consumption.freeSettlementConsumedUsdc
        });
    }

    /// @notice Plans how signed action cost and newly supplied margin change settlement and PnL pledge.
    /// @dev Positive cost may consume this action's supplied margin before it becomes pledge. Any excess must come
    ///      from pre-existing free settlement. It never unlocks existing pledge. A negative cost is credited as free
    ///      settlement and never increases pledge. Other locked buckets remain protected throughout.
    /// @param buckets Account bucket snapshot before the open/increase.
    /// @param marginDeltaUsdc Margin supplied by the order.
    /// @param tradeCostUsdc Signed VPI plus fee; positive is a debit and negative is a rebate.
    /// @return plan Planned mutations and resulting balances, or an insufficiency flag.
    function planOpenCostApplication(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (OpenCostPlan memory plan) {
        uint256 settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        uint256 positionMarginUsdc = buckets.activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;

        if (tradeCostUsdc < 0) {
            plan.settlementCreditUsdc = uint256(-tradeCostUsdc);
            settlementBalanceUsdc += plan.settlementCreditUsdc;
        }

        uint256 totalLockedMarginUsdc = positionMarginUsdc + otherLockedMarginUsdc;
        uint256 freeSettlementUsdc =
            settlementBalanceUsdc > totalLockedMarginUsdc ? settlementBalanceUsdc - totalLockedMarginUsdc : 0;

        if (tradeCostUsdc > 0) {
            plan.settlementDebitUsdc = uint256(tradeCostUsdc);
            if (plan.settlementDebitUsdc > freeSettlementUsdc) {
                plan.insufficientFreeEquity = true;
                return plan;
            }
            settlementBalanceUsdc -= plan.settlementDebitUsdc;
            freeSettlementUsdc -= plan.settlementDebitUsdc;
        }

        uint256 actionCostFundedByMarginUsdc;
        if (tradeCostUsdc > 0) {
            uint256 positiveCostUsdc = uint256(tradeCostUsdc);
            actionCostFundedByMarginUsdc = positiveCostUsdc < marginDeltaUsdc ? positiveCostUsdc : marginDeltaUsdc;
        }
        plan.positionMarginLockedUsdc = marginDeltaUsdc - actionCostFundedByMarginUsdc;
        plan.netMarginChangeUsdc = int256(plan.positionMarginLockedUsdc);
        if (plan.positionMarginLockedUsdc > 0) {
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

    /// @notice Returns all settlement balance reachable during terminal position settlement.
    /// @dev Equivalent to `getSettlementReachableUsdc(buckets, 0)`; lock classifications do not protect value.
    /// @param buckets Account bucket snapshot.
    /// @return reachableUsdc Entire `settlementBalanceUsdc`.
    function getTerminalReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets
    ) internal pure returns (uint256 reachableUsdc) {
        reachableUsdc = getSettlementReachableUsdc(buckets, 0);
    }

    /// @notice Returns settlement balance above an explicitly protected locked amount.
    /// @dev The subtraction saturates at zero and does not inspect which lock bucket supplies the protected amount.
    /// @param buckets Account bucket snapshot.
    /// @param protectedLockedMarginUsdc Settlement amount that must remain unreachable.
    /// @return reachableUsdc `max(settlementBalanceUsdc - protectedLockedMarginUsdc, 0)`.
    function getSettlementReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc
    ) internal pure returns (uint256 reachableUsdc) {
        uint256 protectedBalance = protectedLockedMarginUsdc;
        uint256 settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        reachableUsdc = settlementBalanceUsdc > protectedBalance ? settlementBalanceUsdc - protectedBalance : 0;
    }

    /// @notice Converts a carry-loss consumption plan into clearinghouse mutation amounts.
    /// @dev The bucket snapshot is accepted for plan/apply API symmetry but is not read. Other locked margin is not
    ///      unlocked on this path.
    /// @param consumption Carry-loss allocation to convert.
    /// @return mutation Settlement debit and active-position margin consumption.
    function applyCarryLossMutation(
        IMarginClearinghouse.AccountUsdcBuckets memory,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.positionMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
    }

}
