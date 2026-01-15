// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseForkTest, ICurvePoolExtended} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

/// @title Slippage Report Test
/// @notice Reports slippage for various trade sizes as percentage of pool liquidity
contract SlippageReportTest is BaseForkTest {

    uint256[] percentages;

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 100_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(address(this));
        _mintInitialTokens(1_000_000e18);
        _deployCurvePool(800_000e18);

        percentages = new uint256[](10);
        percentages[0] = 10; // 0.1%
        percentages[1] = 100; // 1%
        percentages[2] = 200; // 2%
        percentages[3] = 300; // 3%
        percentages[4] = 500; // 5%
        percentages[5] = 1000; // 10%
        percentages[6] = 1500; // 15%
        percentages[7] = 2000; // 20%
        percentages[8] = 3300; // 33%
        percentages[9] = 4000; // 40%
    }

    function test_SlippageReport_SellBear() public view {
        console.log("=== SLIPPAGE REPORT: Sell DXY-BEAR for USDC ===");
        console.log("Pool liquidity: 800,000 DXY-BEAR");
        console.log("Curve params: A=%s, gamma=%s", CURVE_A, CURVE_GAMMA);
        console.log("");
        console.log("| Trade Size | BEAR Amount | Expected USDC | Actual USDC | Slippage |");
        console.log("|------------|-------------|---------------|-------------|----------|");

        uint256 poolLiquidity = 800_000e18;

        // Get spot price (tiny trade)
        uint256 spotPrice = ICurvePoolExtended(curvePool).get_dy(1, 0, 1e18);

        for (uint256 i = 0; i < percentages.length; i++) {
            uint256 pct = percentages[i];
            uint256 bearAmount = (poolLiquidity * pct) / 10_000;

            // Expected USDC at spot price (no slippage)
            uint256 expectedUsdc = (bearAmount * spotPrice) / 1e18;

            // Actual USDC from Curve
            uint256 actualUsdc = ICurvePoolExtended(curvePool).get_dy(1, 0, bearAmount);

            // Slippage in bps
            uint256 slippageBps = expectedUsdc > actualUsdc ? ((expectedUsdc - actualUsdc) * 10_000) / expectedUsdc : 0;

            _logRow(pct, bearAmount, expectedUsdc, actualUsdc, slippageBps);
        }
        console.log("");
    }

    function test_SlippageReport_BuyBear() public view {
        console.log("=== SLIPPAGE REPORT: Buy DXY-BEAR with USDC ===");
        console.log("Pool liquidity: ~660,000 USDC equivalent");
        console.log("Curve params: A=%s, gamma=%s", CURVE_A, CURVE_GAMMA);
        console.log("");
        console.log("| Trade Size | USDC Amount | Expected BEAR | Actual BEAR | Slippage |");
        console.log("|------------|-------------|---------------|-------------|----------|");

        // USDC side of pool (approximately)
        uint256 poolLiquidityUsdc = 660_000e6;

        // Get spot price (tiny trade)
        uint256 spotBearPerUsdc = ICurvePoolExtended(curvePool).get_dy(0, 1, 1e6);

        for (uint256 i = 0; i < percentages.length; i++) {
            uint256 pct = percentages[i];
            uint256 usdcAmount = (poolLiquidityUsdc * pct) / 10_000;

            // Expected BEAR at spot price (no slippage)
            // spotBearPerUsdc is BEAR per 1 USDC (1e6), so divide by 1e6
            uint256 expectedBear = (usdcAmount * spotBearPerUsdc) / 1e6;

            // Actual BEAR from Curve
            uint256 actualBear = ICurvePoolExtended(curvePool).get_dy(0, 1, usdcAmount);

            // Slippage in bps
            uint256 slippageBps = expectedBear > actualBear ? ((expectedBear - actualBear) * 10_000) / expectedBear : 0;

            _logRowUsdc(pct, usdcAmount, expectedBear, actualBear, slippageBps);
        }
        console.log("");
    }

    function test_SlippageReport_RoundTrip() public {
        console.log("=== SLIPPAGE REPORT: Round-trip (Sell BEAR -> Buy BEAR) ===");
        console.log("Pool liquidity: 800,000 DXY-BEAR");
        console.log("Curve params: A=%s, gamma=%s", CURVE_A, CURVE_GAMMA);
        console.log("");
        console.log("| Trade Size | BEAR In | USDC Mid | BEAR Out | Round-trip Loss |");
        console.log("|------------|---------|----------|----------|-----------------|");

        uint256 poolLiquidity = 800_000e18;

        for (uint256 i = 0; i < percentages.length; i++) {
            uint256 pct = percentages[i];
            uint256 bearIn = (poolLiquidity * pct) / 10_000;

            // Sell BEAR for USDC
            uint256 usdcMid = ICurvePoolExtended(curvePool).get_dy(1, 0, bearIn);

            // Buy BEAR back with USDC
            uint256 bearOut = ICurvePoolExtended(curvePool).get_dy(0, 1, usdcMid);

            // Round-trip loss in bps
            uint256 lossBps = bearIn > bearOut ? ((bearIn - bearOut) * 10_000) / bearIn : 0;

            _logRowRoundTrip(pct, bearIn, usdcMid, bearOut, lossBps);
        }
        console.log("");
    }

    function _logRow(
        uint256 pct,
        uint256 bearAmount,
        uint256 expectedUsdc,
        uint256 actualUsdc,
        uint256 slippageBps
    ) internal pure {
        console.log(_formatPct(pct));
        console.log("  BEAR amount:", bearAmount / 1e18);
        console.log("  Expected USDC:", expectedUsdc / 1e6);
        console.log("  Actual USDC:", actualUsdc / 1e6);
        console.log("  Slippage (bps):", slippageBps);
    }

    function _logRowUsdc(
        uint256 pct,
        uint256 usdcAmount,
        uint256 expectedBear,
        uint256 actualBear,
        uint256 slippageBps
    ) internal pure {
        console.log(_formatPct(pct));
        console.log("  USDC amount:", usdcAmount / 1e6);
        console.log("  Expected BEAR:", expectedBear / 1e18);
        console.log("  Actual BEAR:", actualBear / 1e18);
        console.log("  Slippage (bps):", slippageBps);
    }

    function _logRowRoundTrip(
        uint256 pct,
        uint256 bearIn,
        uint256 usdcMid,
        uint256 bearOut,
        uint256 lossBps
    ) internal pure {
        console.log(_formatPct(pct));
        console.log("  BEAR in:", bearIn / 1e18);
        console.log("  USDC mid:", usdcMid / 1e6);
        console.log("  BEAR out:", bearOut / 1e18);
        console.log("  Round-trip loss (bps):", lossBps);
    }

    function _formatPct(
        uint256 bps
    ) internal pure returns (string memory) {
        if (bps == 10) return "0.1%  ";
        if (bps == 100) return "1%    ";
        if (bps == 200) return "2%    ";
        if (bps == 300) return "3%    ";
        if (bps == 500) return "5%    ";
        if (bps == 1000) return "10%   ";
        if (bps == 1500) return "15%   ";
        if (bps == 2000) return "20%   ";
        if (bps == 3300) return "33%   ";
        if (bps == 4000) return "40%   ";
        return "?%    ";
    }

    function _formatBear(
        uint256 amount
    ) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        if (whole >= 1_000_000) return string(abi.encodePacked(_uint2str(whole / 1000), "k"));
        if (whole >= 1000) return string(abi.encodePacked(_uint2str(whole / 1000), "k"));
        return _uint2str(whole);
    }

    function _formatUsdc(
        uint256 amount
    ) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        if (whole >= 1_000_000) return string(abi.encodePacked(_uint2str(whole / 1000), "k"));
        if (whole >= 1000) return string(abi.encodePacked(_uint2str(whole / 1000), "k"));
        return _uint2str(whole);
    }

    function _uint2str(
        uint256 _i
    ) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

}
