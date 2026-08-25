// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

/// @title OrderBountyAccounting
/// @notice Quotes execution bounties and transfers queued bounty reservations during account liquidation.
abstract contract OrderBountyAccounting is OrderRouterBase {

    /// @notice Quotes an open-order bounty from notional, bounded by configured floor and cap.
    /// @dev Notional conversion and the basis-point multiplication round down before floor/cap application.
    /// @param sizeDelta Order size in synthetic-token units (18 decimals).
    /// @param price Reference oracle price (8 decimals).
    /// @return executionBountyUsdc Quoted bounty in 6-decimal USDC.
    function _quoteOpenOrderExecutionBountyUsdc(
        uint256 sizeDelta,
        uint256 price
    ) internal view returns (uint256) {
        uint256 notionalUsdc = (sizeDelta * price) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        uint256 executionBountyUsdc = (notionalUsdc * openOrderExecutionBountyBps) / 10_000;
        if (executionBountyUsdc < minOpenOrderExecutionBountyUsdc) {
            executionBountyUsdc = minOpenOrderExecutionBountyUsdc;
        }
        return
            executionBountyUsdc > maxOpenOrderExecutionBountyUsdc
                ? maxOpenOrderExecutionBountyUsdc
                : executionBountyUsdc;
    }

    /// @notice Converts the engine's minimum bounty economics into the smallest partial-close size.
    /// @dev Both divisions round up so an accepted partial-close slice meets the engine-derived bounty notional floor.
    ///      Assumes the engine's `bountyBps` and the supplied price are nonzero.
    /// @param price Commit reference price (8 decimals).
    /// @return Minimum close size in synthetic-token units (18 decimals).
    function _minSizeDeltaForEngineBountyFloor(
        uint256 price
    ) internal view returns (uint256) {
        (,,,,,, uint256 minBountyUsdc, uint256 bountyBps,,) = engine.riskParams();
        uint256 minNotionalUsdc = Math.mulDiv(minBountyUsdc, 10_000, bountyBps, Math.Rounding.Ceil);
        return Math.mulDiv(minNotionalUsdc, DecimalConstants.USDC_TO_TOKEN_SCALE, price, Math.Rounding.Ceil);
    }

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
