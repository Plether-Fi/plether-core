// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {Test, console} from "forge-std/Test.sol";

contract CfdMathTest is Test {

    uint256 constant WAD = 1e18;
    uint256 constant CAP_PRICE = 2e8; // $2.00 in 8 decimals

    CfdTypes.RiskParams params;

    function setUp() public {
        // Set up standard institutional risk parameters
        params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18, // 5 bps impact factor
            maxSkewRatio: 0.4e18, // 40% Hard wall // 25% Inflection point // 15% APY at the kink // 300% APY at the wall
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    // ==========================================
    // 1. PNL & SOLVENCY BOUNDS
    // ==========================================

    function test_CalculatePnL_Bull() public pure {
        // 100k Size (18 dec), Entry $1.00 (8 dec)
        CfdTypes.Position memory pos = CfdTypes.Position({
            size: 100_000 * 1e18,
            margin: 2000 * 1e6, // $2k margin (50x leverage)
            entryPrice: 1e8,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BULL,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        // Price drops to $0.98 (BULL makes $0.02 * 100k = $2,000)
        (bool isProfit, uint256 pnl) = CfdMath.calculatePnL(pos, 0.98e8, CAP_PRICE);
        assertTrue(isProfit);
        assertEq(pnl, 2000 * 1e6); // $2,000 USDC

        // Price rises to $1.05 (BULL loses $0.05 * 100k = $5,000)
        (isProfit, pnl) = CfdMath.calculatePnL(pos, 1.05e8, CAP_PRICE);
        assertFalse(isProfit);
        assertEq(pnl, 5000 * 1e6); // $5,000 USDC
    }

    function test_CalculatePnL_ClampsToCap() public pure {
        CfdTypes.Position memory pos = CfdTypes.Position({
            size: 100_000 * 1e18,
            margin: 2000 * 1e6,
            entryPrice: 1e8,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        // Oracle teleports to $5.00 (way above the $2.00 CAP)
        // Profit should be clamped to ($2.00 - $1.00) * 100k = $100,000
        (bool isProfit, uint256 pnl) = CfdMath.calculatePnL(pos, 5e8, CAP_PRICE);
        assertTrue(isProfit);
        assertEq(pnl, 100_000 * 1e6); // PnL strictly clamped
    }

    function test_CalculateMaxProfit() public pure {
        uint256 size = 100_000 * 1e18;
        uint256 entryPrice = 1.0e8;

        // BULL max profit (Price drops from $1.00 to $0.00)
        uint256 bullMax = CfdMath.calculateMaxProfit(size, entryPrice, CfdTypes.Side.BULL, CAP_PRICE);
        assertEq(bullMax, 100_000 * 1e6); // $100k max

        // BEAR max profit (Price rises from $1.00 to $2.00 CAP)
        uint256 bearMax = CfdMath.calculateMaxProfit(size, entryPrice, CfdTypes.Side.BEAR, CAP_PRICE);
        assertEq(bearMax, 100_000 * 1e6); // $100k max
    }

    // ==========================================
    // 2. VPI WASH-TRADE IMMUNITY (FUZZ TEST)
    // ==========================================

    /// @notice Proves that Opening and Closing the exact same position results in exactly 0 net VPI.
    /// This guarantees wash-trading to farm rebates is mathematically impossible.
    function testFuzz_VpiWashTradingIsZeroSum(
        uint256 preSkewUsdc,
        uint256 tradeSizeUsdc,
        uint256 depthUsdc
    ) public view {
        // Bound fuzz inputs to realistic protocol limits (min $10k depth, max $100m depth)
        depthUsdc = bound(depthUsdc, 10_000 * 1e6, 100_000_000 * 1e6);
        // Pre-skew can be up to 40% of depth
        preSkewUsdc = bound(preSkewUsdc, 0, (depthUsdc * 40) / 100);
        // Trade size shouldn't exceed remaining depth
        tradeSizeUsdc = bound(tradeSizeUsdc, 1 * 1e6, depthUsdc / 10);

        uint256 postSkewUsdc = preSkewUsdc + tradeSizeUsdc;

        int256 vpiCharge = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, depthUsdc, params.vpiFactor);
        int256 vpiRebate = CfdMath.calculateVPI(postSkewUsdc, preSkewUsdc, depthUsdc, params.vpiFactor);

        if (vpiCharge == 0) {
            // Dust trade: both legs round to zero — still zero-sum
            assertEq(vpiRebate, 0, "Dust rebate must also be zero");
        } else {
            assertTrue(vpiCharge > 0, "VPI charge should be positive");
            assertTrue(vpiRebate < 0, "VPI rebate should be negative");
            assertEq(vpiCharge + vpiRebate, 0, "Wash trade net VPI must be exactly zero");
        }
    }

    /// @notice Proves a whale splitting trades into chunks costs exactly the same VPI
    function test_VpiPathIndependence() public pure {
        uint256 depthUsdc = 10_000_000 * 1e6;
        uint256 vpiFactor = 0.0005e18;

        // Whale does one $1M trade
        int256 massiveTradeCharge = CfdMath.calculateVPI(0, 1_000_000 * 1e6, depthUsdc, vpiFactor);

        // Whale splits into ten sequential $100k trades
        int256 splitTradeCharge = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 pre = i * 100_000 * 1e6;
            uint256 post = (i + 1) * 100_000 * 1e6;
            splitTradeCharge += CfdMath.calculateVPI(pre, post, depthUsdc, vpiFactor);
        }

        assertEq(massiveTradeCharge, splitTradeCharge, "VPI must be path independent");
    }

    // ==========================================
    // 4. BEAR PNL & EDGE CASES
    // ==========================================

    function test_CalculatePnL_Bear() public pure {
        CfdTypes.Position memory pos = CfdTypes.Position({
            size: 100_000 * 1e18,
            margin: 2000 * 1e6,
            entryPrice: 0.8e8,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        // Price rises to $0.95 → BEAR profits (profits when oracle rises)
        (bool isProfit, uint256 pnl) = CfdMath.calculatePnL(pos, 0.95e8, CAP_PRICE);
        assertTrue(isProfit);
        assertEq(pnl, 15_000 * 1e6); // $0.15 * 100k = $15,000

        // Price drops to $0.70 → BEAR loses
        (isProfit, pnl) = CfdMath.calculatePnL(pos, 0.7e8, CAP_PRICE);
        assertFalse(isProfit);
        assertEq(pnl, 10_000 * 1e6); // $0.10 * 100k = $10,000
    }

    function test_CalculatePnL_ZeroSize() public pure {
        CfdTypes.Position memory pos = CfdTypes.Position({
            size: 0,
            margin: 0,
            entryPrice: 1e8,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BULL,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        (bool isProfit, uint256 pnl) = CfdMath.calculatePnL(pos, 1.5e8, CAP_PRICE);
        assertFalse(isProfit);
        assertEq(pnl, 0);
    }

    // ==========================================
    // 5. VPI UNIT TESTS
    // ==========================================

    function test_VPI_ChargesWhenAddingToSkew() public pure {
        int256 vpi = CfdMath.calculateVPI(1_000_000 * 1e6, 2_000_000 * 1e6, 10_000_000 * 1e6, 0.0005e18);
        assertTrue(vpi > 0, "VPI should charge when adding to skew");
    }

    function test_VPI_RebatesWhenReducingSkew() public pure {
        int256 vpi = CfdMath.calculateVPI(2_000_000 * 1e6, 1_000_000 * 1e6, 10_000_000 * 1e6, 0.0005e18);
        assertTrue(vpi < 0, "VPI should rebate when reducing skew");
    }

    function test_VPI_ZeroDepth() public pure {
        int256 vpi = CfdMath.calculateVPI(1_000_000 * 1e6, 2_000_000 * 1e6, 0, 0.0005e18);
        assertEq(vpi, 0, "VPI should be zero when depth is zero");
    }

    function test_MaxProfit_BearAtCap_IsZero() public pure {
        uint256 maxProfit = CfdMath.calculateMaxProfit(100_000 * 1e18, CAP_PRICE, CfdTypes.Side.BEAR, CAP_PRICE);
        assertEq(maxProfit, 0, "BEAR at CAP entry has zero max profit");
    }

}
