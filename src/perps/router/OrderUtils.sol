// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {DecimalConstants} from "../../libraries/DecimalConstants.sol";
import {CashPriorityLib} from "../libraries/CashPriorityLib.sol";
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

    /// @dev Liquidation keeper value follows the same default custody path as other keeper flows:
    ///      credit the beneficiary's clearinghouse account when cash is available, otherwise defer the
    ///      claim for later clearinghouse settlement.
    function _creditOrDeferLiquidationBounty(
        uint256 liquidationBountyUsdc,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        if (liquidationBountyUsdc == 0) {
            return;
        }

        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveFreshPayouts(
            housePool.totalAssets(),
            engine.accumulatedFeesUsdc(),
            engine.totalDeferredTraderCreditUsdc(),
            engine.totalDeferredKeeperCreditUsdc()
        );
        if (liquidationBountyUsdc > reservation.freeCashUsdc) {
            engine.recordDeferredKeeperCredit(msg.sender, liquidationBountyUsdc);
            return;
        }

        try housePool.payOut(address(clearinghouse), liquidationBountyUsdc) {
            engine.creditKeeperExecutionBounty(msg.sender, liquidationBountyUsdc, executionPrice, oraclePublishTime);
        } catch {
            engine.recordDeferredKeeperCredit(msg.sender, liquidationBountyUsdc);
        }
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
