// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {DecimalConstants} from "../../libraries/DecimalConstants.sol";
import {OrderRouterBase} from "./OrderRouterBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Shared router math and escrow settlement helpers.
abstract contract OrderUtils is OrderRouterBase {

    using SafeERC20 for IERC20;

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

    function _forfeitEscrowedOrderBountiesOnLiquidation(
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

        USDC.safeTransfer(address(housePool), forfeitedUsdc);
        housePool.recordProtocolInflow(forfeitedUsdc);
        engine.recordRouterProtocolFee(forfeitedUsdc);
    }

}
