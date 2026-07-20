// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title OpenAccountingLib
/// @notice Calculates entry-price, VPI, fee, maximum-profit, and margin requirements for an open or increase.
/// @dev USDC values use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, and VPI parameters use 18-decimal WAD precision. Integer divisions round down.
library OpenAccountingLib {

    /// @notice Inputs needed to value an open or same-side position increase.
    /// @param currentSize Existing position size, or zero for a new position.
    /// @param currentEntryPrice Existing volume-weighted entry price; ignored when `currentSize` is zero.
    /// @param side Side of the new or increased position.
    /// @param sizeDelta Size added by the order.
    /// @param price Execution and margin-reference price.
    /// @param capPrice Protocol price cap used to calculate the added maximum-profit envelope.
    /// @param preSkewUsdc Absolute directional skew before the trade.
    /// @param postSkewUsdc Absolute directional skew after the trade.
    /// @param poolDepthUsdc Pool depth used by the VPI curve.
    /// @param executionFeeBps Execution fee rate on added notional, in basis points.
    /// @param riskParams VPI factor, initial/maintenance margin rates, and minimum bounty.
    struct OpenInputs {
        uint256 currentSize;
        uint256 currentEntryPrice;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 price;
        uint256 capPrice;
        uint256 preSkewUsdc;
        uint256 postSkewUsdc;
        uint256 poolDepthUsdc;
        uint256 executionFeeBps;
        CfdTypes.RiskParams riskParams;
    }

    /// @notice Calculated economic and risk state for an open or increase.
    /// @param addedMaxProfitUsdc Maximum-profit liability added by `sizeDelta` at the execution price.
    /// @param oldEntryNotional Existing raw `currentSize * currentEntryPrice`, with 26-decimal precision.
    /// @param newEntryPrice Resulting size-weighted entry price, rounded down to 8 decimals.
    /// @param newSize Resulting position size.
    /// @param newEntryNotional Raw `newSize * newEntryPrice`; may omit weighted-average division dust.
    /// @param postSkewUsdc Caller-supplied post-trade skew copied into the result.
    /// @param vpiUsdc Signed VPI; positive charges the trader and negative rebates the trader.
    /// @param notionalUsdc Added trade notional at `price`.
    /// @param executionFeeUsdc Execution fee on added notional.
    /// @param tradeCostUsdc Signed `vpiUsdc + executionFeeUsdc`.
    /// @param maintenanceMarginUsdc Maintenance requirement on the entire resulting position at `price`.
    /// @param initialMarginRequirementUsdc Initial requirement on the entire resulting position, floored by
    ///        `riskParams.minBountyUsdc`.
    struct OpenState {
        uint256 addedMaxProfitUsdc;
        uint256 oldEntryNotional;
        uint256 newEntryPrice;
        uint256 newSize;
        uint256 newEntryNotional;
        uint256 postSkewUsdc;
        int256 vpiUsdc;
        uint256 notionalUsdc;
        uint256 executionFeeUsdc;
        int256 tradeCostUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 initialMarginRequirementUsdc;
    }

    /// @notice Builds entry, economic-cost, and risk-requirement state for an open or increase.
    /// @dev The weighted entry price and every fee/margin division round down. A zero pool depth makes VPI zero through
    ///      `CfdMath`. If both current size and size delta are zero, entry price is still set to `price` and the initial
    ///      requirement still takes the configured minimum-bounty floor. Checked arithmetic reverts on overflow;
    ///      callers must bound values before explicit signed casts, which follow fixed-width conversion semantics.
    /// @param inputs Current position values plus trade, skew, fee, and risk inputs.
    /// @return state Resulting entry state, added liabilities, signed trade cost, and margin requirements.
    function buildOpenState(
        OpenInputs memory inputs
    ) internal pure returns (OpenState memory state) {
        state.addedMaxProfitUsdc =
            CfdMath.calculateMaxProfit(inputs.sizeDelta, inputs.price, inputs.side, inputs.capPrice);
        state.oldEntryNotional = inputs.currentSize * inputs.currentEntryPrice;

        if (inputs.currentSize == 0) {
            state.newEntryPrice = inputs.price;
        } else {
            uint256 totalValue = state.oldEntryNotional + (inputs.sizeDelta * inputs.price);
            state.newEntryPrice = totalValue / (inputs.currentSize + inputs.sizeDelta);
        }

        state.newSize = inputs.currentSize + inputs.sizeDelta;
        state.newEntryNotional = state.newSize * state.newEntryPrice;
        state.postSkewUsdc = inputs.postSkewUsdc;

        state.vpiUsdc = CfdMath.calculateVPI(
            inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.riskParams.vpiFactor
        );
        state.notionalUsdc = (inputs.sizeDelta * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (state.notionalUsdc * inputs.executionFeeBps) / 10_000;
        state.tradeCostUsdc = state.vpiUsdc + int256(state.executionFeeUsdc);
        state.maintenanceMarginUsdc =
            (((state.newSize * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE) * inputs.riskParams.maintMarginBps) / 10_000;
        state.initialMarginRequirementUsdc =
            (((state.newSize * inputs.price) / CfdMath.USDC_TO_TOKEN_SCALE) * inputs.riskParams.initMarginBps) / 10_000;
        if (state.initialMarginRequirementUsdc < inputs.riskParams.minBountyUsdc) {
            state.initialMarginRequirementUsdc = inputs.riskParams.minBountyUsdc;
        }
    }

    /// @notice Removes a negative trade-cost rebate from custody margin to obtain canonical economic margin.
    /// @dev The clearinghouse's open-cost plan credits and locks a rebate. Risk accounting must not count that
    ///      pool-funded rebate as trader-provided margin, so `-tradeCostUsdc` is subtracted with a zero floor. Positive
    ///      or zero trade costs leave `marginUsdc` unchanged. `type(int256).min` cannot be negated and reverts.
    /// @param marginUsdc Clearinghouse position margin after the open-cost mutation.
    /// @param tradeCostUsdc Signed VPI plus execution fee; negative values are rebates.
    /// @return effectiveMarginUsdc Canonical risk margin after excluding any rebate, floored at zero.
    function effectiveMarginAfterTradeCost(
        uint256 marginUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (uint256 effectiveMarginUsdc) {
        effectiveMarginUsdc = marginUsdc;
        if (tradeCostUsdc < 0) {
            uint256 rebateUsdc = uint256(-tradeCostUsdc);
            effectiveMarginUsdc = effectiveMarginUsdc > rebateUsdc ? effectiveMarginUsdc - rebateUsdc : 0;
        }
    }

}
