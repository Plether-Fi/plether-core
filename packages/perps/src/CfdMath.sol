// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

    // ==========================================
    // 1. PNL & SOLVENCY MATH
    // ==========================================

    /// @notice Calculates unrealized PnL after clamping the oracle price to the protocol cap.
    /// @dev A zero-size position returns `(false, 0)`. At exactly the entry price, a nonzero position is
    ///      classified as profitable with zero PnL. Multiplication uses ordinary checked arithmetic.
    /// @param pos Position to evaluate; size is 18 decimals and entry price is 8 decimals.
    /// @param currentOraclePrice Current BEAR-leg oracle price (8 decimals).
    /// @param capPrice Protocol maximum oracle price (8 decimals).
    /// @return isProfit Whether the price move is favorable to `pos.side` (including equality).
    /// @return pnlUsdc Absolute PnL in 6-decimal USDC.
    function calculatePnL(
        CfdTypes.Position memory pos,
        uint256 currentOraclePrice,
        uint256 capPrice
    ) internal pure returns (bool isProfit, uint256 pnlUsdc) {
        if (pos.size == 0) {
            return (false, 0);
        }

        // O(1) Solvency Guarantee: Clamp oracle price to Protocol CAP
        uint256 price = currentOraclePrice > capPrice ? capPrice : currentOraclePrice;
        uint256 priceDiff;

        if (pos.side == CfdTypes.Side.BULL) {
            // BULL profits when oracle price drops (USD strengthens)
            isProfit = price <= pos.entryPrice;
            priceDiff = isProfit ? (pos.entryPrice - price) : (price - pos.entryPrice);
        } else {
            // BEAR profits when oracle price rises (USD weakens)
            isProfit = price >= pos.entryPrice;
            priceDiff = isProfit ? (price - pos.entryPrice) : (pos.entryPrice - price);
        }

        // size(18) * priceDiff(8) / 1e20 = USDC(6)
        pnlUsdc = (pos.size * priceDiff) / USDC_TO_TOKEN_SCALE;
    }

    /// @notice Calculates the maximum profit available between zero and the protocol price cap.
    /// @dev BULL uses a zero-price endpoint. BEAR uses `capPrice` and therefore returns zero when the
    ///      entry price is at or above the cap. A zero-size position also returns zero.
    /// @param size Notional size in synthetic-token units (18 decimals).
    /// @param entryPrice Entry oracle price (8 decimals).
    /// @param side Position direction.
    /// @param capPrice Protocol maximum oracle price (8 decimals).
    /// @return maxProfitUsdc Maximum profit in 6-decimal USDC.
    function calculateMaxProfit(
        uint256 size,
        uint256 entryPrice,
        CfdTypes.Side side,
        uint256 capPrice
    ) internal pure returns (uint256 maxProfitUsdc) {
        if (size == 0) {
            return 0;
        }

        uint256 maxPriceDiff;
        if (side == CfdTypes.Side.BULL) {
            // Max profit when price hits 0
            maxPriceDiff = entryPrice;
        } else {
            // Max profit when price hits CAP
            maxPriceDiff = capPrice > entryPrice ? capPrice - entryPrice : 0;
        }
        maxProfitUsdc = (size * maxPriceDiff) / USDC_TO_TOKEN_SCALE;
    }

    /// @notice Conservative upper bound for a side's current gross winning-trader MtM liability.
    /// @dev Uses each position's max-profit envelope so same-side losing positions cannot net down
    ///      winning positions before their losses are physically realized. Returns zero when either
    ///      `maxProfitUsdc` or `capPrice` is zero and rounds a nonzero result up to whole USDC atoms.
    /// @param maxProfitUsdc Aggregate maximum-profit envelope for the side (6-decimal USDC).
    /// @param side Side whose liability envelope is being marked.
    /// @param price Current oracle price (8 decimals); values above `capPrice` are clamped.
    /// @param capPrice Protocol maximum oracle price (8 decimals).
    /// @return Conservative marked liability in 6-decimal USDC.
    function conservativeMtmLiability(
        uint256 maxProfitUsdc,
        CfdTypes.Side side,
        uint256 price,
        uint256 capPrice
    ) internal pure returns (uint256) {
        if (maxProfitUsdc == 0 || capPrice == 0) {
            return 0;
        }

        uint256 clampedPrice = price > capPrice ? capPrice : price;
        if (side == CfdTypes.Side.BULL) {
            return Math.mulDiv(maxProfitUsdc, capPrice - clampedPrice, capPrice, Math.Rounding.Ceil);
        }
        return Math.mulDiv(maxProfitUsdc, clampedPrice, capPrice, Math.Rounding.Ceil);
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
