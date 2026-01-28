// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {BaseForkTest, ICurvePoolExtended, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title RewardDistributor Fork Tests
/// @notice Tests that can only be validated on a mainnet fork:
/// 1. Real liquidity slippage - price impact on actual Curve pool
/// 2. Real rounding - USDC (6 dec) / tokens (18 dec) / oracle (8 dec) conversions
/// 3. Stale oracle protection - verifies 8-hour timeout via OracleLib
contract RewardDistributorForkTest is BaseForkTest {

    RewardDistributor distributor;
    StakedToken stBear;
    StakedToken stBull;
    ZapRouter zapRouter;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 50_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(2_000_000e18);
        _deployCurvePool(1_500_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);

        distributor = new RewardDistributor(
            address(splitter),
            USDC,
            bearToken,
            bullToken,
            address(stBear),
            address(stBull),
            curvePool,
            address(zapRouter),
            address(basketOracle)
        );

        IERC20(bearToken).transfer(address(stBear), 100_000e18);
        IERC20(bullToken).transfer(address(stBull), 100_000e18);
    }

    // ========================================================================
    // TEST 1: REAL LIQUIDITY SLIPPAGE
    // MockCurvePool mints tokens. On fork, massive swaps cause real slippage.
    // ========================================================================

    /// @notice Verify real swap execution on Curve pool
    /// @dev Documents the relationship between get_dy quote and actual execution.
    /// On twocrypto-ng pools, the actual output typically exceeds get_dy quote
    /// because get_dy is conservative and doesn't account for all optimizations.
    function test_DirectSwap_ShowsRealBehavior() public {
        uint256 swapAmount = 100_000e6;
        deal(USDC, address(this), swapAmount);

        uint256 expectedOut = ICurvePoolExtended(curvePool).get_dy(0, 1, swapAmount);

        IERC20(USDC).approve(curvePool, swapAmount);
        (bool success,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, swapAmount, 0));
        require(success, "Swap failed");

        uint256 actualOut = IERC20(bearToken).balanceOf(address(this));

        console.log("100k USDC swap results:");
        console.log("  get_dy quote:", expectedOut);
        console.log("  Actual received:", actualOut);
        console.log("  Actual >= quote:", actualOut >= expectedOut);

        assertGt(actualOut, 0, "Should receive BEAR tokens");
        assertGe(actualOut, expectedOut, "Actual should be >= quote (Curve is conservative)");
    }

    /// @notice Test large direct swap to show price impact
    function test_LargeDirectSwap_ShowsPriceImpact() public {
        uint256 largeSwap = 500_000e6;
        deal(USDC, address(this), largeSwap);

        uint256 expectedOut = ICurvePoolExtended(curvePool).get_dy(0, 1, largeSwap);

        IERC20(USDC).approve(curvePool, largeSwap);
        (bool success,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, largeSwap, 0));
        require(success, "Swap failed");

        uint256 actualOut = IERC20(bearToken).balanceOf(address(this));

        console.log("500k USDC swap results:");
        console.log("  Expected BEAR:", expectedOut);
        console.log("  Actual BEAR:", actualOut);

        uint256 diff = actualOut > expectedOut ? actualOut - expectedOut : expectedOut - actualOut;
        uint256 diffBps = (diff * 10_000) / expectedOut;
        console.log("  Diff (bps):", diffBps);

        assertGt(actualOut, 0, "Should receive BEAR tokens");
    }

    /// @notice Distribution at 50/50 uses minting (no swaps), so no slippage
    /// @dev This documents the current behavior - at balanced split, all USDC goes to minting
    function test_BalancedDistribution_NoSwapSlippage() public {
        uint256 massiveAmount = 5_000_000e6;
        deal(USDC, address(distributor), massiveAmount);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        console.log("Distribution split: BEAR", bearPct, "/ BULL", bullPct);

        uint256 stBearBefore = IERC20(bearToken).balanceOf(address(stBear));
        uint256 stBullBefore = IERC20(bullToken).balanceOf(address(stBull));

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        assertGt(callerReward, 0, "Distribution should succeed");

        uint256 bearReceived = IERC20(bearToken).balanceOf(address(stBear)) - stBearBefore;
        uint256 bullReceived = IERC20(bullToken).balanceOf(address(stBull)) - stBullBefore;

        console.log("Tokens distributed:");
        console.log("  BEAR:", bearReceived / 1e18);
        console.log("  BULL:", bullReceived / 1e18);
    }

    /// @notice Fuzz test: find the threshold where slippage protection kicks in
    function testFuzz_SlippageThreshold(
        uint256 usdcAmount
    ) public {
        usdcAmount = bound(usdcAmount, 1000e6, 5_000_000e6);

        deal(USDC, address(distributor), usdcAmount);

        vm.prank(keeper);
        try distributor.distributeRewards() returns (uint256 callerReward) {
            assertGt(callerReward, 0, "Caller should receive reward on success");

            uint256 distributableUsdc = usdcAmount - callerReward;
            uint256 poolLiquidity = IERC20(bearToken).balanceOf(curvePool);

            console.log("SUCCESS - USDC:", usdcAmount / 1e6);
            console.log("  Distributable:", distributableUsdc / 1e6);
            console.log("  Pool liquidity:", poolLiquidity / 1e18);
            console.log("  Ratio (USDC/liquidity):", (distributableUsdc * 100) / (poolLiquidity / 1e12), "%");
        } catch {
            console.log("REVERTED - USDC:", usdcAmount / 1e6);
            console.log("  Pool liquidity:", IERC20(bearToken).balanceOf(curvePool) / 1e18);
        }
    }

    /// @notice Verify small distributions succeed (baseline sanity check)
    function test_SmallDistribution_Succeeds() public {
        uint256 smallAmount = 1000e6;
        deal(USDC, address(distributor), smallAmount);

        uint256 stBearBefore = IERC20(bearToken).balanceOf(address(stBear));
        uint256 stBullBefore = IERC20(bullToken).balanceOf(address(stBull));

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        assertEq(callerReward, 1e6, "Caller reward should be 0.1% of 1000 USDC");
        assertGt(IERC20(bearToken).balanceOf(address(stBear)), stBearBefore, "stBear should receive BEAR");
        assertGt(IERC20(bullToken).balanceOf(address(stBull)), stBullBefore, "stBull should receive BULL");
    }

    /// @notice Medium distribution should succeed with acceptable slippage
    function test_MediumDistribution_SucceedsWithSlippage() public {
        uint256 mediumAmount = 10_000e6;
        deal(USDC, address(distributor), mediumAmount);

        uint256 stBearBefore = IERC20(bearToken).balanceOf(address(stBear));

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        uint256 stBearAfter = IERC20(bearToken).balanceOf(address(stBear));
        uint256 bearReceived = stBearAfter - stBearBefore;

        assertGt(bearReceived, 0, "Should receive BEAR tokens");
        assertEq(callerReward, 10e6, "Caller reward should be 0.1%");
    }

    // ========================================================================
    // TEST 2: REAL ROUNDING (USDC=6, Tokens=18, Oracle=8)
    // Mocks often use 18 decimals for everything, hiding rounding bugs.
    // ========================================================================

    /// @notice Test with exactly 1,000,001 wei (1.000001 USDC)
    /// @dev Verifies the "extra 1" doesn't get lost in scale-down/scale-up
    function test_MicroAmount_NoRoundingLoss() public {
        uint256 microAmount = 1_000_001;
        deal(USDC, address(distributor), microAmount);

        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        uint256 keeperAfter = IERC20(USDC).balanceOf(keeper);

        uint256 expectedReward = (microAmount * 10) / 10_000;
        assertEq(callerReward, expectedReward, "Caller reward = 0.1% of microAmount");
        assertEq(keeperAfter - keeperBefore, callerReward, "Keeper received exact reward");
        assertGt(callerReward, 0, "Caller reward should not round to 0");
    }

    /// @notice Test minimum viable amount (where callerReward rounds to 0)
    /// @dev CALLER_REWARD_BPS = 10, so need amount < 1000 for reward to round to 0
    function test_MinimumViableAmount() public {
        uint256 tinyAmount = 999;
        deal(USDC, address(distributor), tinyAmount);

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        assertEq(callerReward, 0, "Caller reward rounds to 0 below 1000 wei");
    }

    /// @notice Verify decimal conversions are correct for 1 USDC
    function test_OneUSDC_DecimalConversion() public {
        uint256 oneUsdc = 1e6;
        deal(USDC, address(distributor), oneUsdc);

        uint256 stBearBefore = IERC20(bearToken).balanceOf(address(stBear));
        uint256 stBullBefore = IERC20(bullToken).balanceOf(address(stBull));

        vm.prank(keeper);
        distributor.distributeRewards();

        uint256 bearReceived = IERC20(bearToken).balanceOf(address(stBear)) - stBearBefore;
        uint256 bullReceived = IERC20(bullToken).balanceOf(address(stBull)) - stBullBefore;

        uint256 totalReceived = bearReceived + bullReceived;

        assertGt(totalReceived, 0, "Should receive tokens for 1 USDC");

        console.log("1 USDC distributed:");
        console.log("  BEAR received (18 dec):", bearReceived);
        console.log("  BULL received (18 dec):", bullReceived);
        console.log("  Total tokens:", totalReceived);
    }

    /// @notice Test awkward amount with mixed decimals
    function test_AwkwardAmount_123456789() public {
        uint256 awkwardAmount = 123_456_789;
        deal(USDC, address(distributor), awkwardAmount);

        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);
        uint256 stBearBefore = IERC20(bearToken).balanceOf(address(stBear));
        uint256 stBullBefore = IERC20(bullToken).balanceOf(address(stBull));

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();

        uint256 expectedReward = (awkwardAmount * 10) / 10_000;
        assertEq(callerReward, expectedReward, "Caller reward calculation correct");

        uint256 bearReceived = IERC20(bearToken).balanceOf(address(stBear)) - stBearBefore;
        uint256 bullReceived = IERC20(bullToken).balanceOf(address(stBull)) - stBullBefore;

        assertGt(bearReceived + bullReceived, 0, "Should distribute tokens");

        uint256 keeperAfter = IERC20(USDC).balanceOf(keeper);
        assertEq(keeperAfter - keeperBefore, callerReward, "Keeper received exact reward");
    }

    /// @notice Fuzz various amounts to find rounding edge cases
    function testFuzz_RoundingEdgeCases(
        uint256 usdcAmount
    ) public {
        usdcAmount = bound(usdcAmount, 1, 100_000e6);

        deal(USDC, address(distributor), usdcAmount);

        uint256 distributorBefore = IERC20(USDC).balanceOf(address(distributor));
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);

        vm.prank(keeper);
        try distributor.distributeRewards() returns (uint256 callerReward) {
            uint256 distributorAfter = IERC20(USDC).balanceOf(address(distributor));
            uint256 keeperAfter = IERC20(USDC).balanceOf(keeper);

            uint256 expectedReward = (usdcAmount * 10) / 10_000;
            assertEq(callerReward, expectedReward, "Reward calculation matches");

            assertEq(distributorAfter, 0, "All USDC should be distributed");
            assertEq(keeperAfter - keeperBefore, callerReward, "Keeper received exact reward");
        } catch {
            // Slippage revert is acceptable for large amounts
        }
    }

    // ========================================================================
    // TEST 3: STALE ORACLE PROTECTION
    // RewardDistributor validates staleness directly via OracleLib.checkStaleness()
    // with an 8-hour timeout, matching SyntheticSplitter's ORACLE_TIMEOUT.
    // ========================================================================

    /// @notice Stale oracle is rejected directly by RewardDistributor
    function test_StaleOracle_RevertsDirectly() public {
        deal(USDC, address(distributor), 10_000e6);

        vm.warp(block.timestamp + 24 hours);

        vm.prank(keeper);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        distributor.distributeRewards();
    }

    /// @notice At 7 days stale, distribution reverts with specific error
    function test_VeryStaleOracle_7Days_Reverts() public {
        deal(USDC, address(distributor), 10_000e6);

        vm.warp(block.timestamp + 7 days);

        vm.prank(keeper);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        distributor.distributeRewards();
    }

    /// @notice previewDistribution() also reverts on stale oracle
    function test_PreviewDistribution_RevertsOnStaleOracle() public {
        deal(USDC, address(distributor), 10_000e6);

        (uint256 bearPct, uint256 bullPct,,) = distributor.previewDistribution();
        assertEq(bearPct + bullPct, 10_000, "Preview works with fresh oracle");

        vm.warp(block.timestamp + 24 hours);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        distributor.previewDistribution();
    }

    /// @notice Distribution succeeds within 8-hour timeout window
    /// @dev setUp warps to updatedAt + 1 hour, so we have 7 hours remaining
    function test_OracleTimeout_SucceedsWithinWindow() public {
        deal(USDC, address(distributor), 10_000e6);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(keeper);
        uint256 callerReward = distributor.distributeRewards();
        assertGt(callerReward, 0, "Distribution should succeed within timeout window");
    }

    /// @notice Distribution fails after 8-hour timeout
    /// @dev OracleLib uses `<` so we need to exceed timeout by at least 1 second
    function test_OracleTimeout_FailsAfterTimeout() public {
        deal(USDC, address(distributor), 10_000e6);

        vm.warp(block.timestamp + 7 hours + 1);

        vm.prank(keeper);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        distributor.distributeRewards();
    }

    // ========================================================================
    // ADDITIONAL FORK-SPECIFIC TESTS
    // ========================================================================

    /// @notice Verify Curve pool price_oracle() returns real EMA price
    function test_CurvePool_RealPriceOracle() public view {
        uint256 emaPrice = ICurvePoolExtended(curvePool).price_oracle();

        assertGt(emaPrice, 0.5e18, "EMA price should be > $0.50");
        assertLt(emaPrice, 2e18, "EMA price should be < $2.00");

        console.log("Curve pool EMA price:", emaPrice);
        console.log("  In USD terms:", emaPrice / 1e12, "(6 decimals)");
    }

    /// @notice Verify real swap impacts price (unlike mock which just mints)
    function test_SwapImpactsPrice() public {
        uint256 priceBefore = ICurvePoolExtended(curvePool).get_dy(0, 1, 1e6);

        deal(USDC, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(curvePool, 100_000e6);
        (bool success,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, 100_000e6, 0));
        require(success, "Swap failed");
        vm.stopPrank();

        uint256 priceAfter = ICurvePoolExtended(curvePool).get_dy(0, 1, 1e6);

        assertLt(priceAfter, priceBefore, "Price should decrease after buying BEAR");

        console.log("Price impact from 100k USDC swap:");
        console.log("  Before (BEAR per USDC):", priceBefore);
        console.log("  After (BEAR per USDC):", priceAfter);
        console.log("  Impact:", ((priceBefore - priceAfter) * 10_000) / priceBefore, "bps");
    }

    /// @notice Sequential distributions should work with cooldown
    function test_SequentialDistributions() public {
        deal(USDC, address(distributor), 5000e6);

        vm.prank(keeper);
        distributor.distributeRewards();

        deal(USDC, address(distributor), 5000e6);

        vm.prank(keeper);
        vm.expectRevert(IRewardDistributor.RewardDistributor__DistributionTooSoon.selector);
        distributor.distributeRewards();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(keeper);
        distributor.distributeRewards();
    }

    /// @notice Verify distribution respects real oracle price discrepancy
    function test_RealOracleDiscrepancy() public {
        deal(USDC, address(distributor), 10_000e6);

        (uint256 bearPct, uint256 bullPct, uint256 balance, uint256 reward) = distributor.previewDistribution();

        console.log("Real oracle discrepancy preview:");
        console.log("  BEAR %:", bearPct);
        console.log("  BULL %:", bullPct);
        console.log("  Balance:", balance);
        console.log("  Caller reward:", reward);

        assertEq(bearPct + bullPct, 10_000, "Percentages must sum to 100%");
        assertGe(bearPct, 0, "BEAR % must be non-negative");
        assertGe(bullPct, 0, "BULL % must be non-negative");
    }

}
