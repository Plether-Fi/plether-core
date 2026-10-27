// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title CloseAccountingLib
/// @notice Calculates the proportional position state and signed economic settlement for a close.
/// @dev settlement token fields use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, and `vpiFactor` uses 18-decimal WAD precision. Multiplication followed by integer division
///      rounds down for unsigned values and toward zero for signed values.
library CloseAccountingLib {

    /// @notice Inputs needed to value a full or partial close.
    /// @param position Position before the close; its size must be nonzero.
    /// @param positionEntryCostAssetAtoms Exact remaining entry cost before the close, in 6-decimal settlement token atoms.
    /// @param sizeDelta Size being closed; must be no greater than `position.size`.
    /// @param oraclePrice Execution/risk price used to calculate PnL and close notional.
    /// @param capPrice Price cap passed to bounded PnL calculation.
    /// @param preSkewAssets Absolute market skew immediately before the close.
    /// @param postSkewAssets Absolute market skew immediately after the close.
    /// @param poolDepthAssets Pool depth used by the VPI curve.
    /// @param vpiFactor VPI impact factor, scaled by 1e18.
    /// @param frozenCloseSpreadBps Additional close spread in basis points when the oracle is frozen.
    /// @param oracleFrozen Whether to charge the frozen-market spread.
    /// @param executionFeeBps Execution fee rate applied to closed notional, in basis points.
    struct CloseInputs {
        CfdTypes.Position position;
        uint256 positionEntryCostAssetAtoms;
        uint256 sizeDelta;
        uint256 oraclePrice;
        uint256 capPrice;
        uint256 preSkewAssets;
        uint256 postSkewAssets;
        uint256 poolDepthAssets;
        uint256 vpiFactor;
        uint256 frozenCloseSpreadBps;
        bool oracleFrozen;
        uint256 executionFeeBps;
    }

    /// @notice Calculated position reduction and close economics, excluding carry and collateral collection.
    /// @param realizedPnlAssets Signed price PnL for the closed size; positive is trader profit.
    /// @param marginToFreeAssets Pro-rata margin assigned to the closed size and released from the position.
    /// @param remainingMarginAssets Canonical position margin left after releasing `marginToFreeAssets`.
    /// @param remainingSize Position size left after the close.
    /// @param closedEntryCostAssetAtoms Exact basis allocated to the closed lots, rounded down on a partial close.
    /// @param remainingEntryCostAssetAtoms Entry basis retained by the remaining position, including proration dust.
    /// @param maxProfitReductionAssets Exact endpoint profit envelope of the closed lots and their allocated entry basis.
    /// @param proportionalAccrualAssets Pro-rata lifetime VPI accrual removed with the closed size.
    /// @param vpiDeltaAssets VPI charged for this close after the lifetime-negative clamp; positive is a trader charge.
    /// @param executionFeeAssets Execution fee on closed notional.
    /// @param frozenSpreadAssets Additional spread on closed notional, or zero when `oracleFrozen` is false.
    /// @param netSettlementAssets Signed `realizedPnl - vpiDelta - executionFee - frozenSpread`; positive is owed to the
    ///        trader and negative is owed by the trader. Pending carry is not included.
    struct CloseState {
        int256 realizedPnlAssets;
        uint256 marginToFreeAssets;
        uint256 remainingMarginAssets;
        uint256 remainingSize;
        uint256 closedEntryCostAssetAtoms;
        uint256 remainingEntryCostAssetAtoms;
        uint256 maxProfitReductionAssets;
        int256 proportionalAccrualAssets;
        int256 vpiDeltaAssets;
        uint256 executionFeeAssets;
        uint256 frozenSpreadAssets;
        int256 netSettlementAssets;
    }

    /// @notice Builds the pro-rata remaining-position state and pre-carry settlement for a close.
    /// @dev Reverts through Solidity arithmetic if `position.size == 0`, `sizeDelta > position.size`, products
    ///      overflow, or downstream PnL/VPI preconditions are violated. Partial-close margin and entry-basis allocation
    ///      round down, leaving division remainders on the open position. The max-profit reduction is recomputed from
    ///      the closed lots and allocated basis; signed VPI proration rounds toward zero.
    ///      Close VPI is clamped upward so `proportionalAccrualAssets + vpiDeltaAssets` cannot be negative. Canonical size
    ///      and settlement token values converted to `int256` must fit its positive range; explicit casts otherwise follow
    ///      fixed-width conversion semantics.
    /// @param inputs Position, price, skew, pool-depth, fee, and frozen-market inputs.
    /// @return state Close economics excluding carry and collateral-availability settlement.
    function buildCloseState(
        CloseInputs memory inputs
    ) internal pure returns (CloseState memory state) {
        uint256 positionLots = CfdMath.sizeToLots(inputs.position.size);
        uint256 closedLots = CfdMath.sizeToLots(inputs.sizeDelta);
        state.closedEntryCostAssetAtoms = inputs.sizeDelta == inputs.position.size
            ? inputs.positionEntryCostAssetAtoms
            : Math.mulDiv(inputs.positionEntryCostAssetAtoms, closedLots, positionLots);
        state.remainingEntryCostAssetAtoms = inputs.positionEntryCostAssetAtoms - state.closedEntryCostAssetAtoms;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculateExactPnl(
            closedLots, state.closedEntryCostAssetAtoms, inputs.position.side, inputs.oraclePrice, inputs.capPrice
        );
        state.realizedPnlAssets = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        state.marginToFreeAssets = (inputs.position.margin * inputs.sizeDelta) / inputs.position.size;
        state.remainingMarginAssets = inputs.position.margin - state.marginToFreeAssets;
        state.remainingSize = inputs.position.size - inputs.sizeDelta;
        state.maxProfitReductionAssets = CfdMath.calculateExactMaxProfit(
            closedLots, state.closedEntryCostAssetAtoms, inputs.position.side, inputs.capPrice
        );

        state.proportionalAccrualAssets =
            (inputs.position.vpiAccrued * int256(inputs.sizeDelta)) / int256(inputs.position.size);
        // With no economic depth, keep protective exits live without creating a fresh charge or rebate.
        // The lifetime clamp below still recovers any previously received negative VPI.
        if (inputs.poolDepthAssets != 0) {
            state.vpiDeltaAssets = CfdMath.calculateVPI(
                inputs.preSkewAssets, inputs.postSkewAssets, inputs.poolDepthAssets, inputs.vpiFactor
            );
        }
        // Clamp so lifetime VPI (accrued + delta) never goes negative. Prevents LP sandwich attacks
        // where an attacker opens at high depth, reduces pool depth, then closes to extract a
        // net-negative lifetime VPI rebate. This rule is identical in live and oracle-frozen markets; frozen-market
        // stale-price risk is priced separately through frozenSpreadAssets.
        if (state.proportionalAccrualAssets + state.vpiDeltaAssets < 0) {
            state.vpiDeltaAssets = -state.proportionalAccrualAssets;
        }

        uint256 notionalAssets = (inputs.sizeDelta * inputs.oraclePrice) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        state.executionFeeAssets = (notionalAssets * inputs.executionFeeBps) / 10_000;
        if (inputs.oracleFrozen) {
            state.frozenSpreadAssets = (notionalAssets * inputs.frozenCloseSpreadBps) / 10_000;
        }
        state.netSettlementAssets = state.realizedPnlAssets - state.vpiDeltaAssets
            - int256(state.executionFeeAssets + state.frozenSpreadAssets);
    }

}
