// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title CfdMath
/// @notice Pure stateless arithmetic for capped PnL, solvency envelopes, and virtual price impact.
/// @custom:security-contact contact@plether.com
library CfdMath {

    /// @notice Fixed-point scalar used for 18-decimal ratios.
    uint256 internal constant WAD = 1e18;
    /// @notice 365-day year used by annualized perps accounting.
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    /// @notice Divisor converting size (18 decimals) times price (8 decimals) to USDC (6 decimals).
    uint256 internal constant USDC_TO_TOKEN_SCALE = 1e20; // Resolves Size(18)*Price(8) -> USDC(6)

    /// @notice Converts a quantum-aligned position size into whole 100-token lots.
    /// @dev Reverts when `size` is not exactly representable in the canonical lot size.
    function sizeToLots(
        uint256 size
    ) internal pure returns (uint256 lots) {
        if (size % CfdTypes.SIZE_QUANTUM != 0) {
            revert CfdMath__InvalidSizeQuantum();
        }
        lots = size / CfdTypes.SIZE_QUANTUM;
    }

    /// @notice Thrown when a position size is not divisible by the canonical 100-token quantum.
    error CfdMath__InvalidSizeQuantum();

    // ==========================================
    // 1. PNL & SOLVENCY MATH
    // ==========================================

    /// @notice Calculates exact capped price PnL from canonical lots and entry cost.
    /// @dev `entryCostUsdcAtoms` is the sum of `addedLots * executionPrice` and therefore already uses 6-decimal
    ///      USDC atoms. No average-entry-price rounding is involved. Equality is classified as profit.
    /// @param lots Position size in canonical 100-token lots.
    /// @param entryCostUsdcAtoms Exact entry cost in 6-decimal USDC atoms.
    /// @param side Position direction.
    /// @param currentOraclePrice Current raw FX-basket mark, with 8 decimals.
    /// @param capPrice Protocol maximum oracle price, with 8 decimals.
    /// @return isProfit Whether the marked price move is favorable, including equality.
    /// @return pnlUsdc Absolute exact PnL in 6-decimal USDC atoms.
    function calculateExactPnl(
        uint256 lots,
        uint256 entryCostUsdcAtoms,
        CfdTypes.Side side,
        uint256 currentOraclePrice,
        uint256 capPrice
    ) internal pure returns (bool isProfit, uint256 pnlUsdc) {
        if (lots == 0) {
            return (false, 0);
        }

        uint256 price = currentOraclePrice > capPrice ? capPrice : currentOraclePrice;
        uint256 exitValueUsdcAtoms = lots * price;
        if (side == CfdTypes.Side.LONG) {
            isProfit = entryCostUsdcAtoms >= exitValueUsdcAtoms;
        } else {
            isProfit = exitValueUsdcAtoms >= entryCostUsdcAtoms;
        }
        pnlUsdc = isProfit
            ? (side == CfdTypes.Side.LONG
                    ? entryCostUsdcAtoms - exitValueUsdcAtoms
                    : exitValueUsdcAtoms - entryCostUsdcAtoms)
            : (side == CfdTypes.Side.LONG
                    ? exitValueUsdcAtoms - entryCostUsdcAtoms
                    : entryCostUsdcAtoms - exitValueUsdcAtoms);
    }

    /// @notice Returns the exact endpoint profit envelope for a lot-based position.
    function calculateExactMaxProfit(
        uint256 lots,
        uint256 entryCostUsdcAtoms,
        CfdTypes.Side side,
        uint256 capPrice
    ) internal pure returns (uint256) {
        if (lots == 0) {
            return 0;
        }
        if (side == CfdTypes.Side.LONG) {
            return entryCostUsdcAtoms;
        }
        uint256 capValueUsdcAtoms = lots * capPrice;
        return capValueUsdcAtoms > entryCostUsdcAtoms ? capValueUsdcAtoms - entryCostUsdcAtoms : 0;
    }

    // ==========================================
    // 2. VIRTUAL PRICE IMPACT (VPI)
    // ==========================================

    /// @notice Calculates the cost of an absolute skew state as `C(S) = 0.5 * k * S^2 / D`.
    /// @dev Returns zero when skew or depth is zero. Intermediate WAD scaling and ordinary checked
    ///      multiplication can revert for inputs outside the protocol's supported numeric range.
    /// @param skewUsdc Absolute directional imbalance in 6-decimal USDC.
    /// @param depthUsdc House-pool depth in 6-decimal USDC.
    /// @param vpiFactorWad Impact factor `k` (18-decimal WAD).
    /// @return costUsdc Theoretical cost of reaching the skew, truncated to 6-decimal USDC.
    function getSkewCost(
        uint256 skewUsdc,
        uint256 depthUsdc,
        uint256 vpiFactorWad
    ) internal pure returns (uint256 costUsdc) {
        if (depthUsdc == 0 || skewUsdc == 0) {
            return 0;
        }

        // Scale to WAD internally to prevent precision loss on squaring
        uint256 skewWad = skewUsdc * 1e12;
        uint256 depthWad = depthUsdc * 1e12;

        // (S^2 * WAD) / D => scaled to WAD
        uint256 sqSkewOverDepthWad = (skewWad * skewWad) / depthWad;

        // Cost = (k * (S^2 / D)) / 2
        uint256 costWad = (vpiFactorWad * sqSkewOverDepthWad) / WAD / 2;

        // Scale back to 6 decimals (USDC)
        costUsdc = costWad / 1e12;
    }

    /// @notice Calculates the VPI charge/rebate for a trade.
    /// @dev If postCost > preCost, result is positive (Charge Trader).
    ///      If postCost < preCost, result is negative (Rebate Trader / MM Incentive).
    /// @param preSkewUsdc Absolute directional skew before the trade (6-decimal USDC).
    /// @param postSkewUsdc Absolute directional skew after the trade (6-decimal USDC).
    /// @param depthUsdc House-pool depth used for both cost states (6-decimal USDC).
    /// @param vpiFactorWad Impact factor `k` (18-decimal WAD).
    /// @return vpiUsdc Signed VPI in 6-decimal USDC: positive is a charge and negative is a rebate.
    function calculateVPI(
        uint256 preSkewUsdc,
        uint256 postSkewUsdc,
        uint256 depthUsdc,
        uint256 vpiFactorWad
    ) internal pure returns (int256 vpiUsdc) {
        uint256 preCost = getSkewCost(preSkewUsdc, depthUsdc, vpiFactorWad);
        uint256 postCost = getSkewCost(postSkewUsdc, depthUsdc, vpiFactorWad);

        // Intentionally uncapped negative values to allow massive MM rebates
        vpiUsdc = int256(postCost) - int256(preCost);
    }

}
