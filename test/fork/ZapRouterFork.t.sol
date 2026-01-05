// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BaseForkTest, MockCurvePoolForOracle, MockMorphoOracleForYield} from "./BaseForkTest.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ZapRouter Fork Tests
/// @notice Tests ZapRouter with real Curve pool on mainnet fork
contract ZapRouterForkTest is BaseForkTest {
    StakedToken stBull;
    StakedToken stBear;
    ZapRouter zapRouter;
    StakedOracle stakedOracle;

    function setUp() public {
        _setupFork();
        if (block.chainid != 1) revert("Wrong Chain! Must be Mainnet.");

        deal(USDC, address(this), 2_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");
        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(500_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);
    }

    function test_ZapMint_RealExecution() public {
        uint256 amountIn = 1000e6;
        IERC20(USDC).approve(address(zapRouter), amountIn);
        uint256 balanceBefore = IERC20(bullToken).balanceOf(address(this));

        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 balanceAfter = IERC20(bullToken).balanceOf(address(this));

        console.log("USDC In:", amountIn);
        console.log("BULL Out:", balanceAfter - balanceBefore);

        assertGt(balanceAfter, balanceBefore);
    }

    function test_SplitterMint_RealExecution() public {
        uint256 mintAmount = 1000e18;
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);

        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        splitter.mint(mintAmount);

        uint256 bullAfter = IERC20(bullToken).balanceOf(address(this));
        assertEq(bullAfter - bullBefore, mintAmount);
    }

    function test_ZapBurn_RealExecution() public {
        uint256 amountIn = 100e6;
        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        IERC20(USDC).approve(address(zapRouter), amountIn);
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 bullMinted = IERC20(bullToken).balanceOf(address(this)) - bullBefore;
        console.log("BULL minted:", bullMinted);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        IERC20(bullToken).approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReturned = usdcAfter - usdcBefore;

        console.log("USDC returned:", usdcReturned);
        console.log("Round-trip cost:", amountIn - usdcReturned);

        // Round-trip costs include: 2x Curve swap fees, flash mint fees, and slippage
        // Expect ~2-3% loss on round trip, so require >97% return
        assertGt(usdcReturned, 97e6, "Should return >97% of original USDC");
        assertEq(IERC20(bullToken).balanceOf(address(this)), bullBefore, "All minted BULL burned");
    }
}
