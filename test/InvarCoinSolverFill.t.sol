// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {InvarCoin} from "../src/InvarCoin.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract SolverMockToken is ERC20 {

    uint8 private immutable tokenDecimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

}

contract SolverMockOracle is AggregatorV3Interface {

    int256 public answer = 1e8;
    uint256 public updatedAt;

    function setAnswer(
        int256 answer_
    ) external {
        answer = answer_;
    }

    function setUpdatedAt(
        uint256 timestamp
    ) external {
        updatedAt = timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

}

contract SolverMockCurvePool {

    uint256 public lpPrice = 2e18;
    uint256 public virtualPrice = 1e18;
    uint256 public spotDiscountBps;

    function setLpPrice(
        uint256 lpPrice_
    ) external {
        lpPrice = lpPrice_;
    }

    function setVirtualPrice(
        uint256 virtualPrice_
    ) external {
        virtualPrice = virtualPrice_;
    }

    function setSpotDiscountBps(
        uint256 spotDiscountBps_
    ) external {
        spotDiscountBps = spotDiscountBps_;
    }

    function get_virtual_price() external view returns (uint256) {
        return virtualPrice;
    }

    function lp_price() external view returns (uint256) {
        return lpPrice;
    }

    function calc_token_amount(
        uint256[2] calldata amounts,
        bool
    ) external view returns (uint256) {
        uint256 lpAmount = (amounts[0] * 1e30) / lpPrice;
        return (lpAmount * (10_000 - spotDiscountBps)) / 10_000;
    }

}

contract InvarCoinSolverFillTest is Test {

    SolverMockToken usdc;
    SolverMockToken bear;
    SolverMockToken curveLp;
    SolverMockOracle oracle;
    SolverMockCurvePool curvePool;
    InvarCoin invar;

    address alice = address(0xA11CE);
    address solver = address(0x501);

    function setUp() public {
        vm.warp(2 days);
        usdc = new SolverMockToken("USDC", "USDC", 6);
        bear = new SolverMockToken("BEAR", "BEAR", 18);
        curveLp = new SolverMockToken("Curve LP", "crvLP", 18);
        oracle = new SolverMockOracle();
        oracle.setUpdatedAt(block.timestamp);
        curvePool = new SolverMockCurvePool();

        invar = new InvarCoin(
            address(usdc), address(bear), address(curveLp), address(curvePool), address(oracle), address(0), address(0)
        );

        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(invar), type(uint256).max);
        invar.deposit(100_000e6, alice, 0);
        vm.stopPrank();
    }

    function test_SellLpToVault_PaysReserveBidAndRecordsLp() public {
        uint256 lpAmount = 10_000e18;
        uint256 expectedUsdcOut = 19_980e6;
        curveLp.mint(solver, lpAmount);

        assertEq(invar.previewSellLpToVault(lpAmount), expectedUsdcOut);

        vm.startPrank(solver);
        curveLp.approve(address(invar), lpAmount);
        uint256 usdcOut = invar.sellLpToVault(lpAmount, expectedUsdcOut);
        vm.stopPrank();

        assertEq(usdcOut, expectedUsdcOut);
        assertEq(usdc.balanceOf(solver), expectedUsdcOut);
        assertEq(curveLp.balanceOf(address(invar)), lpAmount);
        assertEq(invar.trackedLpBalance(), lpAmount);
        assertEq(invar.curveLpCostVp(), lpAmount);
    }

    function test_SellLpToVault_RevertsWhenFillExceedsExcessBuffer() public {
        uint256 lpAmount = 50_000e18;
        curveLp.mint(solver, lpAmount);

        vm.startPrank(solver);
        curveLp.approve(address(invar), lpAmount);
        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        invar.sellLpToVault(lpAmount, 0);
        vm.stopPrank();
    }

    function test_BuyLpFromVault_RestoresBufferAtReserveAsk() public {
        uint256 lpSoldToVault = 10_000e18;
        curveLp.mint(solver, lpSoldToVault);
        vm.startPrank(solver);
        curveLp.approve(address(invar), lpSoldToVault);
        invar.sellLpToVault(lpSoldToVault, 0);
        vm.stopPrank();

        usdc.burn(address(invar), usdc.balanceOf(address(invar)));

        uint256 lpBoughtFromVault = 100e18;
        uint256 expectedUsdcIn = 200_200_000;
        assertEq(invar.previewBuyLpFromVault(lpBoughtFromVault), expectedUsdcIn);

        usdc.mint(solver, expectedUsdcIn);
        vm.startPrank(solver);
        usdc.approve(address(invar), expectedUsdcIn);
        uint256 usdcIn = invar.buyLpFromVault(lpBoughtFromVault, expectedUsdcIn);
        vm.stopPrank();

        assertEq(usdcIn, expectedUsdcIn);
        assertEq(usdc.balanceOf(address(invar)), expectedUsdcIn);
        assertEq(curveLp.balanceOf(solver), lpBoughtFromVault);
        assertEq(invar.trackedLpBalance(), lpSoldToVault - lpBoughtFromVault);
    }

    function test_BuyLpFromVault_RevertsBelowReserveAsk() public {
        uint256 lpSoldToVault = 10_000e18;
        curveLp.mint(solver, lpSoldToVault);
        vm.startPrank(solver);
        curveLp.approve(address(invar), lpSoldToVault);
        invar.sellLpToVault(lpSoldToVault, 0);
        vm.stopPrank();

        usdc.burn(address(invar), usdc.balanceOf(address(invar)));

        uint256 lpBoughtFromVault = 100e18;
        uint256 expectedUsdcIn = invar.previewBuyLpFromVault(lpBoughtFromVault);
        usdc.mint(solver, expectedUsdcIn);

        vm.startPrank(solver);
        usdc.approve(address(invar), expectedUsdcIn);
        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        invar.buyLpFromVault(lpBoughtFromVault, expectedUsdcIn - 1);
        vm.stopPrank();
    }

    function test_SolverPricing_OracleBelowCurveUsesOracleForBidAndCurveForAsk() public {
        oracle.setAnswer(81_000_000); // BEAR oracle price = 0.81, oracle-implied LP price = 1.8 USDC.

        uint256 lpAmount = 100e18;

        assertEq(invar.previewSellLpToVault(lpAmount), 179_820_000);
        assertEq(invar.previewBuyLpFromVault(lpAmount), 200_200_000);
    }

    function test_SolverPricing_OracleAboveCurveUsesCurveForBidAndOracleForAsk() public {
        oracle.setAnswer(144_000_000); // BEAR oracle price = 1.44, oracle-implied LP price = 2.4 USDC.

        uint256 lpAmount = 100e18;

        assertEq(invar.previewSellLpToVault(lpAmount), 199_800_000);
        assertEq(invar.previewBuyLpFromVault(lpAmount), 240_240_000);
    }

    function test_SolverPricing_RevertsOnStaleOracle() public {
        oracle.setUpdatedAt(block.timestamp - invar.ORACLE_TIMEOUT() - 1);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        invar.previewSellLpToVault(100e18);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        invar.previewBuyLpFromVault(100e18);
    }

    function test_SolverPricing_IgnoresManipulatedSpotWithUnchangedEma() public {
        curvePool.setSpotDiscountBps(500);

        assertEq(invar.getSpotDeviation(), 500);

        uint256 lpAmount = 100e18;
        assertEq(invar.previewSellLpToVault(lpAmount), 199_800_000);
        assertEq(invar.previewBuyLpFromVault(lpAmount), 200_200_000);
    }

}
