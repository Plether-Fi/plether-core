// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library MarginClearinghouseAccountingLib {

    struct AccountUsdcBuckets {
        uint256 settlementBalanceUsdc;
        uint256 reservedSettlementUsdc;
        uint256 totalLockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
    }

    struct SettlementConsumption {
        uint256 freeSettlementConsumedUsdc;
        uint256 activeMarginConsumedUsdc;
        uint256 totalConsumedUsdc;
        uint256 uncoveredUsdc;
    }

    function buildAccountUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 reservedSettlementUsdc,
        uint256 totalLockedMarginUsdc,
        uint256 activePositionMarginUsdc
    ) internal pure returns (AccountUsdcBuckets memory buckets) {
        buckets.settlementBalanceUsdc = settlementBalanceUsdc;
        buckets.reservedSettlementUsdc = reservedSettlementUsdc;
        buckets.totalLockedMarginUsdc = totalLockedMarginUsdc;
        buckets.activePositionMarginUsdc =
            activePositionMarginUsdc > totalLockedMarginUsdc ? totalLockedMarginUsdc : activePositionMarginUsdc;
        buckets.otherLockedMarginUsdc = buckets.totalLockedMarginUsdc - buckets.activePositionMarginUsdc;

        uint256 encumberedUsdc = buckets.totalLockedMarginUsdc + buckets.reservedSettlementUsdc;
        buckets.freeSettlementUsdc = buckets.settlementBalanceUsdc > encumberedUsdc
            ? buckets.settlementBalanceUsdc - encumberedUsdc
            : 0;
    }

    function planFundingLossConsumption(
        AccountUsdcBuckets memory buckets,
        uint256 lossUsdc
    ) internal pure returns (SettlementConsumption memory consumption) {
        consumption.freeSettlementConsumedUsdc = buckets.freeSettlementUsdc > lossUsdc ? lossUsdc : buckets.freeSettlementUsdc;

        uint256 remainingLossUsdc = lossUsdc - consumption.freeSettlementConsumedUsdc;
        consumption.activeMarginConsumedUsdc =
            buckets.activePositionMarginUsdc > remainingLossUsdc ? remainingLossUsdc : buckets.activePositionMarginUsdc;
        consumption.totalConsumedUsdc = consumption.freeSettlementConsumedUsdc + consumption.activeMarginConsumedUsdc;
        consumption.uncoveredUsdc = remainingLossUsdc - consumption.activeMarginConsumedUsdc;
    }

    function getLiquidationReachableUsdc(
        AccountUsdcBuckets memory buckets
    ) internal pure returns (uint256 reachableUsdc) {
        reachableUsdc = buckets.freeSettlementUsdc + buckets.activePositionMarginUsdc;
        if (reachableUsdc > buckets.settlementBalanceUsdc) {
            reachableUsdc = buckets.settlementBalanceUsdc;
        }
    }

    function getSettlementReachableUsdc(
        AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc
    ) internal pure returns (uint256 reachableUsdc) {
        uint256 protectedBalance = protectedLockedMarginUsdc + buckets.reservedSettlementUsdc;
        reachableUsdc = buckets.settlementBalanceUsdc > protectedBalance ? buckets.settlementBalanceUsdc - protectedBalance : 0;
    }

}
