// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title CloseAccountingLib
/// @notice Calculates the proportional position state and signed economic settlement for a close.
/// @dev USDC fields use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, and `vpiFactor` uses 18-decimal WAD precision. Multiplication followed by integer division
///      rounds down for unsigned values and toward zero for signed values.
library CloseAccountingLib {

    /// @notice Inputs needed to value a full or partial close.
    /// @param position Position before the close; its size must be nonzero.
    /// @param sizeDelta Size being closed; must be no greater than `position.size`.
    /// @param oraclePrice Execution/risk price used to calculate PnL and close notional.
    /// @param capPrice Price cap passed to bounded PnL calculation.
    /// @param preSkewUsdc Absolute market skew immediately before the close.
    /// @param postSkewUsdc Absolute market skew immediately after the close.
    /// @param poolDepthUsdc Pool depth used by the VPI curve.
    /// @param vpiFactor VPI impact factor, scaled by 1e18.
    /// @param frozenCloseSpreadBps Additional close spread in basis points when the oracle is frozen.
    /// @param oracleFrozen Whether to charge the frozen-market spread.
    /// @param executionFeeBps Execution fee rate applied to closed notional, in basis points.
    struct CloseInputs {
        CfdTypes.Position position;
        uint256 sizeDelta;
        uint256 oraclePrice;
        uint256 capPrice;
        uint256 preSkewUsdc;
        uint256 postSkewUsdc;
        uint256 poolDepthUsdc;
        uint256 vpiFactor;
        uint256 frozenCloseSpreadBps;
        bool oracleFrozen;
        uint256 executionFeeBps;
    }

    /// @notice Calculated position reduction and close settlement before carry and collateral collection.
    /// @param realizedPnlUsdc Signed price PnL for the closed size; positive is trader profit.
    /// @param marginToFreeUsdc Pro-rata margin assigned to the closed size and released from the position.
    /// @param remainingMarginUsdc Canonical position margin left after releasing `marginToFreeUsdc`.
    /// @param remainingSize Position size left after the close.
    /// @param maxProfitReductionUsdc Pro-rata reduction of the position's maximum-profit envelope.
    /// @param proportionalAccrualUsdc Pro-rata lifetime VPI accrual removed with the closed size.
    /// @param vpiDeltaUsdc VPI charged for this close after the lifetime-negative clamp; positive is a trader charge.
    /// @param executionFeeUsdc Execution fee on closed notional.
    /// @param frozenSpreadUsdc Additional spread on closed notional, or zero when `oracleFrozen` is false.
    /// @param netSettlementUsdc Signed `realizedPnl - vpiDelta - executionFee - frozenSpread`; positive is owed to the
    ///        trader and negative is owed by the trader. Pending carry is not included.
    struct CloseState {
        int256 realizedPnlUsdc;
        uint256 marginToFreeUsdc;
        uint256 remainingMarginUsdc;
        uint256 remainingSize;
        uint256 maxProfitReductionUsdc;
        int256 proportionalAccrualUsdc;
        int256 vpiDeltaUsdc;
        uint256 executionFeeUsdc;
        uint256 frozenSpreadUsdc;
        int256 netSettlementUsdc;
    }

    /// @notice Builds the pro-rata remaining-position state and pre-carry settlement for a close.
    /// @dev Reverts through Solidity arithmetic if `position.size == 0`, `sizeDelta > position.size`, products
    ///      overflow, or downstream PnL/VPI preconditions are violated. Pro-rata margin and max-profit calculations
    ///      round down, leaving any division remainder on the open position. Signed VPI proration rounds toward zero.
    ///      Close VPI is clamped upward so `proportionalAccrualUsdc + vpiDeltaUsdc` cannot be negative. Canonical size
    ///      and USDC values converted to `int256` must fit its positive range; explicit casts otherwise follow
    ///      fixed-width conversion semantics.
    /// @param inputs Position, price, skew, pool-depth, fee, and frozen-market inputs.
    /// @return state Close accounting before pending carry and collateral-availability settlement.
    function buildCloseState(
        CloseInputs memory inputs
    ) internal pure returns (CloseState memory state) {
        CfdTypes.Position memory closedPart = CfdTypes.Position({
            size: inputs.sizeDelta,
            margin: inputs.position.margin,
            entryPrice: inputs.position.entryPrice,
            maxProfitUsdc: inputs.position.maxProfitUsdc,
            side: inputs.position.side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: inputs.position.vpiAccrued
        });
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, inputs.oraclePrice, inputs.capPrice);
        state.realizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        state.marginToFreeUsdc = (inputs.position.margin * inputs.sizeDelta) / inputs.position.size;
        state.remainingMarginUsdc = inputs.position.margin - state.marginToFreeUsdc;
        state.remainingSize = inputs.position.size - inputs.sizeDelta;
        state.maxProfitReductionUsdc = (inputs.position.maxProfitUsdc * inputs.sizeDelta) / inputs.position.size;

        state.proportionalAccrualUsdc =
            (inputs.position.vpiAccrued * int256(inputs.sizeDelta)) / int256(inputs.position.size);
        state.vpiDeltaUsdc =
            CfdMath.calculateVPI(inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.vpiFactor);
        // Clamp so lifetime VPI (accrued + delta) never goes negative. Prevents LP sandwich attacks
        // where an attacker opens at high depth, donates to shrink depth, then closes to extract a
        // net-negative VPI rebate. This rule is identical in live and oracle-frozen markets; frozen-market
        // stale-price risk is priced separately through frozenSpreadUsdc.
        if (state.proportionalAccrualUsdc + state.vpiDeltaUsdc < 0) {
            state.vpiDeltaUsdc = -state.proportionalAccrualUsdc;
        }

        uint256 notionalUsdc = (inputs.sizeDelta * inputs.oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.executionFeeUsdc = (notionalUsdc * inputs.executionFeeBps) / 10_000;
        if (inputs.oracleFrozen) {
            state.frozenSpreadUsdc = (notionalUsdc * inputs.frozenCloseSpreadBps) / 10_000;
        }
        state.netSettlementUsdc =
            state.realizedPnlUsdc - state.vpiDeltaUsdc - int256(state.executionFeeUsdc + state.frozenSpreadUsdc);
    }

}
