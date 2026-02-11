// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BaseForkTest, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title Full Cycle Fork Tests
/// @notice Tests complete protocol lifecycle: Mint -> Yield -> Burn
contract FullCycleForkTest is BaseForkTest {

    address treasury;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");

        deal(USDC, alice, 100_000e6);
        deal(USDC, bob, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
    }

    /// @notice Warp forward and refresh Chainlink mock so oracle stays valid
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

    function test_FullCycle_MintYieldBurn() public {
        uint256 mintAmount = 10_000e18;
        uint256 usdcRequired;
        uint256 usdcReturned;

        // PHASE 1: MINT
        {
            vm.startPrank(alice);
            (usdcRequired,,) = splitter.previewMint(mintAmount);
            IERC20(USDC).approve(address(splitter), usdcRequired);
            splitter.mint(mintAmount);
            vm.stopPrank();

            assertEq(IERC20(bullToken).balanceOf(alice), mintAmount, "Alice should have BULL tokens");
            assertEq(IERC20(bearToken).balanceOf(alice), mintAmount, "Alice should have BEAR tokens");
        }

        // PHASE 2: YIELD ACCRUAL (Morpho vault accrues internally over time)
        uint256 adapterAssetsBefore = yieldAdapter.totalAssets();
        _warpAndRefreshOracle(30 days);
        uint256 adapterAssetsAfter = yieldAdapter.totalAssets();

        // PHASE 3: HARVEST YIELD
        if (adapterAssetsAfter > adapterAssetsBefore + 50e6) {
            splitter.harvestYield();
        }

        // Seed dust for nested ERC4626 rounding
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        // PHASE 4: BURN TOKENS
        {
            uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

            vm.startPrank(alice);
            IERC20(bullToken).approve(address(splitter), mintAmount);
            IERC20(bearToken).approve(address(splitter), mintAmount);
            splitter.burn(mintAmount);
            vm.stopPrank();

            usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;

            assertEq(IERC20(bullToken).balanceOf(alice), 0, "Alice should have no BULL tokens");
            assertEq(IERC20(bearToken).balanceOf(alice), 0, "Alice should have no BEAR tokens");
        }

        assertGt(usdcReturned, (usdcRequired * 99) / 100, "Should return ~100% of original USDC");
    }

    function test_FullCycle_MultipleUsers() public {
        uint256 aliceMint = 5000e18;
        uint256 bobMint = 10_000e18;
        uint256 aliceUsdc;
        uint256 bobUsdc;
        uint256 aliceReturned;
        uint256 bobReturned;

        // PHASE 1: MULTIPLE MINTS
        {
            vm.startPrank(alice);
            (aliceUsdc,,) = splitter.previewMint(aliceMint);
            IERC20(USDC).approve(address(splitter), aliceUsdc);
            splitter.mint(aliceMint);
            vm.stopPrank();

            vm.startPrank(bob);
            (bobUsdc,,) = splitter.previewMint(bobMint);
            IERC20(USDC).approve(address(splitter), bobUsdc);
            splitter.mint(bobMint);
            vm.stopPrank();
        }

        // PHASE 2: YIELD ACCRUAL
        {
            uint256 assetsBefore = yieldAdapter.totalAssets();
            _warpAndRefreshOracle(30 days);
            uint256 assetsAfter = yieldAdapter.totalAssets();
            if (assetsAfter > assetsBefore + 50e6) {
                splitter.harvestYield();
            }
        }

        // Seed dust for nested ERC4626 rounding
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        // PHASE 3: ALICE BURNS
        {
            uint256 before = IERC20(USDC).balanceOf(alice);
            vm.startPrank(alice);
            IERC20(bullToken).approve(address(splitter), aliceMint);
            IERC20(bearToken).approve(address(splitter), aliceMint);
            splitter.burn(aliceMint);
            vm.stopPrank();
            aliceReturned = IERC20(USDC).balanceOf(alice) - before;
        }

        // PHASE 4: BOB BURNS
        {
            uint256 before = IERC20(USDC).balanceOf(bob);
            vm.startPrank(bob);
            IERC20(bullToken).approve(address(splitter), bobMint);
            IERC20(bearToken).approve(address(splitter), bobMint);
            splitter.burn(bobMint);
            vm.stopPrank();
            bobReturned = IERC20(USDC).balanceOf(bob) - before;
        }

        assertEq(IERC20(bullToken).balanceOf(alice), 0, "Alice BULL should be 0");
        assertEq(IERC20(bearToken).balanceOf(alice), 0, "Alice BEAR should be 0");
        assertEq(IERC20(bullToken).balanceOf(bob), 0, "Bob BULL should be 0");
        assertEq(IERC20(bearToken).balanceOf(bob), 0, "Bob BEAR should be 0");

        assertGt(aliceReturned, (aliceUsdc * 99) / 100, "Alice should get ~100% back");
        assertGt(bobReturned, (bobUsdc * 99) / 100, "Bob should get ~100% back");
    }

    function test_FullCycle_MultipleHarvests() public {
        uint256 mintAmount = 50_000e18;
        uint256 usdcRequired;
        uint256 totalHarvested = 0;
        uint256 returned;

        // PHASE 1: MINT
        {
            vm.startPrank(alice);
            (usdcRequired,,) = splitter.previewMint(mintAmount);
            IERC20(USDC).approve(address(splitter), usdcRequired);
            splitter.mint(mintAmount);
            vm.stopPrank();
        }

        // PHASE 2: SIMULATE 4 QUARTERS OF YIELD
        for (uint256 i = 1; i <= 4; i++) {
            _warpAndRefreshOracle(90 days);

            uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
            try splitter.harvestYield() {
                uint256 harvested = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
                totalHarvested += harvested;
            } catch {}
        }

        require(totalHarvested > 0, "Yield simulation failed: no yield harvested");

        // Seed dust for nested ERC4626 rounding
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        // PHASE 3: FINAL BURN
        {
            uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

            vm.startPrank(alice);
            IERC20(bullToken).approve(address(splitter), mintAmount);
            IERC20(bearToken).approve(address(splitter), mintAmount);
            splitter.burn(mintAmount);
            vm.stopPrank();

            returned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        }

        assertGt(returned, (usdcRequired * 99) / 100, "Should return >99% of deposit");
    }

}
