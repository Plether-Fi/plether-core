// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {Test} from "forge-std/Test.sol";

contract CfdMathFuzzTest is Test {

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant USDC_TO_TOKEN_SCALE = 1e20;

    CfdTypes.RiskParams params;

    function setUp() public {
        params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            carryKinkUtilizationBps: 7000,
            carrySlope1Bps: 0,
            carrySlope2Bps: 0,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
        });
    }

    function testFuzz_VpiExtremeDepth(
        uint256 depthUsdc,
        uint256 preSkew,
        uint256 postSkew
    ) public view {
        depthUsdc = bound(depthUsdc, 1, 1e6);
        preSkew = bound(preSkew, 0, depthUsdc);
        postSkew = bound(postSkew, 0, depthUsdc * 2);

        CfdMath.calculateVPI(preSkew, postSkew, depthUsdc, params.vpiFactor);
    }

    function testFuzz_PnlNeverExceedsMaxProfit(
        uint256 size,
        uint256 entryPrice,
        uint256 currentPrice,
        uint8 sideRaw
    ) public pure {
        size = bound(size, 1e18, 1_000_000e18);
        entryPrice = bound(entryPrice, 0.01e8, 1.99e8);
        currentPrice = bound(currentPrice, 0, 3e8);
        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;

        CfdTypes.Position memory pos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });

        (bool isProfit, uint256 pnlUsdc) = CfdMath.calculatePnL(pos, currentPrice, CAP_PRICE);
        uint256 maxProfit = CfdMath.calculateMaxProfit(size, entryPrice, side, CAP_PRICE);

        if (isProfit) {
            assertLe(pnlUsdc, maxProfit, "PnL exceeds max profit");
        }
    }

    function testFuzz_MaxProfitBounded(
        uint256 size,
        uint256 entryPrice,
        uint8 sideRaw
    ) public pure {
        size = bound(size, 1e18, 1_000_000e18);
        entryPrice = bound(entryPrice, 1, CAP_PRICE);
        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;

        uint256 maxProfit = CfdMath.calculateMaxProfit(size, entryPrice, side, CAP_PRICE);

        assertLe(maxProfit, (size * CAP_PRICE) / USDC_TO_TOKEN_SCALE, "Max profit exceeds upper bound");
    }

}
