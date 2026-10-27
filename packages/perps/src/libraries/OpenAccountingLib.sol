// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Panic} from "@openzeppelin/contracts/utils/Panic.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title OpenAccountingLib
/// @notice Calculates entry-price, VPI, fee, maximum-profit, and margin requirements for an open or increase.
/// @dev settlement token values use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, and VPI parameters use 18-decimal WAD precision. Integer divisions round down.
library OpenAccountingLib {

    /// @notice Inputs needed to value an open or same-side position increase.
    /// @param currentSize Existing position size, or zero for a new position.
    /// @param currentEntryCostAssetAtoms Exact existing entry cost in 6-decimal settlement token atoms.
    /// @param side Side of the new or increased position.
    /// @param sizeDelta Size added by the order.
    /// @param price Execution and margin-reference price.
    /// @param capPrice Protocol price cap used to calculate the added maximum-profit envelope.
    /// @param preSkewAssets Absolute directional skew before the trade.
    /// @param postSkewAssets Absolute directional skew after the trade.
    /// @param poolDepthAssets Pool depth used by the VPI curve.
    /// @param executionFeeBps Execution fee rate on added notional, in basis points.
    /// @param riskParams VPI factor, initial/maintenance margin rates, and minimum bounty.
    struct OpenInputs {
        uint256 currentSize;
        uint256 currentEntryCostAssetAtoms;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 price;
        uint256 capPrice;
        uint256 preSkewAssets;
        uint256 postSkewAssets;
        uint256 poolDepthAssets;
        uint256 executionFeeBps;
        CfdTypes.RiskParams riskParams;
    }

    /// @notice Calculated economic and risk state for an open or increase.
    /// @param addedMaxProfitAssets Maximum-profit liability added by `sizeDelta` at the execution price.
    /// @param oldEntryNotional Existing exact entry cost scaled by `1e20`, with 26-decimal precision.
    /// @param newEntryPrice Display-only average entry price, rounded down to 8 decimals.
    /// @param newEntryCostAssetAtoms Exact resulting entry cost in 6-decimal settlement token atoms.
    /// @param newSize Resulting position size.
    /// @param newEntryNotional Exact resulting entry cost scaled by `1e20`, preserving basis dust at 26-decimal precision.
    /// @param postSkewAssets Caller-supplied post-trade skew copied into the result.
    /// @param vpiAssets Signed VPI; positive charges the trader and negative rebates the trader.
    /// @param notionalAssets Added trade notional at `price`.
    /// @param executionFeeAssets Execution fee on added notional.
    /// @param tradeCostAssets Signed `vpiAssets + executionFeeAssets`.
    /// @param maintenanceMarginAssets Maintenance requirement on the entire resulting position at `price`.
    /// @param initialMarginRequirementAssets Initial requirement on the entire resulting position, floored by
    ///        `riskParams.minBountyAssets`.
    /// @param liquidationReserveTargetAssets Notional-based liquidation charge, floored by `riskParams.minBountyAssets`.
    struct OpenState {
        uint256 addedMaxProfitAssets;
        uint256 oldEntryNotional;
        uint256 newEntryPrice;
        uint256 newEntryCostAssetAtoms;
        uint256 newSize;
        uint256 newEntryNotional;
        uint256 postSkewAssets;
        int256 vpiAssets;
        uint256 notionalAssets;
        uint256 executionFeeAssets;
        int256 tradeCostAssets;
        uint256 maintenanceMarginAssets;
        uint256 initialMarginRequirementAssets;
        uint256 liquidationReserveTargetAssets;
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
    /// @return rawLiquidationRequirementAssets Unfloored notional liquidation requirement used for minimum-size policy.
    function tryBuildOpenState(
        OpenInputs memory inputs
    ) internal pure returns (bool valid, OpenState memory state, uint256 rawLiquidationRequirementAssets) {
        if (inputs.sizeDelta % CfdTypes.SIZE_QUANTUM != 0 || inputs.currentSize % CfdTypes.SIZE_QUANTUM != 0) {
            return (false, state, 0);
        }
        uint256 addedLots = inputs.sizeDelta / CfdTypes.SIZE_QUANTUM;
        uint256 currentLots = inputs.currentSize / CfdTypes.SIZE_QUANTUM;
        if (
            currentLots > type(uint112).max || addedLots > type(uint112).max - currentLots
                || inputs.currentEntryCostAssetAtoms > type(uint144).max
        ) {
            return (false, state, 0);
        }
        uint256 addedEntryCostAssetAtoms = addedLots * inputs.price;
        if (addedEntryCostAssetAtoms > type(uint144).max - inputs.currentEntryCostAssetAtoms) {
            return (false, state, 0);
        }
        state.addedMaxProfitAssets =
            CfdMath.calculateExactMaxProfit(addedLots, addedEntryCostAssetAtoms, inputs.side, inputs.capPrice);
        state.oldEntryNotional = inputs.currentEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE;
        state.newSize = inputs.currentSize + inputs.sizeDelta;
        state.newEntryCostAssetAtoms = inputs.currentEntryCostAssetAtoms + addedEntryCostAssetAtoms;
        uint256 newLots = currentLots + addedLots;
        state.newEntryPrice = newLots == 0 ? inputs.price : state.newEntryCostAssetAtoms / newLots;
        state.newEntryNotional = state.newEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE;
        state.postSkewAssets = inputs.postSkewAssets;

        (valid, state.vpiAssets) = CfdMath.tryCalculateVPI(
            inputs.preSkewAssets, inputs.postSkewAssets, inputs.poolDepthAssets, inputs.riskParams.vpiFactor
        );
        if (!valid) {
            return (false, state, 0);
        }
        state.notionalAssets = addedEntryCostAssetAtoms;
        state.executionFeeAssets = (state.notionalAssets * inputs.executionFeeBps) / 10_000;
        state.tradeCostAssets = state.vpiAssets + int256(state.executionFeeAssets);
        state.maintenanceMarginAssets = ((newLots * inputs.price) * inputs.riskParams.maintMarginBps) / 10_000;
        state.initialMarginRequirementAssets = ((newLots * inputs.price) * inputs.riskParams.initMarginBps) / 10_000;
        if (state.initialMarginRequirementAssets < inputs.riskParams.minBountyAssets) {
            state.initialMarginRequirementAssets = inputs.riskParams.minBountyAssets;
        }
        uint256 resultingNotionalAssets = newLots * inputs.price;
        if (
            inputs.riskParams.bountyBps != 0
                && resultingNotionalAssets > type(uint256).max / inputs.riskParams.bountyBps
        ) {
            return (false, state, 0);
        }
        rawLiquidationRequirementAssets = (resultingNotionalAssets * inputs.riskParams.bountyBps) / 10_000;
        state.liquidationReserveTargetAssets = rawLiquidationRequirementAssets;
        if (state.liquidationReserveTargetAssets < inputs.riskParams.minBountyAssets) {
            state.liquidationReserveTargetAssets = inputs.riskParams.minBountyAssets;
        }
        return (true, state, rawLiquidationRequirementAssets);
    }

}
