// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library HousePoolWaterfallAccountingLib {

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    struct WaterfallState {
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 unpaidSeniorYield;
        uint256 seniorHighWaterMark;
    }

    struct ReconcilePlan {
        uint256 yieldAccrued;
        bool isRevenue;
        uint256 deltaUsdc;
    }

    function accrueSeniorYield(
        uint256 seniorPrincipal,
        uint256 seniorRateBps,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (elapsed == 0 || seniorPrincipal == 0) {
            return 0;
        }
        return (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
    }

    function planReconcile(
        uint256 seniorPrincipal,
        uint256 juniorPrincipal,
        uint256 distributableUsdc,
        uint256 seniorRateBps,
        uint256 elapsed
    ) internal pure returns (ReconcilePlan memory plan) {
        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        plan.yieldAccrued = accrueSeniorYield(seniorPrincipal, seniorRateBps, elapsed);
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
        nextState.unpaidSeniorYield = state.unpaidSeniorYield * remaining / state.seniorPrincipal;
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

        uint256 seniorPayout = nextState.unpaidSeniorYield;
        if (seniorPayout > remaining) {
            seniorPayout = remaining;
        }
        nextState.seniorPrincipal += seniorPayout;
        nextState.unpaidSeniorYield -= seniorPayout;
        remaining -= seniorPayout;

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
            nextState.unpaidSeniorYield = 0;
        }
    }

}
