// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {StakedToken} from "../../src/StakedToken.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {BaseForkTest, ICurvePoolExtended, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title ZapRouter Fork Tests
/// @notice Tests ZapRouter with real Curve pool on mainnet fork
contract ZapRouterForkTest is BaseForkTest {

    StakedToken stBull;
    StakedToken stBear;
    ZapRouter zapRouter;
    StakedOracle stakedOracle;

    function setUp() public {
        _setupFork();
        if (block.chainid != 1) {
            revert("Wrong Chain! Must be Mainnet.");
        }

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

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        IERC20(bullToken).approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReturned = usdcAfter - usdcBefore;

        // Round-trip cost sources:
        // - 2x Curve swap fees (~0.04% each = ~0.08% total)
        // - 2x Curve pool price impact (~0.2% each for this size)
        // - Flash mint fee (if any)
        // Threshold: <1.5% allows for larger trades or worse pool conditions
        assertGt(usdcReturned, (amountIn * 985) / 1000, "Should return >98.5% of original USDC");
        assertEq(IERC20(bullToken).balanceOf(address(this)), bullBefore, "All minted BULL burned");
    }

}

/// @title ZapRouter Direct Path Fork Tests
/// @notice Reproduces the exact mainnet failure (BEAR ~$1.001 on 25k pool) and verifies the fix
contract ZapRouterDirectPathForkTest is Test {

    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SPLITTER = 0x81D7f6eE951f5272043de05E6EE25c58a440c2DF;
    address constant BEAR = 0xEDE56A22771c7fDA8b80Cc1A1fa2B54420cD4A5d;
    address constant BULL = 0xF20D4E93ee2F3948E4aE998F7C3A5Ec9E0aBD4c4;
    address constant CURVE_POOL = 0x2354579380cAd0518C6518e5Ee2A66d30d0149bE;
    address constant OLD_ZAP_ROUTER = 0x96bEEF7872c9bFD746359aD51bE35f1A8e3C99dE;

    address user;

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }
        user = makeAddr("user");
    }

    function test_zapMint_600USDC_fails_on_mainnet_fork() public {
        uint256 bearPrice = ICurvePoolExtended(CURVE_POOL).get_dy(1, 0, 1e18);
        console.log("Current BEAR price (6 dec):", bearPrice);

        if (bearPrice <= 1_000_000) {
            console.log("BEAR not overpriced, bug only manifests when BEAR > $1.00, skipping");
            return;
        }

        deal(_USDC, user, 600e6);

        vm.startPrank(user);
        IERC20(_USDC).approve(OLD_ZAP_ROUTER, 600e6);

        vm.expectRevert();
        ZapRouter(OLD_ZAP_ROUTER).zapMint(600e6, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_zapMint_600USDC_succeeds_after_fix() public {
        uint256 bearPrice = ICurvePoolExtended(CURVE_POOL).get_dy(1, 0, 1e18);
        console.log("Current BEAR price (6 dec):", bearPrice);

        ZapRouter newRouter = new ZapRouter(SPLITTER, BEAR, BULL, _USDC, CURVE_POOL);

        deal(_USDC, user, 600e6);

        vm.startPrank(user);
        IERC20(_USDC).approve(address(newRouter), 600e6);

        uint256 bullBefore = IERC20(BULL).balanceOf(user);
        newRouter.zapMint(600e6, 0, 100, block.timestamp + 1 hours);
        uint256 bullReceived = IERC20(BULL).balanceOf(user) - bullBefore;
        vm.stopPrank();

        console.log("BULL received:", bullReceived);
        assertGt(bullReceived, 0, "Should receive BULL tokens");

        (uint256 flashAmount,,, uint256 expectedTokensOut,) = newRouter.previewZapMint(600e6);
        if (flashAmount == 0) {
            console.log("Direct path used -preview tokens:", expectedTokensOut);
        } else {
            console.log("Flash path used -preview tokens:", expectedTokensOut);
        }
    }

}
