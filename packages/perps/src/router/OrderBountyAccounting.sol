// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";

/// @title OrderBountyAccounting
/// @notice Transfers queued bounty reservations during account liquidation.
abstract contract OrderBountyAccounting is OrderRouterBase {

    /// @notice Clears all live queued-order bounties for an account and asks the engine to absorb their sum.
    /// @dev Does not release margin or unlink orders; post-liquidation queue cleanup performs those steps.
    ///      A downstream engine revert rolls back every cleared record.
    /// @param account Liquidated account whose bounties are forfeited.
    function _forfeitReservedOrderBountiesOnLiquidation(
        address account
    ) internal returns (uint64[] memory orderIds, uint256[] memory orderBountiesUsdc) {
        uint256 orderCount = 0;
        for (
            uint64 cursor = accountHeadOrderId[account]; cursor != 0; cursor = orderRecords[cursor].nextAccountOrderId) {
            ++orderCount;
        }
        orderIds = new uint64[](orderCount);
        orderBountiesUsdc = new uint256[](orderCount);

        uint256 forfeitedUsdc = _protectionBountiesToForfeitOnLiquidation(account);
        uint256 index = 0;
        for (
            uint64 orderId = accountHeadOrderId[account];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            OrderRecord storage record = orderRecords[orderId];
            uint256 executionBountyUsdc = record.executionBountyUsdc;
            orderIds[index] = orderId;
            orderBountiesUsdc[index] = executionBountyUsdc;
            ++index;
            if (executionBountyUsdc > 0) {
                forfeitedUsdc += executionBountyUsdc;
                record.executionBountyUsdc = 0;
            }
        }

        if (forfeitedUsdc == 0) {
            return (orderIds, orderBountiesUsdc);
        }

        engine.absorbReservedExecutionBounty(account, forfeitedUsdc);
    }

    /// @notice Terminalizes and returns any unpaid non-order bounty reservation owned by account protection.
    /// @dev The default router has no such reservation. Position-protection handling overrides this hook so its
    ///      amount is transferred together with ordinary queued-order bounties in one engine call.
    /// @param account Account being liquidated.
    /// @return forfeitedUsdc Additional reserved bounty value to transfer to the protocol treasury.
    function _protectionBountiesToForfeitOnLiquidation(
        address account
    ) internal virtual returns (uint256 forfeitedUsdc) {
        account;
        return 0;
    }

}
