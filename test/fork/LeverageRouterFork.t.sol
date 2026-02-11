// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {BaseForkTest, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title LeverageRouter Fork Tests
/// @notice Tests LeverageRouter with real Curve pool + real Morpho
contract LeverageRouterForkTest is BaseForkTest {

    StakedToken stBear;
    LeverageRouter leverageRouter;
    MorphoOracle morphoOracle;
    MarketParams marketParams;

    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 3_000_000e6);
        deal(USDC, alice, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(400_000e18);

        morphoOracle = new MorphoOracle(address(basketOracle), 2e8, false);
        marketParams = _createMorphoMarket(address(stBear), address(morphoOracle), 1_000_000e6);
        leverageRouter = new LeverageRouter(MORPHO, curvePool, USDC, bearToken, address(stBear), marketParams);
    }

    function test_OpenLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        assertGt(collateral, 0, "Should have collateral");
        assertGt(borrowShares, 0, "Should have debt");
    }

    function test_CloseLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;
        bytes32 marketId = _getMarketId(marketParams);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        leverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        uint256 usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        vm.stopPrank();

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
        assertEq(collateralAfter, 0, "Collateral should be cleared");

        // Cost sources for close:
        // - Curve swap fee (~0.04%) to sell BEAR for USDC
        // - Curve pool price impact (~0.05% for this size)
        // Threshold: <1% allows for larger positions or worse pool conditions
        assertGt(usdcReturned, (principal * 99) / 100, "Should return >99% of principal");
    }

    function test_LeverageRoundTrip_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;
        bytes32 marketId = _getMarketId(marketParams);
        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        leverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        // Round-trip cost sources:
        // - 2x Curve swap fees (~0.04% each = ~0.08% total)
        // - 2x Curve pool price impact (minimal for BEAR leverage, swaps partially offset)
        // Threshold: <1% allows for larger positions or worse pool conditions
        assertLt(totalCost, (principal * 1) / 100, "Round-trip cost should be <1%");
    }

    function _getMarketId(
        MarketParams memory params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

}

/// @title BullLeverageRouter Fork Tests
/// @notice Tests BullLeverageRouter with real Curve pool + real Morpho
contract BullLeverageRouterForkTest is BaseForkTest {

    StakedToken stBull;
    BullLeverageRouter bullLeverageRouter;
    MorphoOracle morphoOracle;
    MarketParams marketParams;

    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 3_000_000e6);
        deal(USDC, alice, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(400_000e18);

        morphoOracle = new MorphoOracle(address(basketOracle), 2e8, true);
        marketParams = _createMorphoMarket(address(stBull), address(morphoOracle), 1_000_000e6);
        bullLeverageRouter = new BullLeverageRouter(
            MORPHO, address(splitter), curvePool, USDC, bearToken, bullToken, address(stBull), marketParams, address(0)
        );
    }

    function test_OpenLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        assertGt(collateral, 0, "Should have collateral");
    }

    function test_CloseLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        bullLeverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
        assertEq(collateralAfter, 0, "Collateral should be cleared");

        assertGt(usdcReturned, (principal * 90) / 100, "Should return >90% of principal");
    }

    function test_LeverageRoundTrip_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        bullLeverageRouter.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        assertLt(totalCost, (principal * 10) / 100, "Bull round-trip cost should be <10%");
    }

    function test_PreviewCloseLeverage_WithOffset() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;
        vm.stopPrank();

        (uint256 expectedUSDC,,) = bullLeverageRouter.previewCloseLeverage(debt, collateral);

        assertGt(expectedUSDC, 500e6, "Expected USDC should be > 500 (sanity check)");
    }

    function _getMarketId(
        MarketParams memory params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

}
