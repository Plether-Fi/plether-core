// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BaseForkTest, MockCurvePoolForOracle, MockMorphoOracleForYield, ICurvePoolExtended} from "./BaseForkTest.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {LeverageRouterBase} from "../../src/base/LeverageRouterBase.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Slippage Protection Fork Tests
/// @notice Adversarial tests proving routers protect users from MEV/price manipulation
contract SlippageProtectionForkTest is BaseForkTest {
    ZapRouter zapRouter;
    StakedToken stBear;
    StakedToken stBull;
    LeverageRouter leverageRouter;
    BullLeverageRouter bullLeverageRouter;
    MorphoOracle bearMorphoOracle;
    MorphoOracle bullMorphoOracle;
    MarketParams bearMarketParams;
    MarketParams bullMarketParams;

    address alice = address(0xA11CE);
    address whale = address(0xBA1E);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 10_000_000e6);
        deal(USDC, alice, 100_000e6);
        deal(USDC, whale, 10_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(1_000_000e18);
        _deployCurvePool(800_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);

        bearMorphoOracle = new MorphoOracle(address(basketOracle), 2e8, false);
        bullMorphoOracle = new MorphoOracle(address(basketOracle), 2e8, true);

        bearMarketParams = _createMorphoMarket(address(stBear), address(bearMorphoOracle), 2_000_000e6);
        bullMarketParams = _createMorphoMarket(address(stBull), address(bullMorphoOracle), 2_000_000e6);

        leverageRouter = new LeverageRouter(MORPHO, curvePool, USDC, bearToken, address(stBear), bearMarketParams);
        bullLeverageRouter = new BullLeverageRouter(
            MORPHO, address(splitter), curvePool, USDC, bearToken, bullToken, address(stBull), bullMarketParams
        );
    }

    function _whaleDumpBear(uint256 bearAmount) internal {
        vm.startPrank(whale);
        (uint256 usdcNeeded,,) = splitter.previewMint(bearAmount);
        IERC20(USDC).approve(address(splitter), usdcNeeded);
        splitter.mint(bearAmount);

        IERC20(bearToken).approve(curvePool, bearAmount);
        (bool success,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, bearAmount, 0));
        require(success, "Whale dump failed");
        vm.stopPrank();
    }

    function _whalePumpBear(uint256 usdcAmount) internal {
        vm.startPrank(whale);
        IERC20(USDC).approve(curvePool, usdcAmount);
        (bool success,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, usdcAmount, 0));
        require(success, "Whale pump failed");
        vm.stopPrank();
    }

    function test_ZapMint_RevertsOnWhaleDump() public {
        uint256 userAmount = 10_000e6;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), userAmount);
        vm.stopPrank();

        uint256 priceBear = ICurvePoolExtended(curvePool).get_dy(1, 0, 1e18);
        uint256 capPrice = splitter.CAP() / 100;
        uint256 priceBull = capPrice - priceBear;
        uint256 expectedBull = (userAmount * 1e18) / priceBull;

        _whaleDumpBear(100_000e18);

        uint256 minOut = (expectedBull * 95) / 100;

        vm.startPrank(alice);
        vm.expectRevert(ZapRouter.ZapRouter__InsufficientOutput.selector);
        zapRouter.zapMint(userAmount, minOut, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SucceedsWithNoManipulation() public {
        uint256 userAmount = 1000e6;

        uint256 priceBear = ICurvePoolExtended(curvePool).get_dy(1, 0, 1e18);
        uint256 capPrice = splitter.CAP() / 100;
        uint256 priceBull = capPrice - priceBear;
        uint256 expectedBull = (userAmount * 1e18) / priceBull;

        uint256 minOut = (expectedBull * 90) / 100;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), userAmount);
        uint256 bullBefore = IERC20(bullToken).balanceOf(alice);

        zapRouter.zapMint(userAmount, minOut, 100, block.timestamp + 1 hours);

        uint256 bullReceived = IERC20(bullToken).balanceOf(alice) - bullBefore;
        vm.stopPrank();

        assertGt(bullReceived, minOut, "Should receive more than minOut");
    }

    function test_ZapBurn_RevertsOnWhalePump() public {
        uint256 zapAmount = 5000e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), zapAmount);
        zapRouter.zapMint(zapAmount, 0, 100, block.timestamp + 1 hours);
        uint256 bullBalance = IERC20(bullToken).balanceOf(alice);
        vm.stopPrank();

        uint256 capPrice = splitter.CAP() / 100;
        uint256 grossUsdc = (bullBalance * capPrice) / 1e18;
        uint256 expectedUsdc = (grossUsdc * 90) / 100;

        _whalePumpBear(500_000e6);

        uint256 minUsdcOut = (expectedUsdc * 95) / 100;

        vm.startPrank(alice);
        IERC20(bullToken).approve(address(zapRouter), bullBalance);
        vm.expectRevert();
        zapRouter.zapBurn(bullBalance, minUsdcOut, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_LeverageRouter_SlippageProtectionLimitsLoss() public {
        uint256 principal = 20_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        (, uint256 totalUSDC, uint256 expectedBear,) = leverageRouter.previewOpenLeverage(principal, leverage);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (,, uint128 actualCollateral) = IMorpho(MORPHO).position(marketId, alice);

        uint256 minAcceptable = (expectedBear * 99) / 100;
        assertGe(actualCollateral, minAcceptable, "Slippage exceeded 1%");
    }

    function test_LeverageRouter_SucceedsWithReasonableSlippage() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        assertGt(collateral, 0, "Should have collateral");
    }

    function test_BullLeverageRouter_SlippageProtectionLimitsLoss() public {
        uint256 principal = 15_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        (,, uint256 expectedBull,) = bullLeverageRouter.previewOpenLeverage(principal, leverage);

        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bullMarketParams));
        (,, uint128 actualCollateral) = IMorpho(MORPHO).position(marketId, alice);

        uint256 minAcceptable = (expectedBull * 98) / 100;
        assertGe(actualCollateral, minAcceptable, "Slippage exceeded tolerance");
    }

    function test_CloseLeverage_SlippageProtectionOnExit() public {
        uint256 principal = 5000e6;
        uint256 leverage = 2e18;

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares;

        leverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
        assertEq(collateralAfter, 0, "Collateral should be 0");
        assertEq(borrowSharesAfter, 0, "Debt should be 0");
        assertLt(totalCost, (principal * 5) / 100, "Round-trip cost too high");
    }

    function test_ZapMint_RevertsOnExpiredDeadline() public {
        uint256 userAmount = 1000e6;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), userAmount);

        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(ZapRouter.ZapRouter__Expired.selector);
        zapRouter.zapMint(userAmount, 0, 100, expiredDeadline);
        vm.stopPrank();
    }

    function test_LeverageRouter_RevertsOnExpiredDeadline() public {
        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), 1000e6);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__Expired.selector);
        leverageRouter.openLeverage(1000e6, 2e18, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_ZapMint_RevertsOnExcessiveSlippage() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), 1000e6);

        vm.expectRevert(ZapRouter.ZapRouter__SlippageExceedsMax.selector);
        zapRouter.zapMint(1000e6, 0, 200, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_LeverageRouter_RevertsOnExcessiveSlippage() public {
        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), 1000e6);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SlippageExceedsMax.selector);
        leverageRouter.openLeverage(1000e6, 2e18, 200, block.timestamp + 1 hours);
        vm.stopPrank();
    }
}
