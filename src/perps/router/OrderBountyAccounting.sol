// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {DecimalConstants} from "../../libraries/DecimalConstants.sol";
import {OrderRouterBase} from "./OrderRouterBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Keeper bounty, liquidation bounty, and forfeited-order bounty accounting for the router stack.
abstract contract OrderBountyAccounting is OrderRouterBase {

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

    function _minSizeDeltaForEngineBountyFloor(
        uint256 price
    ) internal view returns (uint256) {
        (,,,,,, uint256 minBountyUsdc, uint256 bountyBps) = engine.riskParams();
        uint256 minNotionalUsdc = Math.mulDiv(minBountyUsdc, 10_000, bountyBps, Math.Rounding.Ceil);
        return Math.mulDiv(minNotionalUsdc, DecimalConstants.USDC_TO_TOKEN_SCALE, price, Math.Rounding.Ceil);
    }

    function _forfeitReservedOrderBountiesOnLiquidation(
        address account
    ) internal {
        uint256 forfeitedUsdc;
        for (
            uint64 orderId = accountHeadOrderId[account];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            OrderRecord storage record = orderRecords[orderId];
            if (record.executionBountyUsdc > 0) {
                forfeitedUsdc += record.executionBountyUsdc;
                record.executionBountyUsdc = 0;
            }
        }

        if (forfeitedUsdc == 0) {
            return;
        }

        engine.absorbReservedExecutionBounty(account, forfeitedUsdc);
    }

}
