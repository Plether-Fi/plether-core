// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Panic} from "@openzeppelin/contracts/utils/Panic.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title OpenAccountingLib
/// @notice Calculates entry-price, VPI, fee, maximum-profit, and margin requirements for an open or increase.
/// @dev USDC values use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, and VPI parameters use 18-decimal WAD precision. Integer divisions round down.
library OpenAccountingLib {

    /// @notice Inputs needed to value an open or same-side position increase.
    /// @param currentSize Existing position size, or zero for a new position.
    /// @param currentEntryCostUsdcAtoms Exact existing entry cost in 6-decimal USDC atoms.
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
        uint256 currentEntryCostUsdcAtoms;
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
    /// @param oldEntryNotional Existing exact entry cost scaled by `1e20`, with 26-decimal precision.
    /// @param newEntryPrice Display-only average entry price, rounded down to 8 decimals.
    /// @param newEntryCostUsdcAtoms Exact resulting entry cost in 6-decimal USDC atoms.
    /// @param newSize Resulting position size.
    /// @param newEntryNotional Exact resulting entry cost scaled by `1e20`, preserving basis dust at 26-decimal precision.
    /// @param postSkewUsdc Caller-supplied post-trade skew copied into the result.
    /// @param vpiUsdc Signed VPI; positive charges the trader and negative rebates the trader.
    /// @param notionalUsdc Added trade notional at `price`.
    /// @param executionFeeUsdc Execution fee on added notional.
    /// @param tradeCostUsdc Signed `vpiUsdc + executionFeeUsdc`.
    /// @param maintenanceMarginUsdc Maintenance requirement on the entire resulting position at `price`.
    /// @param initialMarginRequirementUsdc Initial requirement on the entire resulting position, floored by
    ///        `riskParams.minBountyUsdc`.
    /// @param liquidationReserveTargetUsdc Notional-based liquidation charge, floored by `riskParams.minBountyUsdc`.
    struct OpenState {
        uint256 addedMaxProfitUsdc;
        uint256 oldEntryNotional;
        uint256 newEntryPrice;
        uint256 newEntryCostUsdcAtoms;
        uint256 newSize;
        uint256 newEntryNotional;
        uint256 postSkewUsdc;
        int256 vpiUsdc;
        uint256 notionalUsdc;
        uint256 executionFeeUsdc;
        int256 tradeCostUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 initialMarginRequirementUsdc;
        uint256 liquidationReserveTargetUsdc;
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
        CfdMath.sizeToLots(inputs.sizeDelta);
        CfdMath.sizeToLots(inputs.currentSize);
        bool valid;
        (valid, state,) = tryBuildOpenState(inputs);
        if (!valid) {
            Panic.panic(Panic.UNDER_OVERFLOW);
        }
    }

    /// @notice Builds open economics inside canonical position storage and original VPI arithmetic bounds.
    /// @dev Requires the authoritative cap/price (at most uint32.max) and governance-capped fee/margin rates. The
    ///      uint112 lot and uint144 entry bounds prove size and scaled entry fit int256; notional times a capped
    ///      10,000-bps rate fits uint256. The checked VPI product bounds cost plus the fee below int256.max.
    /// @return valid Whether every request-dependent numeric operation is representable.
    /// @return state Open economics, diagnostic only when invalid.
    /// @return rawLiquidationRequirementUsdc Unfloored notional liquidation requirement used for minimum-size policy.
    function tryBuildOpenState(
        OpenInputs memory inputs
    ) internal pure returns (bool valid, OpenState memory state, uint256 rawLiquidationRequirementUsdc) {
        if (inputs.sizeDelta % CfdTypes.SIZE_QUANTUM != 0 || inputs.currentSize % CfdTypes.SIZE_QUANTUM != 0) {
            return (false, state, 0);
        }
        uint256 addedLots = inputs.sizeDelta / CfdTypes.SIZE_QUANTUM;
        uint256 currentLots = inputs.currentSize / CfdTypes.SIZE_QUANTUM;
        if (
            currentLots > type(uint112).max || addedLots > type(uint112).max - currentLots
                || inputs.currentEntryCostUsdcAtoms > type(uint144).max
        ) {
            return (false, state, 0);
        }
        uint256 addedEntryCostUsdcAtoms = addedLots * inputs.price;
        if (addedEntryCostUsdcAtoms > type(uint144).max - inputs.currentEntryCostUsdcAtoms) {
            return (false, state, 0);
        }
        state.addedMaxProfitUsdc =
            CfdMath.calculateExactMaxProfit(addedLots, addedEntryCostUsdcAtoms, inputs.side, inputs.capPrice);
        state.oldEntryNotional = inputs.currentEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        state.newSize = inputs.currentSize + inputs.sizeDelta;
        state.newEntryCostUsdcAtoms = inputs.currentEntryCostUsdcAtoms + addedEntryCostUsdcAtoms;
        uint256 newLots = currentLots + addedLots;
        state.newEntryPrice = newLots == 0 ? inputs.price : state.newEntryCostUsdcAtoms / newLots;
        state.newEntryNotional = state.newEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        state.postSkewUsdc = inputs.postSkewUsdc;

        (valid, state.vpiUsdc) = CfdMath.tryCalculateVPI(
            inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.riskParams.vpiFactor
        );
        if (!valid) {
            return (false, state, 0);
        }
        state.notionalUsdc = addedEntryCostUsdcAtoms;
        state.executionFeeUsdc = (state.notionalUsdc * inputs.executionFeeBps) / 10_000;
        state.tradeCostUsdc = state.vpiUsdc + int256(state.executionFeeUsdc);
        state.maintenanceMarginUsdc = ((newLots * inputs.price) * inputs.riskParams.maintMarginBps) / 10_000;
        state.initialMarginRequirementUsdc = ((newLots * inputs.price) * inputs.riskParams.initMarginBps) / 10_000;
        if (state.initialMarginRequirementUsdc < inputs.riskParams.minBountyUsdc) {
            state.initialMarginRequirementUsdc = inputs.riskParams.minBountyUsdc;
        }
        uint256 resultingNotionalUsdc = newLots * inputs.price;
        if (inputs.riskParams.bountyBps != 0 && resultingNotionalUsdc > type(uint256).max / inputs.riskParams.bountyBps)
        {
            return (false, state, 0);
        }
        rawLiquidationRequirementUsdc = (resultingNotionalUsdc * inputs.riskParams.bountyBps) / 10_000;
        state.liquidationReserveTargetUsdc = rawLiquidationRequirementUsdc;
        if (state.liquidationReserveTargetUsdc < inputs.riskParams.minBountyUsdc) {
            state.liquidationReserveTargetUsdc = inputs.riskParams.minBountyUsdc;
        }
        return (true, state, rawLiquidationRequirementUsdc);
    }

}
