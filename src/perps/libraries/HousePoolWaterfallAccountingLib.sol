// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolWaterfallAccountingLib {

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    struct WaterfallState {
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 seniorHighWaterMark;
    }

    struct ReconcilePlan {
        bool isRevenue;
        uint256 deltaUsdc;
    }

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

    function scaleSeniorOnWithdraw(
        WaterfallState memory state,
        uint256 withdrawAmountUsdc
    ) internal pure returns (WaterfallState memory nextState) {
        nextState = state;
        uint256 remaining = state.seniorPrincipal - withdrawAmountUsdc;
        nextState.seniorHighWaterMark = state.seniorHighWaterMark * remaining / state.seniorPrincipal;
        nextState.seniorPrincipal = remaining;
    }

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
