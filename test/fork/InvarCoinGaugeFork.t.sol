// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ICurveGauge, ICurveTwocrypto, InvarCoin} from "../../src/InvarCoin.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BaseForkTest, ICurveCryptoFactory, ICurvePoolExtended} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvarCoinGaugeForkTest is BaseForkTest {

    InvarCoin ic;
    StakedToken sInvar;
    ICurveGauge gauge;

    address treasury;
    address alice;
    address bob;
    address keeper;

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");

        deal(USDC, address(this), 40_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);

        ic = new InvarCoin(USDC, bearToken, curvePool, curvePool, address(basketOracle), address(0), address(0));

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        address gaugeAddr = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY).deploy_gauge(curvePool);
        gauge = ICurveGauge(gaugeAddr);

        deal(USDC, alice, 2_000_000e6);
        deal(USDC, bob, 500_000e6);

        vm.prank(alice);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).approve(address(ic), type(uint256).max);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _warpAndRefreshOracle(
        uint256 duration
    ) internal {
        vm.warp(block.timestamp + duration);
        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), clPrice, uint256(0), block.timestamp, uint80(1))
        );
    }

    function _depositAs(
        address user,
        uint256 usdcAmount
    ) internal returns (uint256 shares) {
        vm.prank(user);
        shares = ic.deposit(usdcAmount, user, 0);
    }

    function _generateCurveFees(
        uint256 swapAmount,
        uint256 rounds
    ) internal {
        deal(USDC, address(this), swapAmount * 2);
        deal(bearToken, address(this), swapAmount * 1e12 * 2);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);

        for (uint256 i = 0; i < rounds; i++) {
            (bool s1,) = curvePool.call(
                abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, swapAmount, 0)
            );
            require(s1, "swap USDC->BEAR failed");
            uint256 bearBal = IERC20(bearToken).balanceOf(address(this));
            (bool s2,) = curvePool.call(
                abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, bearBal / 2, 0)
            );
            require(s2, "swap BEAR->USDC failed");
        }
    }

    function _proposeAndFinalizeGauge() internal {
        ic.proposeGauge(address(gauge));
        _warpAndRefreshOracle(7 days);
        ic.finalizeGauge();
    }

    function _setupWithLpInGauge(
        uint256 depositAmount
    ) internal returns (uint256 shares) {
        shares = _depositAs(alice, depositAmount);
        ic.deployToCurve(0);
        _proposeAndFinalizeGauge();
        ic.stakeToGauge(0);
    }

    // ==========================================
    // GAUGE LIFECYCLE
    // ==========================================

    function test_proposeAndFinalizeGauge() public {
        ic.proposeGauge(address(gauge));

        assertEq(ic.pendingGauge(), address(gauge));
        assertEq(ic.gaugeActivationTime(), block.timestamp + 7 days);

        vm.expectRevert(InvarCoin.InvarCoin__GaugeTimelockActive.selector);
        ic.finalizeGauge();

        _warpAndRefreshOracle(7 days);
        ic.finalizeGauge();

        assertEq(address(ic.curveGauge()), address(gauge));
        assertEq(ic.pendingGauge(), address(0));
        assertEq(ic.gaugeActivationTime(), 0);
    }

    function test_stakeToGauge_realGauge() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);
        _proposeAndFinalizeGauge();

        uint256 lpBal = IERC20(curvePool).balanceOf(address(ic));
        assertGt(lpBal, 0, "Should have LP before staking");

        ic.stakeToGauge(0);

        assertEq(IERC20(curvePool).balanceOf(address(ic)), 0, "All local LP should be staked");
        assertEq(gauge.balanceOf(address(ic)), lpBal, "Gauge balance should match staked amount");
    }

    function test_unstakeFromGauge_realGauge() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);
        _proposeAndFinalizeGauge();

        uint256 lpBal = IERC20(curvePool).balanceOf(address(ic));
        ic.stakeToGauge(0);

        ic.unstakeFromGauge(0);

        assertEq(IERC20(curvePool).balanceOf(address(ic)), lpBal, "LP should return to InvarCoin");
        assertEq(gauge.balanceOf(address(ic)), 0, "Gauge balance should be zero");
    }

    function test_stakeAll_unstakeAll() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);
        _proposeAndFinalizeGauge();

        uint256 lpBal = IERC20(curvePool).balanceOf(address(ic));
        ic.stakeToGauge(0);
        assertEq(gauge.balanceOf(address(ic)), lpBal);

        ic.unstakeFromGauge(0);
        assertEq(IERC20(curvePool).balanceOf(address(ic)), lpBal);
        assertEq(gauge.balanceOf(address(ic)), 0);
    }

    // ==========================================
    // JIT UNSTAKE ON WITHDRAWAL PATHS
    // ==========================================

    function test_withdraw_jitUnstakeFromGauge() public {
        uint256 shares = _setupWithLpInGauge(1_000_000e6);
        assertEq(IERC20(curvePool).balanceOf(address(ic)), 0, "All LP in gauge");
        assertGt(gauge.balanceOf(address(ic)), 0, "Gauge holds LP");

        uint256 withdrawShares = shares / 3;
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(withdrawShares, alice, 0);

        assertGt(usdcOut, 0, "Should receive USDC");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcOut, "Transfer matches return");
        assertGt(usdcOut, 250_000e6, "Should recover substantial USDC via JIT unstake");
    }

    function test_lpWithdraw_jitUnstakeFromGauge() public {
        uint256 shares = _setupWithLpInGauge(1_000_000e6);
        assertEq(IERC20(curvePool).balanceOf(address(ic)), 0, "All LP in gauge");

        uint256 withdrawShares = shares / 2;
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceBearBefore = IERC20(bearToken).balanceOf(alice);

        vm.prank(alice);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(withdrawShares, 0, 0);

        assertGt(usdcReturned, 0, "Should receive USDC");
        assertGt(bearReturned, 0, "Should receive BEAR");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcReturned);
        assertEq(IERC20(bearToken).balanceOf(alice) - aliceBearBefore, bearReturned);
    }

    function test_replenishBuffer_jitUnstakeFromGauge() public {
        _setupWithLpInGauge(1_000_000e6);

        // Flush pending Curve admin fees
        IERC20(curvePool).approve(curvePool, 1e18);
        ICurveTwocrypto(curvePool).remove_liquidity_one_coin(1e18, 0, 0);

        deal(USDC, address(ic), IERC20(USDC).balanceOf(address(ic)) / 10);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(ic));
        assertEq(IERC20(curvePool).balanceOf(address(ic)), 0, "All LP in gauge before replenish");

        ic.replenishBuffer(0);

        assertGt(IERC20(USDC).balanceOf(address(ic)), usdcBefore, "Buffer should increase");
    }

    function test_emergencyWithdraw_jitUnstakeFromGauge() public {
        _setupWithLpInGauge(1_000_000e6);

        uint256 stakedLp = gauge.balanceOf(address(ic));
        assertGt(stakedLp, 0, "LP should be in gauge");
        assertEq(IERC20(curvePool).balanceOf(address(ic)), 0, "No local LP");

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(ic));
        uint256 bearBefore = IERC20(bearToken).balanceOf(address(ic));

        ic.emergencyWithdrawFromCurve();

        assertGt(IERC20(USDC).balanceOf(address(ic)), usdcBefore, "Should recover USDC");
        assertGt(IERC20(bearToken).balanceOf(address(ic)), bearBefore, "Should recover BEAR");
        assertEq(gauge.balanceOf(address(ic)), 0, "Gauge should be empty");
        assertTrue(ic.emergencyActive(), "Emergency mode should be active");
    }

    // ==========================================
    // NAV & ACCOUNTING
    // ==========================================

    function test_totalAssets_includesStakedLp() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);

        uint256 assetsBefore = ic.totalAssets();

        _proposeAndFinalizeGauge();
        ic.stakeToGauge(0);

        uint256 assetsAfter = ic.totalAssets();

        assertApproxEqRel(assetsAfter, assetsBefore, 0.001e18, "totalAssets should be unchanged after staking LP");
    }

    function test_harvest_withStakedLp() public {
        _depositAs(alice, 500_000e6);
        uint256 aliceShares = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        _proposeAndFinalizeGauge();
        ic.stakeToGauge(0);

        _generateCurveFees(50_000e6, 10);
        _warpAndRefreshOracle(1 days);

        uint256 supplyBefore = ic.totalSupply();

        vm.prank(keeper);
        ic.harvest();

        assertGt(ic.totalSupply(), supplyBefore, "Should mint yield shares with LP in gauge");
        assertGt(ic.balanceOf(address(sInvar)), 0, "sINVAR should receive yield");
    }

    function test_depositAndDeploy_afterGaugeSet() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve(0);

        _proposeAndFinalizeGauge();
        ic.stakeToGauge(0);

        _depositAs(bob, 100_000e6);
        ic.deployToCurve(0);

        assertGt(IERC20(curvePool).balanceOf(address(ic)), 0, "New LP minted locally");
        assertGt(gauge.balanceOf(address(ic)), 0, "Old LP still in gauge");
        assertGt(ic.balanceOf(bob), 0, "Bob received shares");
    }

    // ==========================================
    // REWARD CLAIMING
    // ==========================================

    function test_claimGaugeRewards_realGauge() public {
        _setupWithLpInGauge(1_000_000e6);

        _warpAndRefreshOracle(7 days);

        ic.claimGaugeRewards();
    }

    // ==========================================
    // GAUGE MIGRATION
    // ==========================================

    function test_gaugeRotation() public {
        _setupWithLpInGauge(1_000_000e6);

        uint256 stakedBefore = gauge.balanceOf(address(ic));
        assertGt(stakedBefore, 0, "LP should be in old gauge");

        // Curve factory only allows one gauge per pool, so deploy a second pool to get a new gauge.
        // The new gauge still accepts the same LP token deposits via transferFrom.
        address secondPool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
            .deploy_pool(
                "USDC/plDXY-BEAR Pool 2",
                "USDC-plDXY-BEAR-2",
                [USDC, bearToken],
                0,
                CURVE_A,
                CURVE_GAMMA,
                CURVE_MID_FEE,
                CURVE_OUT_FEE,
                CURVE_FEE_GAMMA,
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_HALF_TIME,
                bearPrice
            );
        address newGaugeAddr = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY).deploy_gauge(secondPool);
        ICurveGauge newGauge = ICurveGauge(newGaugeAddr);

        ic.proposeGauge(address(newGauge));
        _warpAndRefreshOracle(7 days);
        ic.finalizeGauge();

        assertEq(gauge.balanceOf(address(ic)), 0, "Old gauge should be emptied");
        assertEq(address(ic.curveGauge()), address(newGauge), "New gauge should be active");

        uint256 localLp = IERC20(curvePool).balanceOf(address(ic));
        assertEq(localLp, stakedBefore, "LP should be back with InvarCoin");
    }

}
