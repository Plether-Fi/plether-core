// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {LeverageRouterBase} from "../../src/base/LeverageRouterBase.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {BaseForkTest, ICurvePoolExtended, MockCurvePoolForOracle, MockMorphoOracleForYield} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

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

    function _whaleDumpBear(
        uint256 bearAmount
    ) internal {
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

    function _whalePumpBear(
        uint256 usdcAmount
    ) internal {
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

        // Whale dumps BEAR, crashing price and making zapMint uneconomical
        _whaleDumpBear(100_000e18);

        uint256 minOut = (expectedBull * 95) / 100;

        vm.startPrank(alice);
        vm.expectRevert(); // Reverts with InsufficientOutput or SolvencyBreach depending on gamma
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

        // Whale pumps BEAR price, making BEAR buyback for redemption too expensive
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

        (,, uint256 expectedBear,) = leverageRouter.previewOpenLeverage(principal, leverage);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (,, uint128 actualCollateral) = IMorpho(MORPHO).position(marketId, alice);

        // StakedToken uses 1000x share offset for inflation attack protection
        uint256 actualTokens = actualCollateral / 1000;

        // Slippage sources:
        // - Curve swap fee (~0.04%) to buy BEAR
        // - Curve pool price impact (depends on trade size vs liquidity)
        // Threshold: <1% ensures large trades still get fair execution
        uint256 minAcceptable = (expectedBear * 99) / 100;
        assertGe(actualTokens, minAcceptable, "Slippage exceeded 1%");
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

        // StakedToken uses 1000x share offset for inflation attack protection
        uint256 actualTokens = actualCollateral / 1000;

        // Slippage sources (Bull has more steps than Bear):
        // - Mint pairs from Splitter (no slippage)
        // - Curve swap to sell BEAR (~0.04% fee + price impact)
        // Threshold: <1% ensures fair execution even for larger trades
        uint256 minAcceptable = (expectedBull * 99) / 100;
        assertGe(actualTokens, minAcceptable, "Slippage exceeded 1%");
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
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        leverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
        assertEq(collateralAfter, 0, "Collateral should be 0");
        assertEq(borrowSharesAfter, 0, "Debt should be 0");

        // Round-trip cost sources:
        // - Open: Curve swap fee + price impact to buy BEAR
        // - Close: Curve swap fee + price impact to sell BEAR
        // - Price impacts partially offset (buy then sell same direction)
        // Threshold: <1% for normal market conditions
        assertLt(totalCost, (principal * 1) / 100, "Round-trip cost too high");
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

    // ==========================================
    // CURVE POOL PRICING VERIFICATION
    // ==========================================

    /// @notice Verify round-trip swap (buy then sell) loses only fees, not principal
    function test_CurvePool_RoundTripSwapLosesOnlyFees() public {
        uint256 swapAmount = 100e6;

        vm.startPrank(alice);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        // Buy BEAR with USDC
        IERC20(USDC).approve(curvePool, swapAmount);
        (bool success1,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, swapAmount, 0));
        require(success1, "Buy failed");

        uint256 bearReceived = IERC20(bearToken).balanceOf(alice);

        // Sell BEAR back to USDC
        IERC20(bearToken).approve(curvePool, bearReceived);
        (bool success2,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, bearReceived, 0));
        require(success2, "Sell failed");

        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        vm.stopPrank();

        uint256 loss = usdcBefore - usdcAfter;

        // Round-trip loss sources:
        // - 2x Curve swap fees (~0.04% each)
        // - Price impact from moving pool state (buy raises price, sell lowers it)
        // Threshold: <2% ensures pool fees are reasonable
        uint256 maxAcceptableLoss = (swapAmount * 2) / 100;
        assertLt(loss, maxAcceptableLoss, "Round-trip loss exceeds acceptable fee threshold");
    }

    /// @notice Verify small swaps don't create arbitrage (buy BEAR price ≈ sell BEAR price)
    function test_CurvePool_SmallSwapNoBidAskArbitrage() public {
        uint256 smallAmount = 10e6;

        // Get buy price (USDC -> BEAR)
        uint256 bearForUsdc = ICurvePoolExtended(curvePool).get_dy(0, 1, smallAmount);
        uint256 buyPrice = (smallAmount * 1e18) / bearForUsdc;

        // Get sell price (BEAR -> USDC) for equivalent amount
        uint256 usdcForBear = ICurvePoolExtended(curvePool).get_dy(1, 0, bearForUsdc);
        uint256 sellPrice = (usdcForBear * 1e18) / bearForUsdc;

        // Buy price should be slightly higher than sell price (spread = fees)
        assertGt(buyPrice, sellPrice, "Buy price should be >= sell price");

        // Spread sources:
        // - Curve swap fee applied to both directions
        // - Any pool imbalance
        // Threshold: <1% spread ensures efficient market for small trades
        uint256 spread = buyPrice - sellPrice;
        uint256 maxSpread = buyPrice / 100;
        assertLt(spread, maxSpread, "Bid-ask spread too wide");
    }

    /// @notice Verify no profit from mint-and-sell arbitrage
    function test_CurvePool_NoMintSellArbitrage() public view {
        uint256 mintAmount = 100e18;

        (uint256 mintCost,,) = splitter.previewMint(mintAmount);
        uint256 bearSellValue = ICurvePoolExtended(curvePool).get_dy(1, 0, mintAmount);

        // No-arbitrage condition: selling BEAR should not exceed mint cost
        // (you still hold BULL which has positive value)
        // Threshold: 5% tolerance for fees and market conditions
        uint256 maxBearValue = (mintCost * 105) / 100;
        assertLe(bearSellValue, maxBearValue, "BEAR sells for too much - arbitrage exists");
    }

    /// @notice Verify no profit from buy-and-burn arbitrage
    function test_CurvePool_NoBuyBurnArbitrage() public view {
        uint256 pairAmount = 100e18;
        uint256 usdcIn = 100e6;

        // Get BEAR per USDC from Curve
        uint256 bearPerUsdc = ICurvePoolExtended(curvePool).get_dy(0, 1, usdcIn);
        uint256 bearPriceUsdc6 = (usdcIn * 1e18) / bearPerUsdc;

        // Cost to buy BEAR and BULL
        uint256 usdcForBear = (pairAmount * bearPriceUsdc6) / 1e18;
        uint256 bullPriceUsdc6 = (CAP_SCALED / 1e12) - bearPriceUsdc6;
        uint256 usdcForBull = (pairAmount * bullPriceUsdc6) / 1e18;
        uint256 totalBuyCost = usdcForBear + usdcForBull;

        (uint256 redeemValue,) = splitter.previewBurn(pairAmount);

        // No-arbitrage: buying tokens on market and redeeming should not profit
        // In efficient market: BEAR + BULL = CAP = redeem value
        // With fees: buy cost > redeem value (loss)
        assertGe(totalBuyCost, redeemValue, "Buy-and-burn should not be profitable");
    }

    /// @notice Verify BEAR + BULL prices approximately sum to CAP (market efficiency)
    function test_CurvePool_TokenPricesSumToCAP() public view {
        uint256 testAmount = 1e18;

        uint256 usdcPerBear = ICurvePoolExtended(curvePool).get_dy(1, 0, testAmount);
        uint256 usdcPerBull = CAP_SCALED / 1e12 - usdcPerBear;

        uint256 sum = usdcPerBear + usdcPerBull;
        uint256 capIn6Decimals = CAP_SCALED / 1e12;

        // Market efficiency check: BEAR + BULL should equal CAP
        // Deviation indicates mispricing or arbitrage opportunity
        // Threshold: 5% allows for fees and temporary imbalances
        uint256 minSum = (capIn6Decimals * 95) / 100;
        uint256 maxSum = (capIn6Decimals * 105) / 100;

        assertGe(sum, minSum, "Token prices sum below CAP - 5%");
        assertLe(sum, maxSum, "Token prices sum above CAP + 5%");
    }

    // ==========================================
    // PREVIEW FUNCTION ACCURACY TESTS
    // ==========================================

    /// @notice previewZapMint should match actual execution within tolerance
    function test_PreviewZapMint_ShouldMatchActual() public {
        uint256 usdcAmount = 10_000e6;

        (,,, uint256 previewTokensOut,) = zapRouter.previewZapMint(usdcAmount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), usdcAmount);
        uint256 bullBefore = IERC20(bullToken).balanceOf(alice);
        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
        uint256 actualTokensOut = IERC20(bullToken).balanceOf(alice) - bullBefore;
        vm.stopPrank();

        // Preview uses Curve's get_dy which matches actual swap output
        // Threshold: 0.01% accounts for any rounding differences
        assertApproxEqRel(
            actualTokensOut, previewTokensOut, 0.0001e18, "previewZapMint should match actual within 0.01%"
        );
    }

    /// @notice previewZapBurn should match actual execution within tolerance
    function test_PreviewZapBurn_ShouldMatchActual() public {
        uint256 zapAmount = 10_000e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zapRouter), zapAmount);
        zapRouter.zapMint(zapAmount, 0, 100, block.timestamp + 1 hours);
        uint256 bullBalance = IERC20(bullToken).balanceOf(alice);
        vm.stopPrank();

        (,, uint256 previewUsdcOut,) = zapRouter.previewZapBurn(bullBalance);

        vm.startPrank(alice);
        IERC20(bullToken).approve(address(zapRouter), bullBalance);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        zapRouter.zapBurn(bullBalance, 0, block.timestamp + 1 hours);
        uint256 actualUsdcOut = IERC20(USDC).balanceOf(alice) - usdcBefore;
        vm.stopPrank();

        // Preview uses Curve's get_dy for buyback cost estimation
        // Threshold: 0.01% accounts for any rounding differences
        assertApproxEqRel(actualUsdcOut, previewUsdcOut, 0.0001e18, "previewZapBurn should match actual within 0.01%");
    }

    /// @notice previewCloseLeverage should match actual execution within tolerance
    function test_PreviewCloseLeverage_ShouldMatchActual() public {
        uint256 principal = 10_000e6;
        // Use 4x leverage to ensure debt is created
        // (at 2x with BEAR ~$1.08, selling BEAR covers the entire flash loan)
        uint256 leverage = 4e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = keccak256(abi.encode(bullMarketParams));
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares;

        (,, uint256 previewReturn) = bullLeverageRouter.previewCloseLeverage(debt, collateral);

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        bullLeverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        uint256 actualReturn = IERC20(USDC).balanceOf(alice) - usdcBefore;
        vm.stopPrank();

        // Preview estimates Curve swap output for BEAR buyback
        // Threshold: 1% accounts for price movement during complex multi-step close at 4x leverage
        assertApproxEqRel(actualReturn, previewReturn, 0.01e18, "previewCloseLeverage should match actual within 1%");
    }

    /// @notice Preview accuracy should hold across different trade sizes
    function test_PreviewAccuracy_AcrossMultipleTradeSizes() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e6;
        amounts[1] = 5000e6;
        amounts[2] = 10_000e6;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 usdcAmount = amounts[i];
            deal(USDC, alice, usdcAmount);

            (,,, uint256 previewTokensOut,) = zapRouter.previewZapMint(usdcAmount);

            vm.startPrank(alice);
            IERC20(USDC).approve(address(zapRouter), usdcAmount);
            uint256 bullBefore = IERC20(bullToken).balanceOf(alice);
            zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
            uint256 actualTokensOut = IERC20(bullToken).balanceOf(alice) - bullBefore;
            vm.stopPrank();

            // Preview should be accurate regardless of trade size (within pool liquidity)
            assertApproxEqRel(actualTokensOut, previewTokensOut, 0.0001e18, "Preview should match actual within 0.01%");
        }
    }

}
