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
    /// @param freeSettlementConsumedUsdc Unlocked settlement consumed first.
    /// @param activeMarginConsumedUsdc Active-position margin consumed after free settlement.
    /// @param otherLockedMarginConsumedUsdc Other locked margin consumed last; zero on the carry-loss path.
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
    /// @param netMarginChangeUsdc Signed `marginDeltaUsdc - tradeCostUsdc`; positive locks margin, negative unlocks it.
    /// @param settlementCreditUsdc Rebate credited when trade cost is negative.
    /// @param settlementDebitUsdc Positive trade cost debited from settlement.
    /// @param positionMarginUnlockedUsdc Active margin released when net margin change is negative.
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

    /// @notice Planned account disposition after removing a liquidated position and paying a keeper bounty.
    /// @param keeperBountyUsdc Requested bounty debited from the liquidated account.
    /// @param settlementRetainedUsdc Existing settlement left in the account toward positive residual equity.
    /// @param settlementSeizedUsdc Existing settlement transferred away after bounty and retained equity.
    /// @param freshTraderPayoutUsdc New value required to satisfy positive residual equity.
    /// @param badDebtUsdc Magnitude of negative residual equity; seizure is not subtracted from this field.
    /// @param mutation Settlement debit and locked-margin consumption required to apply the plan.
    struct LiquidationResidualPlan {
        uint256 keeperBountyUsdc;
        uint256 settlementRetainedUsdc;
        uint256 settlementSeizedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 badDebtUsdc;
        BucketMutation mutation;
    }

    /// @notice Classifies an account's settlement balance into active, other-locked, total-locked, and free buckets.
    /// @dev `freeSettlementUsdc` is `settlementBalanceUsdc - totalLockedMarginUsdc`, floored at zero. Locked amounts are
    ///      assumed to be components of the settlement balance. Additions use checked Solidity arithmetic.
    /// @param settlementBalanceUsdc Total internal USDC balance held for the account.
    /// @param positionMarginUsdc Portion locked to active positions.
    /// @param committedOrderMarginUsdc Portion locked for committed open orders.
    /// @param reservedSettlementUsdc Portion protected as reserved settlement.
    /// @return buckets Aggregate clearinghouse classification of the supplied values.
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

    /// @notice Builds a close-loss view that excludes all other locked margin from both balance and lock totals.
    /// @dev Committed-order plus reserved settlement is subtracted from the supplied settlement balance with a zero
    ///      floor. The returned `settlementBalanceUsdc` is therefore an effective balance, not the original account
    ///      balance; only position margin remains classified as locked.
    /// @param settlementBalanceUsdc Total internal USDC balance before excluding other locked margin.
    /// @param positionMarginUsdc Active-position margin retained in the effective view.
    /// @param committedOrderMarginUsdc Committed-order margin to exclude.
    /// @param reservedSettlementUsdc Reserved settlement to exclude.
    /// @return buckets Effective close-loss buckets protecting all other locked margin.
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

    /// @notice Returns collateral reachable while protecting all other locked margin.
    /// @dev The result is `settlementBalanceUsdc - otherLockedMarginUsdc`, floored at zero, so it includes both free
    ///      settlement and active-position margin. `totalLockedMarginUsdc` is not read.
    /// @param buckets Account bucket snapshot.
    /// @return reachableUsdc Generic reachable collateral in 6-decimal USDC.
    function getGenericReachableUsdc(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets
    ) internal pure returns (uint256 reachableUsdc) {
        uint256 settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        uint256 queuedReservedUsdc = buckets.otherLockedMarginUsdc;
        reachableUsdc = settlementBalanceUsdc > queuedReservedUsdc ? settlementBalanceUsdc - queuedReservedUsdc : 0;
    }

    /// @notice Plans carry-loss collection from free settlement first and active-position margin second.
    /// @dev Other locked margin is never consumed. If eligible collateral is insufficient, the remainder is reported
    ///      in `uncoveredUsdc`. The priority split involves no division or rounding.
    /// @param buckets Account bucket snapshot.
    /// @param lossUsdc Carry loss requested for collection.
    /// @return consumption Free/active consumption, total debit, and uncovered remainder.
    function planCarryLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        uint256 freeSettlementUsdc = buckets.freeSettlementUsdc;
        consumption.freeSettlementConsumedUsdc = freeSettlementUsdc > lossUsdc ? lossUsdc : freeSettlementUsdc;

        uint256 remainingLossUsdc = lossUsdc - consumption.freeSettlementConsumedUsdc;
        uint256 positionMarginUsdc = buckets.activePositionMarginUsdc;
        consumption.activeMarginConsumedUsdc =
            positionMarginUsdc > remainingLossUsdc ? remainingLossUsdc : positionMarginUsdc;
        consumption.totalConsumedUsdc = consumption.freeSettlementConsumedUsdc + consumption.activeMarginConsumedUsdc;
        consumption.uncoveredUsdc = remainingLossUsdc - consumption.activeMarginConsumedUsdc;
    }

    /// @notice Plans how signed trade cost and supplied margin change settlement and active-position margin.
    /// @dev A negative trade cost first credits settlement and increases net margin change. A negative net margin
    ///      change then unlocks position margin. Free settlement is recomputed before a positive trade-cost debit and
    ///      any positive net-margin lock, in that order. Other locked margin remains protected throughout. Inputs must
    ///      fit signed arithmetic (`marginDeltaUsdc` is cast to `int256` and the minimum int cannot be negated).
    /// @param buckets Account bucket snapshot before the open/increase.
    /// @param marginDeltaUsdc Margin supplied by the order.
    /// @param tradeCostUsdc Signed VPI plus fee; positive is a debit and negative is a rebate.
    /// @return plan Planned mutations and resulting balances, or an insufficiency flag.
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

    /// @notice Plans terminal loss collection while leaving an explicit amount of settlement protected.
    /// @dev Collection is capped by settlement balance above `protectedLockedMarginUsdc` and classified in priority
    ///      order as free settlement, consumable active margin, then other locked margin. Consumable active margin is
    ///      `max(activePositionMarginUsdc - protectedLockedMarginUsdc, 0)`. Consistent input buckets are required for
    ///      the residual classification to correspond to actual lock balances.
    /// @param buckets Account bucket snapshot.
    /// @param protectedLockedMarginUsdc Locked settlement that must survive collection, normally remaining position margin.
    /// @param lossUsdc Terminal loss requested for collection.
    /// @return consumption Priority allocation, total debit, and uncovered loss.
    function planTerminalLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        uint256 reachableUsdc = getSettlementReachableUsdc(buckets, protectedLockedMarginUsdc);
        consumption.totalConsumedUsdc = reachableUsdc > lossUsdc ? lossUsdc : reachableUsdc;
        consumption.uncoveredUsdc = lossUsdc - consumption.totalConsumedUsdc;
        uint256 freeSettlementUsdc = buckets.freeSettlementUsdc;
        consumption.freeSettlementConsumedUsdc =
            freeSettlementUsdc > consumption.totalConsumedUsdc ? consumption.totalConsumedUsdc : freeSettlementUsdc;

        uint256 remainingConsumedUsdc = consumption.totalConsumedUsdc - consumption.freeSettlementConsumedUsdc;
        uint256 positionMarginUsdc = buckets.activePositionMarginUsdc;
        uint256 consumableActiveMarginUsdc =
            positionMarginUsdc > protectedLockedMarginUsdc ? positionMarginUsdc - protectedLockedMarginUsdc : 0;
        consumption.activeMarginConsumedUsdc =
            consumableActiveMarginUsdc > remainingConsumedUsdc ? remainingConsumedUsdc : consumableActiveMarginUsdc;
        consumption.otherLockedMarginConsumedUsdc = remainingConsumedUsdc - consumption.activeMarginConsumedUsdc;
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

    /// @notice Converts a terminal-loss consumption plan into clearinghouse mutation amounts.
    /// @dev The bucket snapshot and protected amount are accepted for plan/apply API symmetry but are not revalidated
    ///      or read; callers must pair the mutation with the plan derived from those inputs.
    /// @param consumption Terminal-loss allocation to convert.
    /// @return mutation Settlement debit plus active and other locked-margin consumption.
    function applyTerminalLossMutation(
        IMarginClearinghouse.AccountUsdcBuckets memory,
        uint256,
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitUsdc = consumption.totalConsumedUsdc;
        mutation.positionMarginUnlockedUsdc = consumption.activeMarginConsumedUsdc;
        mutation.otherLockedMarginUnlockedUsdc = consumption.otherLockedMarginConsumedUsdc;
    }

    /// @notice Plans liquidation residual settlement without a keeper bounty.
    /// @param buckets Terminal account bucket snapshot.
    /// @param residualUsdc Signed post-liquidation equity; positive is owed to the trader and negative is bad debt.
    /// @return plan Retention, seizure, fresh-payout, bad-debt, and bucket-mutation plan.
    function planLiquidationResidual(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        int256 residualUsdc
    ) internal pure returns (LiquidationResidualPlan memory plan) {
        return planLiquidationResidual(buckets, residualUsdc, 0);
    }

    /// @notice Plans terminal account settlement for residual equity after reserving a keeper bounty.
    /// @dev The bounty is subtracted from reachable settlement with a zero floor. For nonnegative residual equity,
    ///      remaining settlement is retained up to the residual, excess is seized, and any deficit is a fresh payout.
    ///      For negative residual equity, all post-bounty reachable settlement is seized and the full residual magnitude
    ///      is reported as bad debt. The mutation always unlocks/declassifies the full active-position margin, while
    ///      other locked margin is consumed only for the debit beyond free settlement plus active margin. Canonical
    ///      callers cap the bounty to terminal reachable settlement; otherwise `mutation.settlementDebitUsdc` can
    ///      exceed the balance. `type(int256).min` cannot be negated and reverts on the negative-residual path.
    /// @param buckets Terminal account bucket snapshot.
    /// @param residualUsdc Signed equity remaining after PnL, carry, VPI, and liquidation economics.
    /// @param keeperBountyUsdc Keeper bounty to debit before retaining or seizing residual settlement.
    /// @return plan Retention, seizure, payout, bad-debt, and clearinghouse mutation values.
    function planLiquidationResidual(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        int256 residualUsdc,
        uint256 keeperBountyUsdc
    ) internal pure returns (LiquidationResidualPlan memory plan) {
        uint256 reachableUsdc = getTerminalReachableUsdc(buckets);
        plan.keeperBountyUsdc = keeperBountyUsdc;
        uint256 reachableAfterBountyUsdc = reachableUsdc > keeperBountyUsdc ? reachableUsdc - keeperBountyUsdc : 0;

        if (residualUsdc >= 0) {
            plan.settlementRetainedUsdc =
                reachableAfterBountyUsdc > uint256(residualUsdc) ? uint256(residualUsdc) : reachableAfterBountyUsdc;
            plan.settlementSeizedUsdc = reachableAfterBountyUsdc - plan.settlementRetainedUsdc;
            plan.freshTraderPayoutUsdc = uint256(residualUsdc) - plan.settlementRetainedUsdc;
        } else {
            plan.settlementRetainedUsdc = 0;
            plan.settlementSeizedUsdc = reachableAfterBountyUsdc;
            plan.badDebtUsdc = uint256(-residualUsdc);
        }

        plan.mutation.settlementDebitUsdc = plan.settlementSeizedUsdc + keeperBountyUsdc;
        uint256 freeSettlementUsdc = buckets.freeSettlementUsdc;
        uint256 positionMarginUsdc = buckets.activePositionMarginUsdc;
        plan.mutation.positionMarginUnlockedUsdc = positionMarginUsdc;
        plan.mutation.otherLockedMarginUnlockedUsdc = plan.mutation.settlementDebitUsdc
            > freeSettlementUsdc + positionMarginUsdc
            ? plan.mutation.settlementDebitUsdc - freeSettlementUsdc - positionMarginUsdc
            : 0;
    }

}
