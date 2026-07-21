// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title PositionRiskAccountingLib
/// @notice Pure borrow-utilization, carry-index, equity, and liquidation-threshold accounting for perps positions.
/// @dev USDC values use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, carry indexes use 1e18 precision, and time values use seconds. Integer divisions round down.
library PositionRiskAccountingLib {

    /// @notice Fixed-point scale for cumulative carry indexes.
    uint256 internal constant CARRY_INDEX_SCALE = 1e18;
    /// @notice Basis-point scale and maximum modeled pool utilization.
    uint256 internal constant UTILIZATION_BPS = 10_000;

    /// @notice Price-risk state for one position at a supplied collateral and margin policy.
    /// @param unrealizedPnlUsdc Signed capped price PnL; positive values increase trader equity.
    /// @param equityUsdc Signed collateral equity after the selected builder's carry treatment, negative-VPI clawback,
    ///        and unrealized PnL.
    /// @param currentNotionalUsdc Position notional at the supplied price.
    /// @param maintenanceMarginUsdc Requirement at `requiredBps`; the field may represent maintenance, FAD, or another
    ///        caller-selected threshold despite its historical name.
    /// @param liquidatable Whether equity is less than or equal to the requirement.
    struct PositionRiskState {
        int256 unrealizedPnlUsdc;
        int256 equityUsdc;
        uint256 currentNotionalUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    /// @notice Returns the amount of negative lifetime VPI treated as a collateral clawback.
    /// @dev Negating `type(int256).min` reverts.
    /// @param vpiAccrued Signed lifetime VPI; negative values represent rebates previously received by the trader.
    /// @return Magnitude of a negative accrual, or zero for a nonnegative accrual.
    function _vpiClawbackUsdc(
        int256 vpiAccrued
    ) private pure returns (uint256) {
        return vpiAccrued < 0 ? uint256(-vpiAccrued) : 0;
    }

    /// @notice Computes the LP-backed maximum-profit amount on which carry accrues.
    /// @dev Subtraction saturates at zero: position margin funds the maximum-profit envelope before LP assets do.
    /// @param maxProfitUsdc Position maximum-profit envelope.
    /// @param marginUsdc Canonical position margin.
    /// @return LP-funded borrow base `max(maxProfitUsdc - marginUsdc, 0)`.
    function computeBorrowBaseUsdc(
        uint256 maxProfitUsdc,
        uint256 marginUsdc
    ) internal pure returns (uint256) {
        return maxProfitUsdc > marginUsdc ? maxProfitUsdc - marginUsdc : 0;
    }

    /// @notice Computes pool utilization by the aggregate borrow base, capped at 100%.
    /// @dev Returns zero for zero borrow base. A positive borrow base against zero pool assets is treated as 100%
    ///      utilization. Otherwise division rounds down before the 10,000-bps cap is applied.
    /// @param borrowBaseUsdc LP-backed amount using pool capacity.
    /// @param poolAssetsUsdc Pool asset depth available to support the borrow base.
    /// @return utilizationBps Utilization in basis points, within `[0, 10_000]`.
    function computeBorrowUtilizationBps(
        uint256 borrowBaseUsdc,
        uint256 poolAssetsUsdc
    ) internal pure returns (uint256 utilizationBps) {
        if (borrowBaseUsdc == 0) {
            return 0;
        }
        if (poolAssetsUsdc == 0) {
            return UTILIZATION_BPS;
        }
        utilizationBps = (borrowBaseUsdc * UTILIZATION_BPS) / poolAssetsUsdc;
        if (utilizationBps > UTILIZATION_BPS) {
            utilizationBps = UTILIZATION_BPS;
        }
    }

    /// @notice Scales an annualized base carry rate by capped utilization.
    /// @param baseCarryBps Annualized carry rate at 100% utilization, in basis points.
    /// @param utilizationBps Utilization in basis points; values above 10,000 are capped.
    /// @return Utilization-scaled annualized carry rate in basis points, rounded down.
    function computeUtilizedCarryRateBps(
        uint256 baseCarryBps,
        uint256 utilizationBps
    ) internal pure returns (uint256) {
        if (utilizationBps > UTILIZATION_BPS) {
            utilizationBps = UTILIZATION_BPS;
        }
        return (baseCarryBps * utilizationBps) / UTILIZATION_BPS;
    }

    /// @notice Converts an annualized carry rate and elapsed seconds into a 1e18-scaled index increment.
    /// @dev Uses a 365-day simple-interest year and returns zero when either input is zero. Division rounds down.
    /// @param carryRateBps Annualized carry rate in basis points.
    /// @param timeDelta Accrual interval in seconds.
    /// @return Carry index increment scaled by 1e18.
    function computeCarryIndexIncrement(
        uint256 carryRateBps,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        if (carryRateBps == 0 || timeDelta == 0) {
            return 0;
        }
        return (carryRateBps * CARRY_INDEX_SCALE * timeDelta) / (CfdMath.SECONDS_PER_YEAR * 10_000);
    }

    /// @notice Accrues the current carry index using borrow utilization over an elapsed interval.
    /// @dev Returns `storedIndex` unchanged when time does not advance, borrow base is zero, the base rate is zero,
    ///      or computed utilization is zero. Otherwise the implementation performs one combined floor division of
    ///      `baseCarryBps * utilization * 1e18 * elapsed` by `365 days * 10_000 * 10_000`; this can retain more
    ///      precision than separately rounding an utilized bps rate first.
    /// @param storedIndex Last stored cumulative carry index, scaled by 1e18.
    /// @param previousTimestamp Timestamp through which `storedIndex` has accrued, in Unix seconds.
    /// @param currentTimestamp Timestamp to accrue through, in Unix seconds.
    /// @param borrowBaseUsdc Aggregate LP-funded borrow base during the interval.
    /// @param poolAssetsUsdc Pool assets used to compute utilization.
    /// @param baseCarryBps Annualized rate at full utilization, in basis points.
    /// @return index Current cumulative carry index, scaled by 1e18 and rounded down at the increment.
    function computeCurrentCarryIndex(
        uint256 storedIndex,
        uint64 previousTimestamp,
        uint256 currentTimestamp,
        uint256 borrowBaseUsdc,
        uint256 poolAssetsUsdc,
        uint256 baseCarryBps
    ) internal pure returns (uint256 index) {
        index = storedIndex;
        if (currentTimestamp <= previousTimestamp || borrowBaseUsdc == 0 || baseCarryBps == 0) {
            return index;
        }

        uint256 utilizationBps = computeBorrowUtilizationBps(borrowBaseUsdc, poolAssetsUsdc);
        if (utilizationBps == 0) {
            return index;
        }

        index += (baseCarryBps * utilizationBps * CARRY_INDEX_SCALE * (currentTimestamp - previousTimestamp))
            / (CfdMath.SECONDS_PER_YEAR * UTILIZATION_BPS * 10_000);
    }

    /// @notice Converts a carry-index delta into USDC carry on a fixed borrow base.
    /// @dev Returns zero when either input is zero and otherwise rounds down by the 1e18 index scale.
    /// @param borrowBaseUsdc Position or aggregate borrow base.
    /// @param carryIndexDelta Increase in the cumulative carry index, scaled by 1e18.
    /// @return Carry due in 6-decimal USDC.
    function computeIndexedCarryUsdc(
        uint256 borrowBaseUsdc,
        uint256 carryIndexDelta
    ) internal pure returns (uint256) {
        if (borrowBaseUsdc == 0 || carryIndexDelta == 0) {
            return 0;
        }
        return (borrowBaseUsdc * carryIndexDelta) / CARRY_INDEX_SCALE;
    }

    /// @notice Builds position equity and threshold state without a separate pending-carry debit.
    /// @dev Equity is `reachableCollateral - max(-vpiAccrued, 0) + unrealizedPnl`. Positive lifetime VPI is not
    ///      added back. PnL uses the cap-aware `CfdMath.calculatePnL`; notional and requirement divisions round down.
    ///      Canonical USDC inputs must fit `int256`; larger explicit conversions follow fixed-width signed semantics.
    /// @param pos Position to evaluate.
    /// @param price Current oracle price, conventionally 8 decimals.
    /// @param capPrice Protocol price cap passed to PnL calculation.
    /// @param reachableCollateralUsdc Account collateral eligible for this risk view.
    /// @param requiredBps Caller-selected liquidation threshold rate in basis points.
    /// @return state Signed PnL/equity, current notional, requirement, and inclusive liquidation test.
    function buildPositionRiskState(
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, capPrice);
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc =
            int256(reachableCollateralUsdc) - int256(_vpiClawbackUsdc(pos.vpiAccrued)) + state.unrealizedPnlUsdc;
        state.currentNotionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.maintenanceMarginUsdc = (state.currentNotionalUsdc * requiredBps) / 10_000;
        state.liquidatable = state.equityUsdc <= int256(state.maintenanceMarginUsdc);
    }

    /// @notice Builds position equity and threshold state after deducting pending carry.
    /// @dev Equity is `reachableCollateral - pendingCarry - max(-vpiAccrued, 0) + unrealizedPnl`. The result is
    ///      liquidatable on equality (`equity <= maintenanceMarginUsdc`). PnL is cap-aware and divisions round down.
    ///      Canonical USDC inputs must fit `int256`; larger explicit conversions follow fixed-width signed semantics.
    /// @param pos Position to evaluate.
    /// @param price Current oracle price, conventionally 8 decimals.
    /// @param capPrice Protocol price cap passed to PnL calculation.
    /// @param pendingCarryUsdc Carry accrued but not yet removed from collateral.
    /// @param reachableCollateralUsdc Account collateral eligible for this risk view.
    /// @param requiredBps Caller-selected liquidation threshold rate in basis points.
    /// @return state Signed PnL/equity, current notional, requirement, and inclusive liquidation test.
    function buildPositionRiskStateWithCarry(
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 capPrice,
        uint256 pendingCarryUsdc,
        uint256 reachableCollateralUsdc,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, capPrice);
        state.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityUsdc = int256(reachableCollateralUsdc) - int256(pendingCarryUsdc)
            - int256(_vpiClawbackUsdc(pos.vpiAccrued)) + state.unrealizedPnlUsdc;
        state.currentNotionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        state.maintenanceMarginUsdc = (state.currentNotionalUsdc * requiredBps) / 10_000;
        state.liquidatable = state.equityUsdc <= int256(state.maintenanceMarginUsdc);
    }

}
