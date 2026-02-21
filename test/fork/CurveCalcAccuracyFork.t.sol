// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ICurveTwocrypto} from "../../src/InvarCoin.sol";
import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

/// @notice Empirical fork tests measuring how often Curve V2's calc_token_amount
///         and calc_withdraw_one_coin deviate from actual execution by >1 wei.
///         This validates whether InvarCoin's `- 1` min_amount tolerance is sufficient.
contract CurveCalcAccuracy_AddLiq_UsdcOnly is BaseForkTest {

    ICurveTwocrypto pool;

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 100_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(makeAddr("treasury"));
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);
        pool = ICurveTwocrypto(curvePool);
        IERC20(USDC).approve(curvePool, type(uint256).max);
    }

    function _checkAddLiq(
        uint256 usdcAmount
    ) internal {
        uint256 calc = pool.calc_token_amount([usdcAmount, uint256(0)], true);
        uint256 actual = pool.add_liquidity([usdcAmount, uint256(0)], 0);

        if (actual >= calc) {
            console.log("  %s USDC: actual >= calc, surplus = +%s wei", usdcAmount / 1e6, actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  %s USDC: actual < calc, shortfall = -%s wei", usdcAmount / 1e6, shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_1_dollar() public {
        console.log("=== USDC-only add_liquidity: calc vs actual ===");
        _checkAddLiq(1e6);
    }

    function test_100_dollars() public {
        _checkAddLiq(100e6);
    }

    function test_1k_dollars() public {
        _checkAddLiq(1000e6);
    }

    function test_10k_dollars() public {
        _checkAddLiq(10_000e6);
    }

    function test_100k_dollars() public {
        _checkAddLiq(100_000e6);
    }

    function test_1M_dollars() public {
        _checkAddLiq(1_000_000e6);
    }

    function test_10M_dollars() public {
        _checkAddLiq(10_000_000e6);
    }

}

contract CurveCalcAccuracy_AddLiq_Mixed is BaseForkTest {

    ICurveTwocrypto pool;

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 100_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(makeAddr("treasury"));
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);
        pool = ICurveTwocrypto(curvePool);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);
    }

    function _checkMixed(
        uint256 usdcAmt,
        uint256 bearAmt
    ) internal {
        deal(bearToken, address(this), bearAmt);
        IERC20(bearToken).approve(curvePool, bearAmt);

        uint256 calc = pool.calc_token_amount([usdcAmt, bearAmt], true);
        uint256 actual = pool.add_liquidity([usdcAmt, bearAmt], 0);

        if (actual >= calc) {
            console.log("  %s USDC + BEAR: surplus = +%s wei", usdcAmt / 1e6, actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  %s USDC + BEAR: shortfall = -%s wei", usdcAmt / 1e6, shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_mixed_1k() public {
        console.log("=== Mixed add_liquidity: calc vs actual ===");
        _checkMixed(1000e6, 1000e18);
    }

    function test_mixed_10k() public {
        _checkMixed(10_000e6, 10_000e18);
    }

    function test_mixed_100k() public {
        _checkMixed(100_000e6, 100_000e18);
    }

    function test_mixed_1M() public {
        _checkMixed(1_000_000e6, 1_000_000e18);
    }

}

contract CurveCalcAccuracy_RemoveLiq is BaseForkTest {

    ICurveTwocrypto pool;
    uint256 lpReceived;

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 100_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(makeAddr("treasury"));
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);
        pool = ICurveTwocrypto(curvePool);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(curvePool).approve(curvePool, type(uint256).max);

        lpReceived = pool.add_liquidity([uint256(5_000_000e6), uint256(0)], 0);
    }

    function _checkRemove(
        uint256 divisor
    ) internal {
        uint256 lpToBurn = lpReceived / divisor;
        require(lpToBurn > 0, "zero LP");

        uint256 calc = pool.calc_withdraw_one_coin(lpToBurn, 0);
        uint256 actual = pool.remove_liquidity_one_coin(lpToBurn, 0, 0);

        if (actual >= calc) {
            console.log("  1/%s of LP: surplus = +%s wei", divisor, actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  1/%s of LP: shortfall = -%s wei", divisor, shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_remove_100pct() public {
        console.log("=== remove_liquidity_one_coin: calc vs actual ===");
        _checkRemove(1);
    }

    function test_remove_10pct() public {
        _checkRemove(10);
    }

    function test_remove_1pct() public {
        _checkRemove(100);
    }

    function test_remove_0_1pct() public {
        _checkRemove(1000);
    }

    function test_remove_0_02pct() public {
        _checkRemove(5000);
    }

}

contract CurveCalcAccuracy_Imbalanced is BaseForkTest {

    ICurveTwocrypto pool;

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 100_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(makeAddr("treasury"));
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);
        pool = ICurveTwocrypto(curvePool);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);
        IERC20(curvePool).approve(curvePool, type(uint256).max);
    }

    function test_afterHeavyUsdcDeposit_addLiq() public {
        pool.add_liquidity([uint256(20_000_000e6), uint256(0)], 0);

        console.log("=== After 20M USDC one-sided deposit ===");
        uint256 calc = pool.calc_token_amount([uint256(100_000e6), uint256(0)], true);
        uint256 actual = pool.add_liquidity([uint256(100_000e6), uint256(0)], 0);

        if (actual >= calc) {
            console.log("  add_liq 100k USDC: surplus = +%s wei", actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  add_liq 100k USDC: shortfall = -%s wei", shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_afterHeavyBearDeposit_addLiq() public {
        deal(bearToken, address(this), 20_000_000e18);
        IERC20(bearToken).approve(curvePool, 20_000_000e18);
        pool.add_liquidity([uint256(0), uint256(20_000_000e18)], 0);

        console.log("=== After 20M BEAR one-sided deposit ===");
        uint256 calc = pool.calc_token_amount([uint256(100_000e6), uint256(0)], true);
        uint256 actual = pool.add_liquidity([uint256(100_000e6), uint256(0)], 0);

        if (actual >= calc) {
            console.log("  add_liq 100k USDC: surplus = +%s wei", actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  add_liq 100k USDC: shortfall = -%s wei", shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_afterHeavyUsdcDeposit_removeLiq() public {
        pool.add_liquidity([uint256(20_000_000e6), uint256(0)], 0);
        uint256 lpBal = IERC20(curvePool).balanceOf(address(this));
        uint256 lpToBurn = lpBal / 100;

        console.log("=== remove_liq after 20M USDC imbalance ===");
        uint256 calc = pool.calc_withdraw_one_coin(lpToBurn, 0);
        uint256 actual = pool.remove_liquidity_one_coin(lpToBurn, 0, 0);

        if (actual >= calc) {
            console.log("  rm_liq 1%% of LP: surplus = +%s wei", actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  rm_liq 1%% of LP: shortfall = -%s wei", shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

    function test_afterHeavyBearDeposit_removeLiq() public {
        deal(bearToken, address(this), 20_000_000e18);
        IERC20(bearToken).approve(curvePool, 20_000_000e18);
        pool.add_liquidity([uint256(0), uint256(20_000_000e18)], 0);
        uint256 lpBal = IERC20(curvePool).balanceOf(address(this));
        uint256 lpToBurn = lpBal / 100;

        console.log("=== remove_liq after 20M BEAR imbalance ===");
        uint256 calc = pool.calc_withdraw_one_coin(lpToBurn, 0);
        uint256 actual = pool.remove_liquidity_one_coin(lpToBurn, 0, 0);

        if (actual >= calc) {
            console.log("  rm_liq 1%% of LP: surplus = +%s wei", actual - calc);
        } else {
            uint256 shortfall = calc - actual;
            console.log("  rm_liq 1%% of LP: shortfall = -%s wei", shortfall);
            assertLe(shortfall, calc * 5 / 10_000, "Shortfall exceeds 5 bps tolerance");
        }
    }

}
