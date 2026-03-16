// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";

/// @title CfdMath
/// @notice Pure stateless math library for PnL, Price Impact, and Funding
/// @custom:security-contact contact@plether.com
library CfdMath {

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant USDC_TO_TOKEN_SCALE = 1e20; // Resolves Size(18)*Price(8) -> USDC(6)
    uint256 internal constant FUNDING_INDEX_SCALE = 1e30; // Resolves Size(18)*Index(18) -> USDC(6)

    // ==========================================
    // 1. PNL & SOLVENCY MATH
    // ==========================================

    /// @notice Calculates Unrealized PnL strictly bounded by the protocol CAP
    /// @param pos The position to evaluate
    /// @param currentOraclePrice Current oracle price (8 decimals)
    /// @param capPrice Protocol cap price (8 decimals)
    /// @return isProfit True if the position is in profit
    /// @return pnlUsdc Absolute PnL value in USDC (6 decimals)
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

    /// @notice Calculates the absolute maximum payout a trade can ever achieve
    /// @param size Notional size (18 decimals)
    /// @param entryPrice Entry oracle price (8 decimals)
    /// @param side BULL or BEAR
    /// @param capPrice Protocol cap price (8 decimals)
    /// @return maxProfitUsdc Maximum possible profit in USDC (6 decimals)
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

    // ==========================================
    // 2. VIRTUAL PRICE IMPACT (VPI)
    // ==========================================

    /// @notice Calculates the cost of a specific skew state. C(S) = 0.5 * k * (S^2 / D)
    /// @param skewUsdc The absolute directional imbalance in USDC (6 decimals)
    /// @param depthUsdc The total free USDC in the House Pool (6 decimals)
    /// @param vpiFactorWad The 'k' impact parameter (18 decimals)
    /// @return costUsdc The theoretical cost to reach this skew (6 decimals)
    function _getSkewCost(
        uint256 skewUsdc,
        uint256 depthUsdc,
        uint256 vpiFactorWad
    ) private pure returns (uint256 costUsdc) {
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
    function calculateVPI(
        uint256 preSkewUsdc,
        uint256 postSkewUsdc,
        uint256 depthUsdc,
        uint256 vpiFactorWad
    ) internal pure returns (int256 vpiUsdc) {
        uint256 preCost = _getSkewCost(preSkewUsdc, depthUsdc, vpiFactorWad);
        uint256 postCost = _getSkewCost(postSkewUsdc, depthUsdc, vpiFactorWad);

        // Intentionally uncapped negative values to allow massive MM rebates
        vpiUsdc = int256(postCost) - int256(preCost);
    }

    // ==========================================
    // 3. PROGRESSIVE FUNDING CURVE
    // ==========================================

    /// @notice Returns the annualized funding rate based on the kinked curve.
    ///         Linear ramp up to kinkSkewRatio, quadratic acceleration above it.
    /// @param absSkewUsdc Absolute directional imbalance in USDC (6 decimals)
    /// @param depthUsdc Total pool depth in USDC (6 decimals)
    /// @param params Risk parameters defining the funding curve shape
    /// @return annualizedRateWad Annualized rate (18 decimals WAD)
    function getAnnualizedFundingRate(
        uint256 absSkewUsdc,
        uint256 depthUsdc,
        CfdTypes.RiskParams memory params
    ) internal pure returns (uint256 annualizedRateWad) {
        if (depthUsdc == 0 || absSkewUsdc == 0) {
            return 0;
        }

        uint256 skewRatio = (absSkewUsdc * WAD) / depthUsdc;
        if (skewRatio > params.maxSkewRatio) {
            skewRatio = params.maxSkewRatio;
        }

        if (skewRatio <= params.kinkSkewRatio) {
            // Zone 1: Linear Ramp -> BaseApy * (skewRatio / kinkRatio)
            annualizedRateWad = (params.baseApy * skewRatio) / params.kinkSkewRatio;
        } else {
            // Zone 2: True Quadratic Hockey Stick
            uint256 excessSkew = skewRatio - params.kinkSkewRatio;
            uint256 dangerZoneSize = params.maxSkewRatio - params.kinkSkewRatio;

            // Ratio of how far we are into the danger zone (WAD)
            uint256 excessRatio = (excessSkew * WAD) / dangerZoneSize;

            // Quadratic acceleration (WAD)
            uint256 quadraticFactor = (excessRatio * excessRatio) / WAD;

            uint256 apyRange = params.maxApy - params.baseApy;
            uint256 premiumApy = (apyRange * quadraticFactor) / WAD;

            annualizedRateWad = params.baseApy + premiumApy;
        }
    }

}
