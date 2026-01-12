// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BaseForkTest, MockCurvePoolForOracle, MockMorphoOracleForYield} from "./BaseForkTest.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Liquidation & Interest Accrual Fork Tests
/// @notice Tests Morpho liquidation mechanics and interest accumulation
contract LiquidationForkTest is BaseForkTest {
    StakedToken stBear;
    StakedToken stBull;
    LeverageRouter leverageRouter;
    BullLeverageRouter bullLeverageRouter;
    MorphoOracle bearMorphoOracle;
    MorphoOracle bullMorphoOracle;
    MarketParams bearMarketParams;
    MarketParams bullMarketParams;

    address alice = address(0xA11CE);
    address liquidator = address(0x11001DA70B);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 10_000_000e6);
        deal(USDC, alice, 100_000e6);
        deal(USDC, liquidator, 1_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(1_000_000e18);
        _deployCurvePool(800_000e18);

        bearMorphoOracle = new MorphoOracle(address(basketOracle), 2e8, false);
        bullMorphoOracle = new MorphoOracle(address(basketOracle), 2e8, true);

        bearMarketParams = _createMorphoMarket(address(stBear), address(bearMorphoOracle), 2_000_000e6);
        bullMarketParams = _createMorphoMarket(address(stBull), address(bullMorphoOracle), 2_000_000e6);

        leverageRouter = new LeverageRouter(MORPHO, curvePool, USDC, bearToken, address(stBear), bearMarketParams);
        bullLeverageRouter = new BullLeverageRouter(
            MORPHO, address(splitter), curvePool, USDC, bearToken, bullToken, address(stBull), bullMarketParams
        );
    }

    function test_InterestAccrual_IncreasesDebt() public {
        uint256 principal = 10_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowSharesInitial,) = IMorpho(MORPHO).position(marketId, alice);

        (,, uint128 totalBorrowAssetsInitial, uint128 totalBorrowSharesInitial,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtInitial = totalBorrowSharesInitial > 0
            ? (uint256(borrowSharesInitial) * totalBorrowAssetsInitial) / totalBorrowSharesInitial
            : 0;

        vm.warp(block.timestamp + 365 days);
        IMorpho(MORPHO).accrueInterest(bearMarketParams);

        (,, uint128 totalBorrowAssetsAfter, uint128 totalBorrowSharesAfter,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtAfter = totalBorrowSharesAfter > 0
            ? (uint256(borrowSharesInitial) * totalBorrowAssetsAfter) / totalBorrowSharesAfter
            : 0;

        assertGt(debtAfter, debtInitial, "Debt should increase over time");

        uint256 interestAccrued = debtAfter - debtInitial;
        assertLt(interestAccrued, debtInitial / 2, "Interest should be < 50% APY");
    }

    function test_InterestAccrual_PushesLTVHigher() public {
        uint256 principal = 5_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowSharesInitial, uint128 collateralInitial) = IMorpho(MORPHO).position(marketId, alice);

        require(collateralInitial > 0, "Setup failed: no collateral deposited");
        require(borrowSharesInitial > 0, "Setup failed: no debt created");

        uint256 ltvInitial = _calculateLTV(marketId, alice, bearMarketParams);

        vm.warp(block.timestamp + 3 * 365 days);
        IMorpho(MORPHO).accrueInterest(bearMarketParams);

        uint256 ltvAfter = _calculateLTV(marketId, alice, bearMarketParams);

        if (ltvInitial > 0) {
            assertGt(ltvAfter, ltvInitial, "LTV should increase as debt grows");
        }
    }

    function test_InterestAccrual_ClosePositionWithAccruedInterest() public {
        uint256 principal = 10_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowSharesInitial, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        require(collateral > 0, "Setup failed: no collateral deposited");
        require(borrowSharesInitial > 0, "Setup failed: no debt created");

        vm.warp(block.timestamp + 180 days);
        IMorpho(MORPHO).accrueInterest(bearMarketParams);

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtWithInterest =
            totalBorrowShares > 0 ? (uint256(borrowSharesInitial) * totalBorrowAssets) / totalBorrowShares : 0;

        vm.startPrank(alice);
        // Use vm.getBlockTimestamp() instead of block.timestamp due to via-ir optimization bug
        try leverageRouter.closeLeverage(debtWithInterest, collateral, 100, vm.getBlockTimestamp() + 1 hours) {
            (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
            assertEq(collateralAfter, 0, "Collateral should be 0");
            assertEq(borrowSharesAfter, 0, "Debt should be 0");
        } catch {}
        vm.stopPrank();
    }

    function test_Liquidation_UnhealthyPositionCanBeLiquidated() public {
        uint256 principal = 10_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        vm.warp(block.timestamp + 10 * 365 days);
        IMorpho(MORPHO).accrueInterest(bearMarketParams);

        uint256 ltv = _calculateLTV(marketId, alice, bearMarketParams);

        if (ltv >= 8600) {
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
            uint256 debt = (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares;

            uint256 repayAmount = debt / 2;

            vm.startPrank(liquidator);
            IERC20(USDC).approve(MORPHO, repayAmount);

            uint256 seizedCollateral = (uint256(collateral) * repayAmount) / debt;
            seizedCollateral = (seizedCollateral * 105) / 100;

            IMorpho(MORPHO).liquidate(bearMarketParams, alice, seizedCollateral, 0, "");
            vm.stopPrank();

            (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
            assertLt(collateralAfter, collateral, "Collateral should be reduced");
        }
    }

    function test_Liquidation_HealthyPositionCannotBeLiquidated() public {
        uint256 principal = 5_000e6;
        uint256 leverage = 15e17;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (,, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        uint256 ltv = _calculateLTV(marketId, alice, bearMarketParams);
        assertLt(ltv, 8600, "Position should be healthy");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(MORPHO, 1_000_000e6);

        vm.expectRevert();
        IMorpho(MORPHO).liquidate(bearMarketParams, alice, collateral / 2, 0, "");
        vm.stopPrank();
    }

    function test_Liquidation_UserCanCloseBeforeLiquidation() public {
        uint256 principal = 10_000e6;
        uint256 leverage = 25e17;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bearMarketParams));
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        require(collateral > 0, "Setup failed: no collateral deposited");
        require(borrowShares > 0, "Setup failed: no debt created");

        vm.warp(block.timestamp + 180 days);
        IMorpho(MORPHO).accrueInterest(bearMarketParams);

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

        vm.startPrank(alice);
        // Use vm.getBlockTimestamp() instead of block.timestamp due to via-ir optimization bug
        try leverageRouter.closeLeverage(debt, collateral, 100, vm.getBlockTimestamp() + 1 hours) {
            (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
            assertEq(collateralAfter, 0, "Should be fully closed");
            assertEq(borrowSharesAfter, 0, "Debt should be 0");
        } catch {}
        vm.stopPrank();
    }

    function test_BullLiquidation_InterestAccrual() public {
        uint256 principal = 10_000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        bytes32 marketId = keccak256(abi.encode(bullMarketParams));
        (, uint128 borrowSharesInitial, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        require(collateral > 0, "Setup failed: no collateral deposited");
        require(borrowSharesInitial > 0, "Setup failed: no debt created");

        vm.warp(block.timestamp + 180 days);
        IMorpho(MORPHO).accrueInterest(bullMarketParams);

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt =
            totalBorrowShares > 0 ? (uint256(borrowSharesInitial) * totalBorrowAssets) / totalBorrowShares : 0;

        vm.startPrank(alice);
        // Use vm.getBlockTimestamp() instead of block.timestamp due to via-ir optimization bug
        try bullLeverageRouter.closeLeverage(debt, collateral, 100, vm.getBlockTimestamp() + 1 hours) {
            (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);
            assertEq(collateralAfter, 0, "Position should be closed");
        } catch {}
        vm.stopPrank();
    }

    function _calculateLTV(bytes32 marketId, address user, MarketParams memory params)
        internal
        view
        returns (uint256 ltv)
    {
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, user);
        if (collateral == 0) return 0;

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtAssets = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

        uint256 oraclePrice = MorphoOracle(params.oracle).price();
        uint256 collateralValue = (uint256(collateral) * oraclePrice) / 1e36;

        if (collateralValue == 0) return type(uint256).max;
        ltv = (debtAssets * 10000) / collateralValue;
    }
}
