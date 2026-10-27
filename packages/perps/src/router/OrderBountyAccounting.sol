// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";

/// @title OrderBountyAccounting
/// @notice Transfers queued bounty reservations during account liquidation.
abstract contract OrderBountyAccounting is OrderRouterBase {

    /// @notice Forfeits live order and unpaid protection-trigger bounty reservations before liquidation.
    /// @dev Does not release margin or unlink orders; post-liquidation queue cleanup performs those steps.
    ///      A downstream engine revert rolls back every cleared record.
    /// @param account Liquidated account whose bounties are forfeited.
    function _forfeitReservedOrderBountiesOnLiquidation(
        address account
    ) internal returns (uint64[] memory orderIds, uint256[] memory orderBountiesAssets) {
        uint256 orderCount = 0;
        for (
            uint64 cursor = accountHeadOrderId[account]; cursor != 0; cursor = orderRecords[cursor].nextAccountOrderId) {
            lifecycleBook.validateBountyFunding(cursor);
            ++orderCount;
        }
        orderIds = new uint64[](orderCount);
        orderBountiesAssets = new uint256[](orderCount);

        uint256 forfeitedAssets = _protectionBountiesToForfeitOnLiquidation(account);
        uint256 index = 0;
        for (
            uint64 orderId = accountHeadOrderId[account];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            uint256 executionBountyAssets =
                clearinghouse.takeBountyReservation(account, IMarginClearinghouse.BountyKind.Order, orderId);
            orderIds[index] = orderId;
            orderBountiesAssets[index] = executionBountyAssets;
            ++index;
            forfeitedAssets += executionBountyAssets;
        }

        if (forfeitedAssets == 0) {
            return (orderIds, orderBountiesAssets);
        }

        engine.absorbReservedExecutionBounty(account, forfeitedAssets);
    }

    /// @notice Terminalizes and returns any unpaid non-order bounty reservation owned by account protection.
    /// @dev The default router has no such reservation. Position-protection handling overrides this hook so its
    ///      amount is transferred together with ordinary queued-order bounties in one engine call.
    /// @param account Account being liquidated.
    /// @return forfeitedAssets Additional reserved bounty value to transfer to the protocol treasury.
    function _protectionBountiesToForfeitOnLiquidation(
        address account
    ) internal virtual returns (uint256 forfeitedAssets) {
        account;
        return 0;
    }

}
