// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title HousePoolWaterfallAccountingLib
/// @notice Pure senior/junior principal accounting for coupon, revenue, loss, and senior withdrawal events.
/// @dev Principal and coupon values use 6-decimal USDC, rates use basis points, and elapsed time uses seconds.
///      Integer divisions round down. The high-water mark tracks unimpaired senior entitlement: losses do not reduce
///      it, while senior withdrawals scale it and senior gains above it increase it. Unless a function explicitly
///      saturates a subtraction, arithmetic is checked and reverts on overflow or underflow.
library HousePoolWaterfallAccountingLib {

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;
    /// @notice Seconds in the 365-day year used for simple annualized coupon accrual.
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice Current claimant principal and senior unimpaired entitlement.
    /// @param seniorPrincipal Current value attributed to senior claimants.
    /// @param juniorPrincipal Current value attributed to junior claimants.
    /// @param seniorHighWaterMark Senior principal target restored before revenue reaches junior claimants.
    struct WaterfallState {
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 seniorHighWaterMark;
    }

    /// @notice Difference between distributable assets and claimed principal.
    /// @param isRevenue True when distributable assets exceed claimed principal; false for loss or exact equality.
    /// @param deltaUsdc Absolute difference; zero when the two values are equal.
    struct ReconcilePlan {
        bool isRevenue;
        uint256 deltaUsdc;
    }

    /// @notice Calculates simple annualized coupon due on current senior principal.
    /// @dev Returns zero when elapsed time or principal is zero. The result is
    ///      `floor(seniorPrincipal * seniorRateBps * elapsed / (10_000 * 365 days))`.
    /// @param seniorPrincipal Coupon-bearing senior principal in 6-decimal USDC.
    /// @param seniorRateBps Annualized coupon rate in basis points.
    /// @param elapsed Accrual interval in seconds.
    /// @return Coupon due in 6-decimal USDC, rounded down.
    function calculateSeniorCoupon(
        uint256 seniorPrincipal,
        uint256 seniorRateBps,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (elapsed == 0 || seniorPrincipal == 0) {
            return 0;
        }
        return (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
    }

    /// @notice Transfers the accrued senior coupon from junior principal to senior principal.
    /// @dev Payment is capped by junior principal. Paid coupon first restores senior impairment without changing the
    ///      high-water mark; any excess increases senior principal and its high-water mark equally. If coupon due or
    ///      junior principal is zero, state is unchanged. Arithmetic in coupon calculation rounds down.
    /// @param state Waterfall state before coupon payment.
    /// @param seniorRateBps Annualized senior coupon rate in basis points.
    /// @param elapsed Accrual interval in seconds.
    /// @return nextState Waterfall after the junior-to-senior transfer.
    /// @return couponPaid Actual coupon transferred, capped by junior principal.
    function paySeniorCoupon(
        WaterfallState memory state,
        uint256 seniorRateBps,
        uint256 elapsed
    ) internal pure returns (WaterfallState memory nextState, uint256 couponPaid) {
        nextState = state;
        uint256 couponDue = calculateSeniorCoupon(state.seniorPrincipal, seniorRateBps, elapsed);
        if (couponDue == 0 || state.juniorPrincipal == 0) {
            return (nextState, 0);
        }

        couponPaid = couponDue < state.juniorPrincipal ? couponDue : state.juniorPrincipal;
        nextState.juniorPrincipal -= couponPaid;

        uint256 remaining = couponPaid;
        if (nextState.seniorPrincipal < nextState.seniorHighWaterMark) {
            uint256 deficit = nextState.seniorHighWaterMark - nextState.seniorPrincipal;
            uint256 restore = remaining < deficit ? remaining : deficit;
            nextState.seniorPrincipal += restore;
            remaining -= restore;
        }

        if (remaining > 0) {
            nextState.seniorPrincipal += remaining;
            nextState.seniorHighWaterMark += remaining;
        }
    }

    /// @notice Compares distributable assets with total senior and junior principal.
    /// @param seniorPrincipal Current senior claim in 6-decimal USDC.
    /// @param juniorPrincipal Current junior claim in 6-decimal USDC.
    /// @param distributableUsdc Assets available to back claimant principal.
    /// @return plan Revenue/loss direction and absolute delta; exact equality returns zero and `isRevenue == false`.
    function planReconcile(
        uint256 seniorPrincipal,
        uint256 juniorPrincipal,
        uint256 distributableUsdc
    ) internal pure returns (ReconcilePlan memory plan) {
        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (distributableUsdc > claimedEquity) {
            plan.isRevenue = true;
            plan.deltaUsdc = distributableUsdc - claimedEquity;
        } else if (distributableUsdc < claimedEquity) {
            plan.deltaUsdc = claimedEquity - distributableUsdc;
        }
    }

    /// @notice Removes senior principal and scales the senior high-water mark pro rata.
    /// @dev Requires nonzero `state.seniorPrincipal` and `withdrawAmountUsdc <= state.seniorPrincipal`; otherwise
    ///      Solidity division or subtraction reverts. High-water-mark scaling rounds down. Junior principal is unchanged.
    /// @param state Waterfall state before withdrawal.
    /// @param withdrawAmountUsdc Senior principal withdrawn in 6-decimal USDC.
    /// @return nextState State with reduced senior principal and proportionally scaled high-water mark.
    function scaleSeniorOnWithdraw(
        WaterfallState memory state,
        uint256 withdrawAmountUsdc
    ) internal pure returns (WaterfallState memory nextState) {
        nextState = state;
        uint256 remaining = state.seniorPrincipal - withdrawAmountUsdc;
        nextState.seniorHighWaterMark = state.seniorHighWaterMark * remaining / state.seniorPrincipal;
        nextState.seniorPrincipal = remaining;
    }

    /// @notice Distributes revenue by restoring impaired senior principal before crediting junior principal.
    /// @dev Revenue first fills `seniorHighWaterMark - seniorPrincipal`. Remaining revenue accrues to junior principal.
    ///      Independently, a senior principal already above its high-water mark raises the mark to current principal,
    ///      including when `revenueUsdc` is zero.
    /// @param state Waterfall state before revenue.
    /// @param revenueUsdc Revenue to distribute in 6-decimal USDC.
    /// @return nextState State after senior restoration and junior allocation.
    function distributeRevenue(
        WaterfallState memory state,
        uint256 revenueUsdc
    ) internal pure returns (WaterfallState memory nextState) {
        nextState = state;
        uint256 remaining = revenueUsdc;

        if (remaining > 0 && nextState.seniorPrincipal < nextState.seniorHighWaterMark) {
            uint256 deficit = nextState.seniorHighWaterMark - nextState.seniorPrincipal;
            uint256 restore = remaining < deficit ? remaining : deficit;
            nextState.seniorPrincipal += restore;
            remaining -= restore;
        }

        if (nextState.seniorPrincipal > nextState.seniorHighWaterMark) {
            nextState.seniorHighWaterMark = nextState.seniorPrincipal;
        }

        nextState.juniorPrincipal += remaining;
    }

    /// @notice Absorbs loss against junior principal first and senior principal second.
    /// @dev Principal subtraction saturates at zero if loss exceeds all claimed equity. The senior high-water mark is
    ///      deliberately unchanged so future revenue continues to restore senior impairment.
    /// @param state Waterfall state before loss.
    /// @param lossUsdc Loss to absorb in 6-decimal USDC.
    /// @return nextState State after the junior-first loss waterfall.
    function absorbLoss(
        WaterfallState memory state,
        uint256 lossUsdc
    ) internal pure returns (WaterfallState memory nextState) {
        nextState = state;
        if (lossUsdc <= nextState.juniorPrincipal) {
            nextState.juniorPrincipal -= lossUsdc;
            return nextState;
        }

        uint256 seniorLoss = lossUsdc - nextState.juniorPrincipal;
        nextState.juniorPrincipal = 0;
        if (nextState.seniorPrincipal > seniorLoss) {
            nextState.seniorPrincipal -= seniorLoss;
        } else {
            nextState.seniorPrincipal = 0;
        }
    }

}
