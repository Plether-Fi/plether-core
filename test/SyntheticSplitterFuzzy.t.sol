// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAToken, MockERC20, MockPool} from "./utils/MockAave.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {MockYieldAdapter} from "./utils/MockYieldAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console} from "forge-std/Test.sol";

contract SyntheticSplitterFuzzTest is Test {

    SyntheticSplitter splitter;
    MockYieldAdapter adapter;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;
    MockOracle sequencer;

    address alice = address(0x1);
    address treasury = address(0x999);

    uint256 constant CAP = 200_000_000; // $2.00
    uint256 constant MAX_MINT_AMOUNT = 1_000_000_000 * 1e18;

    function setUp() public {
        vm.warp(1_735_689_600);

        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc));
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket");
        sequencer = new MockOracle(0, "Sequencer");

        usdc.mint(address(pool), 10_000_000_000 * 1e6);

        // Predict Splitter address before deploying Adapter
        uint64 nonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), nonce + 1);

        adapter = new MockYieldAdapter(IERC20(address(usdc)), address(this), predictedSplitter);

        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));

        require(address(splitter) == predictedSplitter, "Address prediction failed");

        // Satisfy Sequencer Grace Period
        vm.warp(block.timestamp + 3601);
    }

    function testFuzz_Mint_MaintainsSolvency(
        uint256 amount
    ) public {
        amount = bound(amount, 0.01 ether, MAX_MINT_AMOUNT);

        (uint256 usdcNeeded,,) = splitter.previewMint(amount);
        usdc.mint(alice, usdcNeeded + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(amount);
        vm.stopPrank();

        uint256 totalLiabilities = (splitter.BEAR().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
        uint256 localBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterAssets = adapter.convertToAssets(adapter.balanceOf(address(splitter)));
        uint256 totalAssets = localBuffer + adapterAssets;

        assertGe(totalAssets, totalLiabilities, "Solvency Broken");
    }

    /// @notice Verify that users pay at least fair price (catches rounding exploits)
    /// @dev Uses small amounts where rounding has maximum impact
    function testFuzz_Mint_UserPaysFairPrice(
        uint256 amount
    ) public {
        // Use smaller range to maximize rounding impact
        amount = bound(amount, 1e15, 1e20);

        // Get expected cost from preview function
        (uint256 usdcExpected,,) = splitter.previewMint(amount);

        usdc.mint(alice, usdcExpected + 1e6);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(amount);
        vm.stopPrank();

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 actualPaid = aliceBalanceBefore - aliceBalanceAfter;

        // User should pay exactly what preview said
        assertEq(actualPaid, usdcExpected, "Should pay preview amount");

        // Verify security property: user pays at least fair value (ceiling rounding)
        assertGe(
            actualPaid * splitter.USDC_MULTIPLIER(), amount * CAP, "ROUNDING EXPLOIT: User paid less than fair price"
        );
    }

    /// @notice Fuzz test with edge-case amounts designed to maximize rounding benefit
    function testFuzz_Mint_EdgeCaseAmounts(
        uint256 multiplier
    ) public {
        // Generate amounts just below clean USDC boundaries
        multiplier = bound(multiplier, 1, 1000);

        uint256 usdcMultiplier = splitter.USDC_MULTIPLIER();
        // Amount that costs exactly `multiplier` USDC
        uint256 exactAmount = (multiplier * usdcMultiplier) / CAP;
        // Amount just below the next USDC (maximizes rounding benefit)
        uint256 exploitAmount = exactAmount + (usdcMultiplier / CAP) - 1;

        if (exploitAmount == 0) {
            return;
        }

        // Get expected cost from preview function
        (uint256 expectedPrice,,) = splitter.previewMint(exploitAmount);
        usdc.mint(alice, expectedPrice + 1e6);
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(exploitAmount);
        vm.stopPrank();

        uint256 actualPaid = balanceBefore - usdc.balanceOf(alice);

        // User should pay exactly what preview said
        assertEq(actualPaid, expectedPrice, "Should pay preview amount");

        // Verify security property: user pays at least fair value
        assertGe(actualPaid * usdcMultiplier, exploitAmount * CAP, "ROUNDING EXPLOIT: Edge case amount exploited");
    }

    function testFuzz_MintBurn_TokenParity(
        uint256 mintAmount,
        uint256 burnAmount
    ) public {
        mintAmount = bound(mintAmount, 1 ether, MAX_MINT_AMOUNT);

        // Minimum burn amount for non-zero USDC refund: USDC_MULTIPLIER / CAP = 5e11
        uint256 minBurnForRefund = splitter.USDC_MULTIPLIER() / CAP;
        burnAmount = bound(burnAmount, minBurnForRefund, mintAmount);

        (uint256 cost,,) = splitter.previewMint(mintAmount);
        usdc.mint(alice, cost + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);

        splitter.burn(burnAmount);
        vm.stopPrank();

        assertEq(splitter.BEAR().totalSupply(), splitter.BULL().totalSupply(), "Token Parity Broken");
    }

    function testFuzz_BurnWhilePaused_IfSolvent(
        uint256 amount
    ) public {
        amount = bound(amount, 1 ether, MAX_MINT_AMOUNT);

        (uint256 cost,,) = splitter.previewMint(amount);
        usdc.mint(alice, cost + 1e6);
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(amount);
        vm.stopPrank();

        splitter.pause();

        vm.startPrank(alice);
        splitter.burn(amount);
        vm.stopPrank();

        assertEq(splitter.BEAR().balanceOf(alice), 0);
    }

    function testFuzz_HarvestMath(
        uint96 poolLiquidity,
        uint96 yieldAmount
    ) public {
        // Constrain inputs
        uint256 poolSize = bound(uint256(poolLiquidity), 100 * 1e6, 100_000_000_000 * 1e6);
        uint256 yield = bound(uint256(yieldAmount), 1 * 1e6, poolSize * 2);
        uint256 mintAmt = 10_000 * 1e18;
        (uint256 cost,,) = splitter.previewMint(mintAmt);
        usdc.mint(alice, cost + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), cost + 1e6);
        splitter.mint(mintAmt);
        vm.stopPrank();
        // Simulate Whale
        usdc.mint(address(pool), poolSize);
        aUsdc.mint(address(this), poolSize);
        // Inject Yield
        aUsdc.mint(address(adapter), yield);
        usdc.mint(address(pool), yield);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 callerBefore = usdc.balanceOf(address(this));

        try splitter.harvestYield() {
            uint256 callerReward = usdc.balanceOf(address(this)) - callerBefore;
            uint256 treasuryReward = usdc.balanceOf(treasury) - treasuryBefore;

            assertGt(callerReward, 0, "Caller should receive reward on success");
            assertGt(treasuryReward, 0, "Treasury should receive reward on success");
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == SyntheticSplitter.Splitter__NoSurplus.selector) {
                return;
            }
            if (reason.length >= 4 && bytes4(reason) == SyntheticSplitter.Splitter__InsufficientHarvest.selector) {
                return;
            }
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

}
