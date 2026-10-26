// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title PositionRiskAccountingLib
/// @notice Pure borrow-utilization, carry-index, equity, and liquidation-threshold accounting for perps positions.
/// @dev settlement token values use 6 decimals, prices use 8 decimals, sizes use 18 decimals, basis points use a 10,000
///      denominator, carry indexes use 1e18 precision, and time values use seconds. Integer divisions round down.
library PositionRiskAccountingLib {

    /// @notice Fixed-point scale for cumulative carry indexes.
    uint256 internal constant CARRY_INDEX_SCALE = 1e18;
    /// @notice Basis-point scale and maximum modeled pool utilization.
    uint256 internal constant UTILIZATION_BPS = 10_000;

    /// @notice Returns economic pool depth after reserving outstanding trader claims.
    /// @dev Physical assets remain gross in custody and solvency snapshots. Only carry, skew and VPI use this depth;
    ///      open-position liabilities and the settlement buffer are not deducted again.
    function computeNetPoolDepthAssets(
        uint256 physicalAssets,
        uint256 traderClaimsAssets
    ) internal pure returns (uint256) {
        return physicalAssets > traderClaimsAssets ? physicalAssets - traderClaimsAssets : 0;
    }

    /// @notice Price-risk state for one position at a supplied collateral and margin policy.
    /// @param unrealizedPnlAssets Signed capped price PnL; positive values increase trader equity.
    /// @param equityAssets Signed post-carry PnL pledge plus same-account nettable claim and exact price PnL.
    /// @param currentNotionalAssets Position notional at the supplied price.
    /// @param maintenanceMarginAssets Requirement at `requiredBps`; the field may represent maintenance, FAD, or another
    ///        caller-selected threshold despite its historical name.
    /// @param liquidatable Whether equity is less than or equal to the requirement.
    struct PositionRiskState {
        int256 unrealizedPnlAssets;
        int256 equityAssets;
        uint256 currentNotionalAssets;
        uint256 maintenanceMarginAssets;
        bool liquidatable;
    }

    /// @notice Computes the LP-backed maximum-profit amount on which carry accrues.
    /// @dev Subtraction saturates at zero: position margin funds the maximum-profit envelope before LP assets do.
    /// @param maxProfitAssets Position maximum-profit envelope.
    /// @param marginAssets Canonical position margin.
    /// @return LP-funded borrow base `max(maxProfitAssets - marginAssets, 0)`.
    function computeBorrowBaseAssets(
        uint256 maxProfitAssets,
        uint256 marginAssets
    ) internal pure returns (uint256) {
        return maxProfitAssets > marginAssets ? maxProfitAssets - marginAssets : 0;
    }

    /// @notice Computes pool utilization by the aggregate borrow base, capped at 100%.
    /// @dev Returns zero for zero borrow base. A positive borrow base against zero pool assets is treated as 100%
    ///      utilization. Otherwise division rounds down before the 10,000-bps cap is applied.
    /// @param borrowBaseAssets LP-backed amount using pool capacity.
    /// @param poolAssets Economic pool depth after reserving outstanding trader claims.
    /// @return utilizationBps Utilization in basis points, within `[0, 10_000]`.
    function computeBorrowUtilizationBps(
        uint256 borrowBaseAssets,
        uint256 poolAssets
    ) internal pure returns (uint256 utilizationBps) {
        if (borrowBaseAssets == 0) {
            return 0;
        }
        if (poolAssets == 0) {
            return UTILIZATION_BPS;
        }
        utilizationBps = (borrowBaseAssets * UTILIZATION_BPS) / poolAssets;
        if (utilizationBps > UTILIZATION_BPS) {
            utilizationBps = UTILIZATION_BPS;
        }
    }

    /// @notice Accrues the current carry index using borrow utilization over an elapsed interval.
    /// @dev Returns `storedIndex` unchanged when time does not advance, borrow base is zero, the base rate is zero,
    ///      or computed utilization is zero. Otherwise the implementation performs one combined floor division of
    ///      `baseCarryBps * utilization * 1e18 * elapsed` by `365 days * 10_000 * 10_000`; this can retain more
    ///      precision than separately rounding an utilized bps rate first.
    /// @param storedIndex Last stored cumulative carry index, scaled by 1e18.
    /// @param previousTimestamp Timestamp through which `storedIndex` has accrued, in Unix seconds.
    /// @param currentTimestamp Timestamp to accrue through, in Unix seconds.
    /// @param borrowBaseAssets Aggregate LP-funded borrow base during the interval.
    /// @param poolAssets Economic pool depth after reserving outstanding trader claims.
    /// @param baseCarryBps Annualized rate at full utilization, in basis points.
    /// @return index Current cumulative carry index, scaled by 1e18 and rounded down at the increment.
    function computeCurrentCarryIndex(
        uint256 storedIndex,
        uint64 previousTimestamp,
        uint256 currentTimestamp,
        uint256 borrowBaseAssets,
        uint256 poolAssets,
        uint256 baseCarryBps
    ) internal pure returns (uint256 index) {
        index = storedIndex;
        if (currentTimestamp <= previousTimestamp || borrowBaseAssets == 0 || baseCarryBps == 0) {
            return index;
        }

        uint256 utilizationBps = computeBorrowUtilizationBps(borrowBaseAssets, poolAssets);
        if (utilizationBps == 0) {
            return index;
        }

        index += (baseCarryBps * utilizationBps * CARRY_INDEX_SCALE * (currentTimestamp - previousTimestamp))
            / (CfdMath.SECONDS_PER_YEAR * UTILIZATION_BPS * 10_000);
    }

    /// @notice Converts a carry-index delta into settlement token carry on a fixed borrow base.
    /// @dev Returns zero when either input is zero and otherwise rounds down by the 1e18 index scale.
    /// @param borrowBaseAssets Position or aggregate borrow base.
    /// @param carryIndexDelta Increase in the cumulative carry index, scaled by 1e18.
    /// @return Carry due in 6-decimal settlement token.
    function computeIndexedCarryAssets(
        uint256 borrowBaseAssets,
        uint256 carryIndexDelta
    ) internal pure returns (uint256) {
        if (borrowBaseAssets == 0 || carryIndexDelta == 0) {
            return 0;
        }
        return (borrowBaseAssets * carryIndexDelta) / CARRY_INDEX_SCALE;
    }

    /// @notice Builds canonical V3 price-risk equity without mixing action charges into PnL backing.
    /// @dev Equity is exactly `pnlPledge + same-account nettable claim + exact price PnL`. Callers supply pledge after
    ///      carry collection or projection; carry must not be deducted again here. VPI backing is checked separately.
    function buildExactPriceRiskState(
        CfdTypes.Position memory pos,
        uint256 entryCostAssetAtoms,
        uint256 price,
        uint256 capPrice,
        uint256 priceCollateralAssets,
        uint256 requiredBps
    ) internal pure returns (PositionRiskState memory state) {
        uint256 lots = CfdMath.sizeToLots(pos.size);
        (bool isProfit, uint256 pnlAbs) =
            CfdMath.calculateExactPnl(lots, entryCostAssetAtoms, pos.side, price, capPrice);
        state.unrealizedPnlAssets = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        state.equityAssets = int256(priceCollateralAssets) + state.unrealizedPnlAssets;
        state.currentNotionalAssets = lots * (price > capPrice ? capPrice : price);
        state.maintenanceMarginAssets = (state.currentNotionalAssets * requiredBps) / 10_000;
        state.liquidatable = state.equityAssets <= int256(state.maintenanceMarginAssets);
    }

}
