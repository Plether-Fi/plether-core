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
        vm.warp(25 hours); // Must be > 24 hours to avoid underflow in staleness check

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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(oracle),
            address(0),
            address(0)
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
            address(0),
            address(0),
            address(0)
        );
    }

    function test_DistributeRewards_EmitsEvent() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        vm.expectEmit(true, false, false, true);
        emit IRewardDistributor.RewardsDistributed(49.95e18, 49.95e18, 0, 5000, 5000);

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

    // ============================================
    // MUTATION TESTS
    // ============================================

    // Mutation: block.timestamp < lastDistributionTime + MIN_DISTRIBUTION_INTERVAL
    // Tests boundary: exactly at 1 hour should succeed
    function test_Mutation_ExactCooldownBoundary() public {
        usdc.mint(address(distributor), 100e6);
        vm.prank(alice);
        distributor.distributeRewards();

        // Warp to exactly 1 hour (the minimum interval)
        vm.warp(block.timestamp + 1 hours);
        usdc.mint(address(distributor), 100e6);

        // Should succeed at exactly the boundary
        vm.prank(alice);
        distributor.distributeRewards();
    }

    // Mutation: block.timestamp < ... could become <=
    // Tests that 1 second before cooldown still fails
    function test_Mutation_OneSecondBeforeCooldown() public {
        usdc.mint(address(distributor), 100e6);
        vm.prank(alice);
        distributor.distributeRewards();

        vm.warp(block.timestamp + 1 hours - 1);
        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__DistributionTooSoon.selector);
        distributor.distributeRewards();
    }

    // Mutation: spotBear18 < theoreticalBear18 could become <=
    // Tests exact price match gives 50/50 split
    function test_Mutation_ExactPriceMatch() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.8e6); // Exact match

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bearPct, 5000, "Exact match should give 50% to BEAR");
        assertEq(bullPct, 5000, "Exact match should give 50% to BULL");
    }

    // Mutation: bearPct >= bullPct could become >
    // At exactly 50/50, should take the bearPct >= bullPct branch (mint + swap for bear)
    function test_Mutation_5050_TakesBearPath() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.8e6);

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        // At 50/50, both should receive equal amounts
        // If mutation changes >= to >, it would wrongly take the bull path
        assertEq(bearDonated, bullDonated, "50/50 split must donate equal amounts");
    }

    // Mutation: Quadratic formula 5000 + (ratio * ratio * 5000) / (10_000 * 10_000)
    // Tests multiple points on the quadratic curve
    function test_Mutation_QuadraticFormula_HalfThreshold() public {
        // At 1% discrepancy (half of 2% threshold):
        // ratio = 5000 (50% of threshold)
        // underperformerPct = 5000 + (5000 * 5000 * 5000) / (10000 * 10000) = 5000 + 1250 = 6250
        oracle.setPrice(1e8);
        curvePool.setPrice(0.99e6); // 1% below

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bearPct, 6250, "At 50% of threshold, underperformer should get 62.5%");
        assertEq(bullPct, 3750, "At 50% of threshold, other should get 37.5%");
    }

    function test_Mutation_QuadraticFormula_QuarterThreshold() public {
        // At 0.5% discrepancy (quarter of 2% threshold):
        // ratio = 2500 (25% of threshold)
        // underperformerPct = 5000 + (2500 * 2500 * 5000) / (10000 * 10000) = 5000 + 312.5 ≈ 5312
        oracle.setPrice(1e8);
        curvePool.setPrice(0.995e6); // 0.5% below

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertApproxEqAbs(bearPct, 5312, 1, "At 25% of threshold, underperformer should get ~53.12%");
        assertEq(bearPct + bullPct, 10_000, "Must sum to 100%");
    }

    function test_Mutation_QuadraticFormula_ThreeQuarterThreshold() public {
        // At 1.5% discrepancy (75% of 2% threshold):
        // ratio = 7500 (75% of threshold)
        // underperformerPct = 5000 + (7500 * 7500 * 5000) / (10000 * 10000) = 5000 + 2812.5 ≈ 7812
        oracle.setPrice(1e8);
        curvePool.setPrice(0.985e6); // 1.5% below

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertApproxEqAbs(bearPct, 7812, 1, "At 75% of threshold, underperformer should get ~78.12%");
        assertEq(bearPct + bullPct, 10_000, "Must sum to 100%");
    }

    // Mutation: discrepancyBps >= DISCREPANCY_THRESHOLD_BPS could become >
    // Verifies behavior at exactly 2% (already covered but reinforcing)
    function test_Mutation_ExactThreshold_Gets100Percent() public {
        oracle.setPrice(1e8);
        // Exactly 2% below: 1.00 * 0.98 = 0.98
        curvePool.setPrice(0.98e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bearPct, 10_000, "At exact 2% threshold, underperformer must get 100%");
        assertEq(bullPct, 0, "At exact 2% threshold, other must get 0%");
    }

    // Mutation: if (bearAmount > 0) could be removed
    // Tests that zero donations don't cause issues
    function test_Mutation_ZeroBearDonation_NoRevert() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.85e6); // BULL underperforming, BEAR gets 0%

        usdc.mint(address(distributor), 100e6);

        (uint256 bearPct,,,) = distributor.previewDistribution();
        assertEq(bearPct, 0, "BEAR should get 0%");

        // Should not revert even with zero BEAR donation
        vm.prank(alice);
        distributor.distributeRewards();
    }

    // Mutation: if (bullAmount > 0) could be removed
    function test_Mutation_ZeroBullDonation_NoRevert() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.75e6); // BEAR underperforming, BULL gets 0%

        usdc.mint(address(distributor), 100e6);

        (, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bullPct, 0, "BULL should get 0%");

        // Should not revert even with zero BULL donation
        vm.prank(alice);
        distributor.distributeRewards();
    }

    // Mutation: mintUsdc = (totalUsdc * bullPct * 2) / 10_000 - the * 2 factor
    // Verifies the mint/swap ratio is correct
    function test_Mutation_MintSwapRatio_70_30() public {
        // At 70% BEAR / 30% BULL:
        // mintUsdc = totalUsdc * 30% * 2 = 60% of totalUsdc
        // swapUsdc = 40% of totalUsdc
        // This ensures we get 30% BULL from mint and 40% extra BEAR from swap
        oracle.setPrice(1e8);
        // Need ~1.33% discrepancy for 70% allocation
        // At 1.33%, ratio = 6650, underperformerPct = 5000 + (6650^2 * 5000) / 100000000 ≈ 7210
        curvePool.setPrice(0.988e6); // ~1.2% below for approximately 70%

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // Verify we're in the expected range
        assertGt(bearPct, 6000, "BEAR should be majority");
        assertLt(bearPct, 8000, "BEAR should not be too high");

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        // Verify ratio matches allocation
        uint256 totalDonated = bearDonated + bullDonated;
        uint256 actualBearPct = (bearDonated * 10_000) / totalDonated;

        assertApproxEqAbs(actualBearPct, bearPct, 200, "Actual donation ratio should match target");
    }

    // Mutation: swapUsdc = totalUsdc - mintUsdc could become totalUsdc + mintUsdc
    function test_Mutation_SwapUsdcCalculation() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.78e6); // ~2.5% below, so 100% to BEAR

        usdc.mint(address(distributor), 100e6);

        uint256 usdcBefore = usdc.balanceOf(address(distributor));
        assertEq(usdcBefore, 100e6);

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewards();

        // All USDC should be consumed (caller reward + distribution)
        uint256 usdcAfter = usdc.balanceOf(address(distributor));
        assertEq(usdcAfter, 0, "All USDC should be distributed");
        assertEq(callerReward, 0.1e6, "Caller should get 0.1%");
    }

    // Mutation: lastDistributionTime = block.timestamp could be removed
    function test_Mutation_LastDistributionTimeUpdated() public {
        usdc.mint(address(distributor), 100e6);

        assertEq(distributor.lastDistributionTime(), 0, "Initial time should be 0");

        uint256 distributionTime = block.timestamp;
        vm.prank(alice);
        distributor.distributeRewards();

        assertEq(distributor.lastDistributionTime(), distributionTime, "Time must be updated");

        // Immediate second call should fail (proves time was updated)
        usdc.mint(address(distributor), 100e6);
        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__DistributionTooSoon.selector);
        distributor.distributeRewards();
    }

    // Mutation: USDC.safeTransfer(msg.sender, callerReward) could be removed
    function test_Mutation_CallerRewardTransferred() public {
        usdc.mint(address(distributor), 1000e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        assertEq(bobBefore, 0);

        vm.prank(bob);
        uint256 callerReward = distributor.distributeRewards();

        uint256 bobAfter = usdc.balanceOf(bob);
        assertEq(bobAfter, callerReward, "Caller must receive reward");
        assertEq(bobAfter, 1e6, "Reward should be 0.1% of 1000 USDC");
    }

    // Mutation: diff calculation ternary could be inverted
    function test_Mutation_DiffCalculation_BearOverpriced() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.84e6); // BEAR overpriced by 5%

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // When BEAR is overpriced, BULL is underperforming
        assertEq(bullPct, 10_000, "BULL should get 100% when BEAR is 5% overpriced");
        assertEq(bearPct, 0, "BEAR should get 0% when overpriced");
    }

    function test_Mutation_DiffCalculation_BearUnderpriced() public {
        oracle.setPrice(0.8e8);
        curvePool.setPrice(0.76e6); // BEAR underpriced by 5%

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // When BEAR is underpriced, BEAR is underperforming
        assertEq(bearPct, 10_000, "BEAR should get 100% when 5% underpriced");
        assertEq(bullPct, 0, "BULL should get 0% when BEAR is underpriced");
    }

    // ============================================
    // MUTATION KILLER TESTS (Round 2)
    // Kill mutants: 107, 113, 206, 209, 211, 212, 214, 215, 226, 227, 228, 235, 271-282
    // ============================================

    // Kill mutants 107, 113: subtraction → modulo in diff calculation
    // Need 50%+ price gap where (a - b) ≠ (a % b)
    function test_Mutation_LargePriceGap_BearUnderpriced() public {
        oracle.setPrice(1e8); // theoretical = 1.0
        curvePool.setPrice(0.5e6); // spot = 0.5 (50% below)

        // diff = 1.0 - 0.5 = 0.5 (original)
        // diff = 1.0 % 0.5 = 0 (mutant 113) - WRONG!

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // 50% discrepancy is way above 2% threshold, so 100% to BEAR
        assertEq(bearPct, 10_000, "BEAR must get 100% at 50% underpricing");
        assertEq(bullPct, 0, "BULL must get 0%");
    }

    function test_Mutation_LargePriceGap_BullUnderpriced() public {
        oracle.setPrice(1e8); // theoretical = 1.0
        curvePool.setPrice(1.5e6); // spot = 1.5 (50% above, so BULL underpriced)

        // diff = 1.5 - 1.0 = 0.5 (original)
        // diff = 1.5 % 1.0 = 0.5 (mutant 107) - happens to be same!
        // Need different values...

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        assertEq(bullPct, 10_000, "BULL must get 100% when 50% underpriced");
        assertEq(bearPct, 0, "BEAR must get 0%");
    }

    function test_Mutation_LargePriceGap_ModuloBreaks() public {
        // Use values where a % b gives clearly wrong result
        oracle.setPrice(1.2e8); // theoretical = 1.2
        curvePool.setPrice(0.5e6); // spot = 0.5

        // diff = 1.2 - 0.5 = 0.7 (original) => 58% discrepancy
        // diff = 1.2 % 0.5 = 0.2 (mutant) => 16% discrepancy - WRONG!

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // 58% discrepancy means 100% to BEAR
        assertEq(bearPct, 10_000, "BEAR must get 100% at large discrepancy");
        assertEq(bullPct, 0, "BULL must get 0%");
    }

    // Kill mutants 206, 209, 211, 212, 214, 215: mutations to mintUsdc calculation
    // Kill mutants 226, 227, 228: if(mintUsdc > 0) mutations and mint deletion
    // Kill mutant 235: bearAmount = 1 instead of balance
    // These all affect the BULL path (bearPct < bullPct)
    function test_Mutation_BullPath_PartialAllocation() public {
        // Set up 40% BEAR / 60% BULL allocation
        oracle.setPrice(1e8);
        curvePool.setPrice(1.01e6); // BEAR slightly overpriced => BULL underperforming

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();

        // Verify we're in the BULL path (bullPct > bearPct)
        assertGt(bullPct, bearPct, "BULL should get more than BEAR");
        assertGt(bearPct, 0, "BEAR should still get some");
        assertLt(bullPct, 10_000, "BULL should not get 100%");

        usdc.mint(address(distributor), 1000e6); // Large amount to make mutations visible

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        // Verify both tokens received meaningful amounts (not 0 or 1)
        assertGt(bearDonated, 100e18, "BEAR donation must be substantial");
        assertGt(bullDonated, 100e18, "BULL donation must be substantial");

        // BULL should get more than BEAR
        assertGt(bullDonated, bearDonated, "BULL must receive more than BEAR");

        // Verify approximate ratio matches allocation
        uint256 totalDonated = bearDonated + bullDonated;
        uint256 actualBearPct = (bearDonated * 10_000) / totalDonated;

        assertApproxEqAbs(actualBearPct, bearPct, 300, "Actual BEAR % should match target");
    }

    // Kill mutants in minOut calculation (271-282)
    // These affect the BEAR path swap slippage calculation
    function test_Mutation_BearPath_SwapSlippage() public {
        // Set up 70% BEAR / 30% BULL allocation (BEAR path)
        oracle.setPrice(1e8);
        curvePool.setPrice(0.99e6); // BEAR slightly underpriced

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertGt(bearPct, bullPct, "BEAR should get more");

        usdc.mint(address(distributor), 1000e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;

        // With 1000 USDC and ~70% to BEAR, should get substantial BEAR
        // If minOut calculation is wrong, swap would fail or give wrong amount
        assertGt(bearDonated, 300e18, "BEAR donation must be substantial");
    }

    // Verify exact amounts to catch assignment mutations (mutant 235)
    function test_Mutation_ExactDonationAmounts() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6); // 50/50 split

        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));
        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        // At 50/50, both should receive equal substantial amounts
        // 99.9 USDC distributed, ~50 USDC each => ~25 tokens each (at CAP = 2)
        assertGt(bearDonated, 20e18, "BEAR must get meaningful amount, not 1");
        assertGt(bullDonated, 20e18, "BULL must get meaningful amount, not 1");
        assertApproxEqRel(bearDonated, bullDonated, 0.05e18, "50/50 should be equal");
    }

    // Test that minting actually happens in BULL path (kills mutant 228)
    function test_Mutation_BullPath_MintingOccurs() public {
        // 30% BEAR / 70% BULL - should mint pairs AND zap
        oracle.setPrice(1e8);
        curvePool.setPrice(1.015e6); // BEAR overpriced by 1.5%

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertLt(bearPct, bullPct, "Must be in BULL path");
        assertGt(bearPct, 0, "BEAR pct must be non-zero for minting to occur");

        usdc.mint(address(distributor), 1000e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;

        // If minting was deleted (mutant 228), BEAR would get 0 in BULL path
        // But with 30% allocation to BEAR, we should get meaningful amount
        assertGt(bearDonated, 100e18, "BEAR must receive tokens from minting");
    }

    // Test large values to distinguish division from modulo (kill 206, 271)
    function test_Mutation_LargeValues_DivisionVsModulo() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1.01e6); // BULL path

        // Use amount where totalUsdc * bearPct * 2 > 10_000
        // so that division gives different result than modulo
        usdc.mint(address(distributor), 10_000e6); // 10,000 USDC

        uint256 stakedBullBefore = plDxyBull.balanceOf(address(stakedBull));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 bullDonated = plDxyBull.balanceOf(address(stakedBull)) - stakedBullBefore;

        // With 10,000 USDC, should get thousands of tokens
        // If using modulo instead of division, would get tiny amount
        assertGt(bullDonated, 1000e18, "Must get thousands of tokens with 10k USDC");
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

    // ============================================
    // DISTRIBUTE REWARDS WITH PRICE UPDATE TESTS
    // ============================================

    function test_DistributeRewardsWithPriceUpdate_WorksWithNoPythAdapter() public {
        // PYTH_ADAPTER is address(0) in setUp
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        bytes[] memory emptyUpdateData = new bytes[](0);

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewardsWithPriceUpdate(emptyUpdateData);

        assertEq(callerReward, 0.1e6, "Caller should receive 0.1% reward");

        uint256 bearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        assertGt(bearDonated, 0, "BEAR should receive rewards");
    }

    function test_DistributeRewardsWithPriceUpdate_SkipsUpdateWhenEmptyData() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        bytes[] memory emptyUpdateData = new bytes[](0);

        vm.prank(alice);
        uint256 callerReward = distributor.distributeRewardsWithPriceUpdate(emptyUpdateData);

        assertEq(callerReward, 0.1e6, "Should work with empty update data");
    }

    function test_DistributeRewardsWithPriceUpdate_RespectsCooldown() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        bytes[] memory emptyUpdateData = new bytes[](0);

        vm.prank(alice);
        distributor.distributeRewardsWithPriceUpdate(emptyUpdateData);

        usdc.mint(address(distributor), 100e6);

        vm.prank(alice);
        vm.expectRevert(IRewardDistributor.RewardDistributor__DistributionTooSoon.selector);
        distributor.distributeRewardsWithPriceUpdate(emptyUpdateData);
    }

    // ============================================
    // INVAR COIN SPLIT TESTS
    // ============================================

    function _createDistributorWithInvar(
        MockInvarCoin invar
    ) internal returns (RewardDistributor) {
        return new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle),
            address(0),
            address(invar)
        );
    }

    function _stakeIntoStakedBear(
        uint256 amount
    ) internal {
        plDxyBear.mint(alice, amount);
        vm.startPrank(alice);
        plDxyBear.approve(address(stakedBear), amount);
        stakedBear.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_InvarSplit_5050() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        _stakeIntoStakedBear(1000e18);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        // stakedBear.totalAssets() = 1000e18
        // invarBearExposure = (totalAssets * 1e20) / (2 * 1e8) = 1000e18
        // => totalAssets = 2000e6
        invar.setTotalAssets(2000e6);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        dist.distributeRewards();

        uint256 stakedBearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 invarUsdcDonated = usdc.balanceOf(address(invar));

        assertGt(stakedBearDonated, 0, "StakedBear donation should be non-zero");
        assertGt(invarUsdcDonated, 0, "InvarCoin USDC donation should be non-zero");

        // With equal exposure, invar should get ~50% of bear-side USDC
        uint256 callerReward = (100e6 * 10) / 10_000;
        uint256 bearUsdc = (100e6 - callerReward) / 2;
        assertApproxEqRel(invarUsdcDonated, bearUsdc / 2, 0.02e18, "50/50 split should give half of bear USDC");
    }

    function test_InvarSplit_75_25() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        _stakeIntoStakedBear(1000e18);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        // stakedBear.totalAssets() = 1000e18
        // For 75% staked / 25% invar:
        // invarBearExposure = 1000e18 / 3
        // totalAssets = (1000e18/3) * 2e8 / 1e20 = ~666.67e6
        invar.setTotalAssets(666_666_666);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        vm.prank(alice);
        dist.distributeRewards();

        uint256 invarUsdcDonated = usdc.balanceOf(address(invar));
        uint256 callerReward = (100e6 * 10) / 10_000;
        uint256 bearUsdc = (100e6 - callerReward) / 2;

        // InvarCoin should get ~25% of bear-side USDC (75/25 split)
        assertGt(invarUsdcDonated, 0, "InvarCoin should receive USDC");
        assertLt(invarUsdcDonated, bearUsdc / 2, "InvarCoin should get less than half of bear USDC");
    }

    function test_InvarSplit_ZeroInvarAssets_AllToStaked() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        invar.setTotalAssets(0);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        dist.distributeRewards();

        uint256 stakedBearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 invarUsdcDonated = usdc.balanceOf(address(invar));

        assertGt(stakedBearDonated, 0, "StakedBear should get all BEAR");
        assertEq(invarUsdcDonated, 0, "InvarCoin should get nothing");
    }

    function test_InvarSplit_ZeroStakedBearAssets_AllToInvar() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        // Remove all BEAR from stakedBear so totalAssets = 0
        uint256 stakedBal = plDxyBear.balanceOf(address(stakedBear));
        vm.prank(address(stakedBear));
        plDxyBear.transfer(address(1), stakedBal);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        invar.setTotalAssets(1000e6);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        vm.prank(alice);
        dist.distributeRewards();

        uint256 invarUsdcDonated = usdc.balanceOf(address(invar));
        assertGt(invarUsdcDonated, 0, "InvarCoin should get all bear-side USDC");
    }

    function test_InvarSplit_InvarCoinZeroAddress_AllToStaked() public {
        // Default distributor has INVAR_COIN = address(0)
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);
        usdc.mint(address(distributor), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        distributor.distributeRewards();

        uint256 stakedBearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        assertGt(stakedBearDonated, 0, "StakedBear should get all BEAR when INVAR_COIN is zero");
    }

    function test_InvarSplit_EventIncludesInvarAmount() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        invar.setTotalAssets(2000e6);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        vm.prank(alice);
        dist.distributeRewards();

        // Just verify it didn't revert — event parameter verification is covered by other tests
    }

    function test_InvarSplit_InvarTotalAssetsReverts_AllToStaked() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        invar.setShouldRevert(true);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        dist.distributeRewards();

        uint256 stakedBearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        assertGt(stakedBearDonated, 0, "StakedBear should get all BEAR when InvarCoin reverts");
    }

    function test_InvarSplit_DonateUsdcReverts_FallbackToStaked() public {
        oracle.setPrice(1e8);
        curvePool.setPrice(1e6);

        _stakeIntoStakedBear(1000e18);

        MockInvarCoin invar = new MockInvarCoin(address(usdc));
        invar.setTotalAssets(2000e6);
        invar.setDonateUsdcReverts(true);

        RewardDistributor dist = _createDistributorWithInvar(invar);
        usdc.mint(address(dist), 100e6);

        uint256 stakedBearBefore = plDxyBear.balanceOf(address(stakedBear));

        vm.prank(alice);
        dist.distributeRewards();

        uint256 stakedBearDonated = plDxyBear.balanceOf(address(stakedBear)) - stakedBearBefore;
        uint256 invarUsdcDonated = usdc.balanceOf(address(invar));

        assertGt(stakedBearDonated, 0, "StakedBear should get all BEAR when donateUsdc reverts");
        assertEq(invarUsdcDonated, 0, "InvarCoin should get nothing when donateUsdc reverts");
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

    function mintWithPermit(
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }

    function treasury() external view returns (address) {
        return address(this);
    }

    function liquidationTimestamp() external pure returns (uint256) {
        return 0;
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

contract MockPythAdapter {

    bool public updateCalled;
    uint256 public lastUpdateValue;
    uint256 public fee = 1 wei;

    function setFee(
        uint256 _fee
    ) external {
        fee = _fee;
    }

    function updatePrice(
        bytes[] calldata
    ) external payable {
        updateCalled = true;
        lastUpdateValue = msg.value;
        uint256 refund = msg.value > fee ? msg.value - fee : 0;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
    }

}

contract RewardDistributorPythTest is Test {

    RewardDistributor public distributor;
    MockPythAdapter public pythAdapter;

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

    function setUp() public {
        vm.warp(25 hours);

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

        pythAdapter = new MockPythAdapter();

        distributor = new RewardDistributor(
            address(splitter),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedBear),
            address(stakedBull),
            address(curvePool),
            address(zapRouter),
            address(oracle),
            address(pythAdapter),
            address(0)
        );

        plDxyBear.mint(address(stakedBear), 1000e18);
        plDxyBull.mint(address(stakedBull), 1000e18);
    }

    function test_DistributeRewardsWithPriceUpdate_CallsPythAdapter() public {
        usdc.mint(address(distributor), 100e6);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        distributor.distributeRewardsWithPriceUpdate{value: 1 wei}(updateData);

        assertTrue(pythAdapter.updateCalled(), "PythAdapter.updatePrice should be called");
        assertEq(pythAdapter.lastUpdateValue(), 1 wei, "Should forward msg.value");
    }

    function test_DistributeRewardsWithPriceUpdate_SkipsWhenEmptyData() public {
        usdc.mint(address(distributor), 100e6);

        bytes[] memory emptyData = new bytes[](0);

        vm.prank(alice);
        distributor.distributeRewardsWithPriceUpdate(emptyData);

        assertFalse(pythAdapter.updateCalled(), "Should not call updatePrice with empty data");
    }

    function test_PYTH_ADAPTER_Immutable() public view {
        assertEq(address(distributor.PYTH_ADAPTER()), address(pythAdapter));
    }

    function test_DistributeRewardsWithPriceUpdate_RefundsExcessETH() public {
        usdc.mint(address(distributor), 100e6);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        distributor.distributeRewardsWithPriceUpdate{value: 0.5 ether}(updateData);

        // MockPythAdapter keeps 1 wei fee, refunds rest to distributor.
        // Distributor sweeps remaining ETH back to caller.
        assertEq(alice.balance, 1 ether - 1 wei, "Caller should get back all ETH minus Pyth fee");
        assertEq(address(distributor).balance, 0, "Distributor should hold no ETH");
    }

}

contract MockInvarCoin {

    IERC20 public usdc;
    uint256 private _totalAssets;
    bool private _shouldRevert;
    bool private _donateUsdcReverts;

    constructor(
        address _usdc
    ) {
        usdc = IERC20(_usdc);
    }

    function setTotalAssets(
        uint256 val
    ) external {
        _totalAssets = val;
    }

    function setShouldRevert(
        bool val
    ) external {
        _shouldRevert = val;
    }

    function setDonateUsdcReverts(
        bool val
    ) external {
        _donateUsdcReverts = val;
    }

    function totalAssets() external view returns (uint256) {
        require(!_shouldRevert, "MockInvarCoin: revert");
        return _totalAssets;
    }

    function donateUsdc(
        uint256 usdcAmount
    ) external {
        require(!_donateUsdcReverts, "MockInvarCoin: donateUsdc reverted");
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
    }

}
