// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

/// @title MarginClearinghouseAccountingLib
/// @notice Pure plans for classifying account settlement token, applying open costs, consuming losses, and settling liquidations.
/// @dev All amounts use 6-decimal settlement token. A clearinghouse settlement balance includes its locked margin; bucket helpers
///      classify portions of that balance rather than adding independent assets. Callers must supply internally
///      consistent snapshots and apply returned mutations atomically.
library MarginClearinghouseAccountingLib {

    /// @notice Priority breakdown for a requested settlement loss.
    /// @param freeSettlementConsumedAssets Portion consumed from unlocked settlement under the selected loss policy.
    /// @param activeMarginConsumedAssets Portion consumed from active-position margin under the selected loss policy.
    /// @param otherLockedMarginConsumedAssets Portion consumed from other locked margin; zero on the carry-loss path.
    /// @param totalConsumedAssets Total settlement balance to debit.
    /// @param uncoveredAssets Requested loss not covered by eligible settlement balance.
    struct SettlementConsumption {
        uint256 freeSettlementConsumedAssets;
        uint256 activeMarginConsumedAssets;
        uint256 otherLockedMarginConsumedAssets;
        uint256 totalConsumedAssets;
        uint256 uncoveredAssets;
    }

    /// @notice Clearinghouse mutation corresponding to a consumption plan.
    /// @param settlementDebitAssets Total account settlement balance to remove.
    /// @param positionMarginUnlockedAssets Active-position margin removed from lock classification; loss paths consume it
    ///        toward the debit, while liquidation may leave some unlocked settlement retained by the account.
    /// @param otherLockedMarginUnlockedAssets Other locked margin consumed and removed from lock classification.
    struct BucketMutation {
        uint256 settlementDebitAssets;
        uint256 positionMarginUnlockedAssets;
        uint256 otherLockedMarginUnlockedAssets;
    }

    /// @notice Planned settlement and position-margin mutations for an open or increase.
    /// @dev Resulting balances are populated only when both insufficiency flags are false. Mutation fields populated
    ///      before a failing check are diagnostic and must not be applied.
    /// @param netMarginChangeAssets Nonnegative PnL-pledge increase funded by this action's margin contribution after
    ///        its positive trade cost; rebates never increase pledge and costs never decrease pre-existing pledge.
    /// @param settlementCreditAssets Rebate credited when trade cost is negative.
    /// @param settlementDebitAssets Positive trade cost debited from settlement.
    /// @param positionMarginLockedAssets Active margin added when net margin change is positive.
    /// @param resultingSettlementBalanceAssets Settlement balance after rebate or positive-cost debit.
    /// @param resultingPositionMarginAssets Active-position margin after unlock or lock.
    /// @param resultingFreeSettlementAssets Free settlement after every planned mutation.
    /// @param insufficientFreeEquity Whether a debit or margin lock exceeds free settlement.
    struct OpenCostPlan {
        int256 netMarginChangeAssets;
        uint256 settlementCreditAssets;
        uint256 settlementDebitAssets;
        uint256 positionMarginLockedAssets;
        uint256 resultingSettlementBalanceAssets;
        uint256 resultingPositionMarginAssets;
        uint256 resultingFreeSettlementAssets;
        bool insufficientFreeEquity;
    }

    /// @notice Full PnL-pledge unlock selected by isolated liquidation planning.
    /// @param mutation Current planner populates only the full PnL-pledge unlock; other fields remain zero.
    struct LiquidationResidualPlan {
        BucketMutation mutation;
    }

    /// @notice Classifies settlement under the V3 PnL-isolation bucket model.
    /// @dev `pnlPledgeAssets` is the only active margin reachable by position price-loss paths. Liquidation, order, and
    ///      action reserves are all reported in `otherLockedMarginAssets` and remain excluded unless a dedicated path
    ///      explicitly consumes them.
    function buildIsolatedAccountAssetBuckets(
        uint256 settlementBalanceAssets,
        uint256 pnlPledgeAssets,
        uint256 liquidationReserveAssets,
        uint256 orderMarginAssets,
        uint256 actionReserveAssets
    ) internal pure returns (IMarginClearinghouse.AccountAssetBuckets memory buckets) {
        buckets.settlementBalanceAssets = settlementBalanceAssets;
        buckets.activePositionMarginAssets = pnlPledgeAssets;
        buckets.otherLockedMarginAssets = liquidationReserveAssets + orderMarginAssets + actionReserveAssets;
        buckets.totalLockedMarginAssets =
            pnlPledgeAssets + liquidationReserveAssets + orderMarginAssets + actionReserveAssets;

        uint256 encumberedAssets = buckets.totalLockedMarginAssets;
        buckets.freeSettlementAssets =
            buckets.settlementBalanceAssets > encumberedAssets ? buckets.settlementBalanceAssets - encumberedAssets : 0;
    }

    /// @notice Plans carry-loss collection from active position margin, then free settlement.
    /// @dev Other locked buckets and trader claims remain protected. Uncovered carry is retained until collection or
    ///      terminal recovery/waiver; it is never converted into position price-loss debt.
    /// @param buckets Account bucket snapshot.
    /// @param lossAssets Carry loss requested for collection.
    /// @return consumption Free/active consumption, total debit, and uncovered remainder.
    function planCarryLossConsumption(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 lossAssets
    ) internal pure returns (SettlementConsumption memory consumption) {
        consumption.activeMarginConsumedAssets =
            buckets.activePositionMarginAssets < lossAssets ? buckets.activePositionMarginAssets : lossAssets;
        uint256 remainderAssets = lossAssets - consumption.activeMarginConsumedAssets;
        consumption.freeSettlementConsumedAssets =
            buckets.freeSettlementAssets < remainderAssets ? buckets.freeSettlementAssets : remainderAssets;
        consumption.totalConsumedAssets =
            consumption.activeMarginConsumedAssets + consumption.freeSettlementConsumedAssets;
        consumption.uncoveredAssets = lossAssets - consumption.totalConsumedAssets;
    }

    /// @notice Projects carry allocation and the resulting account collateral without changing the input snapshot.
    /// @dev Requires canonical, internally consistent buckets. Returns a fresh bucket object: callers can retain raw
    ///      custody for diagnostics while using projected margin for price equity and projected free cash for actions.
    ///      Claims and other locked buckets are not carry funding sources. Uncovered carry remains an obligation.
    function projectCarryLoss(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 pendingCarryAssets
    )
        internal
        pure
        returns (SettlementConsumption memory consumption, IMarginClearinghouse.AccountAssetBuckets memory afterBuckets)
    {
        consumption = planCarryLossConsumption(buckets, pendingCarryAssets);
        afterBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: buckets.settlementBalanceAssets - consumption.totalConsumedAssets,
            totalLockedMarginAssets: buckets.totalLockedMarginAssets - consumption.activeMarginConsumedAssets,
            activePositionMarginAssets: buckets.activePositionMarginAssets - consumption.activeMarginConsumedAssets,
            otherLockedMarginAssets: buckets.otherLockedMarginAssets,
            freeSettlementAssets: buckets.freeSettlementAssets - consumption.freeSettlementConsumedAssets
        });
    }

    /// @notice Plans how signed action cost and newly supplied margin change settlement and PnL pledge.
    /// @dev Positive cost may consume this action's supplied margin before it becomes pledge. Any excess must come
    ///      from pre-existing free settlement. It never unlocks existing pledge. A negative cost is credited as free
    ///      settlement and never increases pledge. Other locked buckets remain protected throughout.
    /// @param buckets Account bucket snapshot before the open/increase.
    /// @param marginDeltaAssets Margin supplied by the order.
    /// @param tradeCostAssets Signed VPI plus fee; positive is a debit and negative is a rebate.
    /// @return plan Planned mutations and resulting balances, or an insufficiency flag.
    function planOpenCostApplication(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets
    ) internal pure returns (OpenCostPlan memory plan) {
        uint256 settlementBalanceAssets = buckets.settlementBalanceAssets;
        uint256 positionMarginAssets = buckets.activePositionMarginAssets;
        uint256 otherLockedMarginAssets = buckets.otherLockedMarginAssets;

        if (tradeCostAssets < 0) {
            plan.settlementCreditAssets = uint256(-tradeCostAssets);
            settlementBalanceAssets += plan.settlementCreditAssets;
        }

        uint256 totalLockedMarginAssets = positionMarginAssets + otherLockedMarginAssets;
        uint256 freeSettlementAssets =
            settlementBalanceAssets > totalLockedMarginAssets ? settlementBalanceAssets - totalLockedMarginAssets : 0;

        if (tradeCostAssets > 0) {
            plan.settlementDebitAssets = uint256(tradeCostAssets);
            if (plan.settlementDebitAssets > freeSettlementAssets) {
                plan.insufficientFreeEquity = true;
                return plan;
            }
            settlementBalanceAssets -= plan.settlementDebitAssets;
            freeSettlementAssets -= plan.settlementDebitAssets;
        }

        uint256 actionCostFundedByMarginAssets;
        if (tradeCostAssets > 0) {
            uint256 positiveCostAssets = uint256(tradeCostAssets);
            actionCostFundedByMarginAssets =
                positiveCostAssets < marginDeltaAssets ? positiveCostAssets : marginDeltaAssets;
        }
        plan.positionMarginLockedAssets = marginDeltaAssets - actionCostFundedByMarginAssets;
        plan.netMarginChangeAssets = int256(plan.positionMarginLockedAssets);
        if (plan.positionMarginLockedAssets > 0) {
            if (plan.positionMarginLockedAssets > freeSettlementAssets) {
                plan.insufficientFreeEquity = true;
                return plan;
            }
            positionMarginAssets += plan.positionMarginLockedAssets;
            freeSettlementAssets -= plan.positionMarginLockedAssets;
        }

        plan.resultingSettlementBalanceAssets = settlementBalanceAssets;
        plan.resultingPositionMarginAssets = positionMarginAssets;
        plan.resultingFreeSettlementAssets = freeSettlementAssets;
    }

    /// @notice Returns all settlement balance reachable during terminal position settlement.
    /// @dev Equivalent to `getSettlementReachableAssets(buckets, 0)`; lock classifications do not protect value.
    /// @param buckets Account bucket snapshot.
    /// @return reachableAssets Entire `settlementBalanceAssets`.
    function getTerminalReachableAssets(
        IMarginClearinghouse.AccountAssetBuckets memory buckets
    ) internal pure returns (uint256 reachableAssets) {
        reachableAssets = getSettlementReachableAssets(buckets, 0);
    }

    /// @notice Returns settlement balance above an explicitly protected locked amount.
    /// @dev The subtraction saturates at zero and does not inspect which lock bucket supplies the protected amount.
    /// @param buckets Account bucket snapshot.
    /// @param protectedLockedMarginAssets Settlement amount that must remain unreachable.
    /// @return reachableAssets `max(settlementBalanceAssets - protectedLockedMarginAssets, 0)`.
    function getSettlementReachableAssets(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 protectedLockedMarginAssets
    ) internal pure returns (uint256 reachableAssets) {
        uint256 protectedBalance = protectedLockedMarginAssets;
        uint256 settlementBalanceAssets = buckets.settlementBalanceAssets;
        reachableAssets = settlementBalanceAssets > protectedBalance ? settlementBalanceAssets - protectedBalance : 0;
    }

    /// @notice Converts a carry-loss consumption plan into clearinghouse mutation amounts.
    /// @dev Other locked margin is not unlocked on this path.
    /// @param consumption Carry-loss allocation to convert.
    /// @return mutation Settlement debit and active-position margin consumption.
    function applyCarryLossMutation(
        SettlementConsumption memory consumption
    ) internal pure returns (BucketMutation memory mutation) {
        mutation.settlementDebitAssets = consumption.totalConsumedAssets;
        mutation.positionMarginUnlockedAssets = consumption.activeMarginConsumedAssets;
    }

}
