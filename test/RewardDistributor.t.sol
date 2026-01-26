// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RewardDistributor} from "../src/RewardDistributor.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract RewardDistributorTest is Test {

    RewardDistributor public distributor;

    MockToken public usdc;
    MockFlashToken public plDxyBear;
    MockFlashToken public plDxyBull;
    MockSplitter public splitter;
    MockCurvePool public curvePool;
    MockOracle public oracle;
    StakedToken public stakedBear;
    StakedToken public stakedBull;
    ZapRouter public zapRouter;

    address alice = address(0xA11ce);
    address bob = address(0xB0b);

    uint256 constant CAP = 2e8;

    function setUp() public {
        vm.warp(2 hours);

        usdc = new MockToken("USDC", "USDC");
        plDxyBear = new MockFlashToken("plDxyBear", "plDxyBear");
        plDxyBull = new MockFlashToken("plDxyBull", "plDxyBull");
        splitter = new MockSplitter(address(plDxyBear), address(plDxyBull));
        splitter.setUsdc(address(usdc));

        oracle = new MockOracle(1e8);
        curvePool = new MockCurvePool(address(usdc), address(plDxyBear));
        curvePool.setPrice(1e6);

        stakedBear = new StakedToken(IERC20(address(plDxyBear)), "Staked BEAR", "sBEAR");
        stakedBull = new StakedToken(IERC20(address(plDxyBull)), "Staked BULL", "sBULL");

        zapRouter =
            new ZapRouter(address(splitter), address(plDxyBear), address(plDxyBull), address(usdc), address(curvePool));

        distributor = new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );

        plDxyBear.mint(address(stakedBear), 1000e18);
        plDxyBull.mint(address(stakedBull), 1000e18);

        vm.prank(alice);
        plDxyBear.approve(address(stakedBear), type(uint256).max);
        vm.prank(alice);
        plDxyBull.approve(address(stakedBull), type(uint256).max);
    }

    function test_DistributeRewards_50_50_Split() public {
        curvePool.setPrice(1e6);
        oracle.setPrice(1e8);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewards();

        uint256 stakedBearAfter = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullAfter = plDxyBull.balanceOf(address(stakedBull));

        assertEq(callerReward, 0.1e6, "Caller should receive 0.1% reward");
        assertEq(usdc.balanceOf(alice), callerReward, "Alice should receive caller reward");

        uint256 bearDonated = stakedBearAfter - stakedBearBefore;
        uint256 bullDonated = stakedBullAfter - stakedBullBefore;

        assertApproxEqRel(bearDonated, bullDonated, 0.05e18, "50/50 split should donate equal amounts");
        assertGt(bearDonated, 0, "BEAR donation should be non-zero");
        assertGt(bullDonated, 0, "BULL donation should be non-zero");
    }

    function test_DistributeRewards_100_Bear_Split() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(0.96e6);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 stakedBearAfter = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullAfter = plDxyBull.balanceOf(address(stakedBull));

        uint256 bearDonated = stakedBearAfter - stakedBearBefore;
        uint256 bullDonated = stakedBullAfter - stakedBullBefore;

        assertGt(bearDonated, 0, "BEAR donation should be non-zero");
        assertEq(bullDonated, 0, "BULL donation should be zero at 100% BEAR");
    }

    function test_DistributeRewards_100_Bull_Split() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1.04e6);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 stakedBearAfter = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullAfter = plDxyBull.balanceOf(address(stakedBull));

        uint256 bearDonated = stakedBearAfter - stakedBearBefore;
        uint256 bullDonated = stakedBullAfter - stakedBullBefore;

        assertGt(bullDonated, 0, "BULL donation should be non-zero");
        assertGt(bullDonated, bearDonated * 100, "BULL should get >99% of rewards");
    }

    function test_DistributeRewards_QuadraticInterpolation() public {
        // At 1% discrepancy (50% of 2% threshold), quadratic gives:
        // underperformerPct = 50% + (0.5)² × 50% = 62.5%
        oracle.setPrice(1e8);
        curvePool.setPrice(0.99e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertApproxEqAbs(bearPct, 6250, 50, "BEAR pct should be ~62.5% at 1% discrepancy");
        assertEq(bearPct + bullPct, 10_000, "Percentages should sum to 100%");
    }

    function test_DistributeRewards_RevertsIfTooSoon() public {
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        distributor.distributeRewards();

        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__DistributionTooSoon.selector);
        distributor.distributeRewards();
    }

    function test_DistributeRewards_SucceedsAfterCooldown() public {
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        distributor.distributeRewards();

        vm.warp(block.timestamp + 1 hours);
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        distributor.distributeRewards();
    }

    function test_DistributeRewards_RevertsIfNoRewards() public {
        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__NoRewards.selector);
        distributor.distributeRewards();
    }

    function test_DistributeRewards_RevertsIfSplitterPaused() public {
        splitter.setStatus(ISyntheticSplitter.Status.PAUSED);
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__SplitterNotActive.selector);
        distributor.distributeRewards();
    }

    function test_DistributeRewards_RevertsIfSplitterSettled() public {
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__SplitterNotActive.selector);
        distributor.distributeRewards();
    }

    function test_PreviewDistribution() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(0.98e6);
        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct, uint256 usdcBalance, uint256 callerReward) =
            distributor.previewDistribution();

        assertEq(usdcBalance, 100e6, "USDC balance should match");
        assertEq(callerReward, 0.1e6, "Caller reward should be 0.1%");
        assertEq(bearPct + bullPct, 10_000, "Percentages should sum to 100%");
        assertGt(bearPct, 5000, "BEAR should be underperforming");
    }

    function test_Constructor_RevertsOnZeroAddress_Splitter() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(0),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_Usdc() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(0),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_PlDxyBear() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(0),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_PlDxyBull() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(0),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_StakedBear() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(0),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_StakedBull() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(0),
            address(curvePool),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_CurvePool() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(0),
            address(zapRouter),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_ZapRouter() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(0),
            address(oracle)
        );
    }

    function test_Constructor_RevertsOnZeroAddress_Oracle() public {
        vm.expectRevert(IRewardDistributor.RewardDistributor__ZeroAddress.selector);
        new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(0)
        );
    }

    function test_DistributeRewards_EmitsEvent() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        vm.expectEmit(false, false, false, false);
        emit IRewardDistributor.RewardsDistributed(0, 0, 0, 0);

        vm.prank(alice);
        distributor.distributeRewards();
    }

    function testFuzz_DistributeRewards_VariableDiscrepancy(
        uint256 discrepancyBps
    ) public {
        discrepancyBps = bound(discrepancyBps, 0, 500);

        oracle.setPrice(1e8);
        uint256 theoreticalBear = 1e6;
        uint256 spotBear = theoreticalBear - (theoreticalBear * discrepancyBps) / 10_000;
        curvePool.setPrice(spotBear);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct + bullPct, 10_000, "Percentages should always sum to 100%");
        assertGe(bearPct, 5000, "BEAR should get at least 50% when underperforming");
    }

    function testFuzz_DistributeRewards_VariableAmount(
        uint256 usdcAmount
    ) public {
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000e6);

        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), usdcAmount);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewards();

        uint256 expectedReward = (usdcAmount * 10) / 10_000;
        assertEq(callerReward, expectedReward, "Caller reward should be 0.1%");

        uint256 stakedBearAfter = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullAfter = plDxyBull.balanceOf(address(stakedBull));

        assertGe(stakedBearAfter, stakedBearBefore, "BEAR balance should not decrease");
        assertGe(stakedBullAfter, stakedBullBefore, "BULL balance should not decrease");
    }

    function test_DistributeRewards_NonDollarOracle_BearUnderperforming() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.76e6);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertGt(bearPct, 5000, "BEAR should get majority when underperforming");

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        assertGt(bearDonated, bullDonated, "BEAR should receive more rewards");
    }

    function test_DistributeRewards_NonDollarOracle_BullUnderperforming() public {
        oracle.setPrice(1.2e8);
        curvePool.setPrice(1.26e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertGt(bullPct, 5000, "BULL should get majority when underperforming");

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        assertGt(bullDonated, bearDonated, "BULL should receive more rewards");
    }

    function test_DistributeRewards_ExactThreshold() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.784e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bearPct, 10_000, "BEAR should get 100% at exact threshold");
        assertEq(bullPct, 0, "BULL should get 0% at exact threshold");
    }

    function test_DistributeRewards_AboveThreshold() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.75e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bearPct, 10_000, "BEAR should get 100% above threshold");
        assertEq(bullPct, 0, "BULL should get 0% above threshold");
    }

    function test_DistributeRewards_SpotHigherThanTheoretical() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.84e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertGt(bullPct, bearPct, "BULL should get more when BEAR overpriced");

        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;
        assertGt(bullDonated, 0, "BULL should receive rewards");
    }

    function test_DistributeRewards_ZeroBullAllocation() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.75e6);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;
        assertEq(bullDonated, 0, "BULL should receive zero when 100% to BEAR");
    }

    function test_DistributeRewards_ZeroBearTargetAllocation() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.85e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct, 0, "BEAR target should be 0%");
        assertEq(bullPct, 10_000, "BULL target should be 100%");

        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;
        assertGt(bullDonated, 0, "BULL should receive rewards");
    }

    function test_DistributeRewards_UpdatesLastDistributionTime() public {
        usdc.mint(address(distributor), 100e6);

        uint256 timeBefore = distributor.lastDistributionTime();
        assertEq(timeBefore, 0, "Initial distribution time should be 0");

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 timeAfter = distributor.lastDistributionTime();
        assertEq(timeAfter, block.timestamp, "Distribution time should update");
    }

    function test_DistributeRewards_CallerGetsReward() public {
        usdc.mint(address(distributor), 1000e6);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewards();

        uint256 aliceAfter = usdc.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, callerReward, "Alice should receive caller reward");
        assertEq(callerReward, 1e6, "Reward should be 0.1% of 1000 USDC");
    }

    function test_PreviewDistribution_ZeroBalance() public {
        (uint256 bearPct, uint256 bullPct, uint256 usdcBalance, uint256 callerReward) =
            distributor.previewDistribution();

        assertEq(usdcBalance, 0, "Balance should be zero");
        assertEq(callerReward, 0, "Caller reward should be zero");
        assertEq(bearPct + bullPct, 10_000, "Percentages should still sum to 100%");
    }

    function testFuzz_DistributeRewards_NonDollarOracle(
        uint256 oraclePrice,
        uint256 discrepancyBps
    ) public {
        oraclePrice = bound(oraclePrice, 0.5e8, 1.5e8);
        discrepancyBps = bound(discrepancyBps, 0, 500);

        oracle.setPrice(int256(oraclePrice));

        uint256 theoreticalSpot = (oraclePrice * 1e6) / 1e8;
        uint256 spotPrice = theoreticalSpot - (theoreticalSpot * discrepancyBps) / 10_000;
        curvePool.setPrice(spotPrice);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct + bullPct, 10_000, "Percentages should always sum to 100%");

        vm.prank(alice);
        distributor.distributeRewards();
    }

    function test_Immutables() public view {
        assertEq(address(distributor.SPLITTER()), address(splitter));
        assertEq(address(distributor.USDC()), address(usdc));
        assertEq(address(distributor.PLDXY_BEAR()), address(plDxyBear));
        assertEq(address(distributor.PLDXY_BULL()), address(plDxyBull));
        assertEq(address(distributor.STAKED_BEAR()), address(stakedBear));
        assertEq(address(distributor.STAKED_BULL()), address(stakedBull));
        assertEq(address(distributor.CURVE_POOL()), address(curvePool));
        assertEq(address(distributor.ZAP_ROUTER()), address(zapRouter));
        assertEq(address(distributor.ORACLE()), address(oracle));
        assertEq(distributor.CAP(), CAP);
    }

    function test_Constants() public view {
        assertEq(distributor.DISCREPANCY_THRESHOLD_BPS(), 200);
        assertEq(distributor.MIN_DISTRIBUTION_INTERVAL(), 1 hours);
        assertEq(distributor.CALLER_REWARD_BPS(), 10);
        assertEq(distributor.USDC_INDEX(), 0);
        assertEq(distributor.PLDXY_BEAR_INDEX(), 1);
        assertEq(distributor.MAX_SWAP_SLIPPAGE_BPS(), 100);
    }

    function test_DistributeRewards_Equal5050_NoSwap() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.8e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct, 5000, "BEAR should be exactly 50%");
        assertEq(bullPct, 5000, "BULL should be exactly 50%");

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        assertGt(bearDonated, 0, "BEAR should receive rewards");
        assertGt(bullDonated, 0, "BULL should receive rewards");
        assertEq(bearDonated, bullDonated, "Equal split means equal donations");
    }

    function test_DistributeRewards_100Bear_NoMint() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.75e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct, 10_000, "BEAR should get 100%");
        assertEq(bullPct, 0, "BULL should get 0%");

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        assertGt(bearDonated, 0, "BEAR should receive all rewards via swap");
    }

    function test_DistributeRewards_PartialBullAllocation() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.808e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertGt(bullPct, bearPct, "BULL should get more than BEAR");
        assertGt(bearPct, 0, "BEAR should still get some");
        assertLt(bullPct, 10_000, "BULL should not get 100%");

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        assertGt(bearDonated, 0, "BEAR should receive some rewards");
        assertGt(bullDonated, 0, "BULL should receive some rewards");
        assertGt(bullDonated, bearDonated, "BULL should receive more");
    }

    function test_DistributeRewards_100Bull_NoMint() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.85e6);

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct, 0, "BEAR should get 0%");
        assertEq(bullPct, 10_000, "BULL should get 100%");

        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;
        assertGt(bullDonated, 0, "BULL should receive rewards via zap");
    }

}

