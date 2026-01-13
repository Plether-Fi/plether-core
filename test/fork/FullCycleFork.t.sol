// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IMorpho} from "../../src/interfaces/IMorpho.sol";
import {BaseForkTest, MockCurvePoolForOracle, MockMorphoOracleForYield} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title Full Cycle Fork Tests
/// @notice Tests complete protocol lifecycle: Mint -> Yield -> Burn
contract FullCycleForkTest is BaseForkTest {

    address treasury;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address borrower = address(0xB0BB0B);

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");

        deal(USDC, alice, 100_000e6);
        deal(USDC, bob, 100_000e6);
        deal(WETH, borrower, 1000 ether);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
    }

    /// @notice Helper to simulate yield by creating borrowers and accruing interest
    /// @param utilizationPercent Percentage of supplied assets to borrow (1-100)
    function _simulateYield(
        uint256 utilizationPercent
    ) internal {
        uint256 adapterAssets = yieldAdapter.totalAssets();
        require(adapterAssets > 0, "_simulateYield: adapter has no assets");

        uint256 borrowAmount = (adapterAssets * utilizationPercent) / 100;
        require(borrowAmount > 0, "_simulateYield: borrow amount is 0");

        // Borrower supplies WETH collateral and borrows USDC
        vm.startPrank(borrower);
        IERC20(WETH).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).supplyCollateral(yieldMarketParams, 500 ether, borrower, "");
        IMorpho(MORPHO).borrow(yieldMarketParams, borrowAmount, 0, borrower, borrower);
        vm.stopPrank();

        // Warp time forward to accrue significant interest (simulates ~10% APY for 1 year)
        vm.warp(block.timestamp + 365 days);

        // Accrue interest
        IMorpho(MORPHO).accrueInterest(yieldMarketParams);

        // Repay the loan to restore liquidity for burns
        bytes32 marketId = keccak256(abi.encode(yieldMarketParams));
        (, uint128 borrowShares,) = IMorpho(MORPHO).position(marketId, borrower);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtWithInterest = totalBorrowShares > 0
            ? (uint256(borrowShares) * uint256(totalBorrowAssets) + totalBorrowShares - 1) / uint256(totalBorrowShares)
                + 1
            : 0;

        deal(USDC, borrower, debtWithInterest + 1000);

        vm.startPrank(borrower);
        IERC20(USDC).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).repay(yieldMarketParams, 0, borrowShares, borrower, "");
        vm.stopPrank();
    }

    function test_FullCycle_MintYieldBurn() public {
        uint256 mintAmount = 10_000e18;
        uint256 usdcRequired;
        uint256 usdcReturned;

        // PHASE 1: MINT
        {
            console.log("=== PHASE 1: MINT ===");
            vm.startPrank(alice);
            (usdcRequired,,) = splitter.previewMint(mintAmount);
            console.log("USDC Required for mint:", usdcRequired);
            IERC20(USDC).approve(address(splitter), usdcRequired);
            splitter.mint(mintAmount);
            vm.stopPrank();

            assertEq(IERC20(bullToken).balanceOf(alice), mintAmount, "Alice should have BULL tokens");
            assertEq(IERC20(bearToken).balanceOf(alice), mintAmount, "Alice should have BEAR tokens");
        }

        // PHASE 2: SIMULATE YIELD
        uint256 adapterAssetsBefore;
        {
            console.log("\n=== PHASE 2: SIMULATE YIELD ===");
            uint256 adapterShares = yieldAdapter.balanceOf(address(splitter));
            adapterAssetsBefore = yieldAdapter.convertToAssets(adapterShares);
            _simulateYield(50);
            console.log("Yield simulation complete");
        }

        // PHASE 3: HARVEST YIELD
        {
            console.log("\n=== PHASE 3: HARVEST YIELD ===");
            uint256 adapterShares = yieldAdapter.balanceOf(address(splitter));
            uint256 adapterAssetsAfter = yieldAdapter.convertToAssets(adapterShares);
            if (adapterAssetsAfter > adapterAssetsBefore + 50e6) {
                splitter.harvestYield();
            }
        }

        // PHASE 4: BURN TOKENS
        {
            console.log("\n=== PHASE 4: BURN ===");
            uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

            vm.startPrank(alice);
            IERC20(bullToken).approve(address(splitter), mintAmount);
            IERC20(bearToken).approve(address(splitter), mintAmount);
            splitter.burn(mintAmount);
            vm.stopPrank();

            usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
            console.log("USDC returned from burn:", usdcReturned);

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
            _simulateYield(50);
            uint256 assetsAfter = yieldAdapter.totalAssets();
            if (assetsAfter > assetsBefore + 50e6) {
                splitter.harvestYield();
            }
        }

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
        uint256 adapterAssetsBefore;
        uint256 returned;

        // PHASE 1: MINT
        {
            vm.startPrank(alice);
            (usdcRequired,,) = splitter.previewMint(mintAmount);
            IERC20(USDC).approve(address(splitter), usdcRequired);
            splitter.mint(mintAmount);
            vm.stopPrank();
        }

        // PHASE 2: CREATE BORROWER POSITION
        {
            adapterAssetsBefore = yieldAdapter.totalAssets();
            uint256 borrowAmount = adapterAssetsBefore / 2;

            vm.startPrank(borrower);
            IERC20(WETH).approve(MORPHO, type(uint256).max);
            IMorpho(MORPHO).supplyCollateral(yieldMarketParams, 500 ether, borrower, "");
            IMorpho(MORPHO).borrow(yieldMarketParams, borrowAmount, 0, borrower, borrower);
            vm.stopPrank();
        }

        // PHASE 3: SIMULATE 4 QUARTERS OF YIELD
        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(block.timestamp + 90 days);
            IMorpho(MORPHO).accrueInterest(yieldMarketParams);

            uint256 adapterAssetsNow = yieldAdapter.totalAssets();

            uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
            try splitter.harvestYield() {
                uint256 harvested = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
                totalHarvested += harvested;
                adapterAssetsBefore = yieldAdapter.totalAssets();
            } catch {}
        }

        require(totalHarvested > 0, "Yield simulation failed: no yield harvested");

        // PHASE 4: REPAY LOAN
        {
            bytes32 marketId = keccak256(abi.encode(yieldMarketParams));
            (, uint128 borrowShares,) = IMorpho(MORPHO).position(marketId, borrower);
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
            uint256 debtWithInterest = totalBorrowShares > 0
                ? (uint256(borrowShares) * uint256(totalBorrowAssets) + totalBorrowShares - 1)
                    / uint256(totalBorrowShares) + 1
                : 0;

            deal(USDC, borrower, debtWithInterest + 1000);
            vm.startPrank(borrower);
            IERC20(USDC).approve(MORPHO, type(uint256).max);
            IMorpho(MORPHO).repay(yieldMarketParams, 0, borrowShares, borrower, "");
            vm.stopPrank();
        }

        // PHASE 5: FINAL BURN
        {
            uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

            vm.startPrank(alice);
            IERC20(bullToken).approve(address(splitter), mintAmount);
            IERC20(bearToken).approve(address(splitter), mintAmount);
            splitter.burn(mintAmount);
            vm.stopPrank();

            returned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        }

        assertGt(returned, (usdcRequired * 98) / 100, "Should return >98% of deposit");
    }

}