contract MockToken is ERC20 {

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockFlashToken is ERC20, IERC3156FlashLender {

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

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

    function maxFlashLoan(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(
        address,
        uint256
    ) public pure override returns (uint256) {
        return 0;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        _mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        _burn(address(receiver), amount);
        return true;
    }

}

contract MockCurvePool is ICurvePool {

    address public token0;
    address public token1;
    uint256 public bearPrice = 1e6;

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(
        uint256 _price
    ) external {
        bearPrice = _price;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        if (i == 1 && j == 0) {
            return (dx * bearPrice) / 1e18;
        }
        if (i == 0 && j == 1) {
            return (dx * 1e18) / bearPrice;
        }
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);

        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12;
    }

}

contract MockSplitter is ISyntheticSplitter {

    address public tA;
    address public tB;
    address public usdc;
    Status private _status = Status.ACTIVE;

    uint256 public constant CAP = 2e8;

    constructor(
        address _tA,
        address _tB
    ) {
        tA = _tA;
        tB = _tB;
    }

    function setUsdc(
        address _usdc
    ) external {
        usdc = _usdc;
    }

    function setStatus(
        Status newStatus
    ) external {
        _status = newStatus;
    }

    function mint(
        uint256 amount
    ) external override {
        uint256 usdcCost = (amount * CAP) / 1e20;
        MockToken(usdc).transferFrom(msg.sender, address(this), usdcCost);
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external override {
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);
        uint256 usdcOut = (amount * CAP) / 1e20;
        MockToken(usdc).mint(msg.sender, usdcOut);
    }

    function emergencyRedeem(
        uint256
    ) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }

}

contract MockOracle is AggregatorV3Interface {

    int256 private _price;

    constructor(
        int256 price_
    ) {
        _price = price_;
    }

    function setPrice(
        int256 price_
    ) external {
        _price = price_;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock Oracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, block.timestamp, 0);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, block.timestamp, 0);
    }

}
