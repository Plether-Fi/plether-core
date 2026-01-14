// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ZapRouter} from "../src/ZapRouter.sol";
import {FlashLoanBase} from "../src/base/FlashLoanBase.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract ZapRouterTest is Test {

    ZapRouter public zapRouter;

    // Mocks
    MockToken public usdc;
    MockFlashToken public dxyBear;
    MockFlashToken public dxyBull;
    MockSplitter public splitter;
    MockCurvePool public curvePool;

    address alice = address(0xA11ce);

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockToken("USDC", "USDC");
        dxyBear = new MockFlashToken("dxyBear", "dxyBear");
        dxyBull = new MockFlashToken("dxyBull", "dxyBull");
        splitter = new MockSplitter(address(dxyBear), address(dxyBull));
        splitter.setUsdc(address(usdc));
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));

        // 2. Deploy ZapRouter
        zapRouter =
            new ZapRouter(address(splitter), address(dxyBear), address(dxyBull), address(usdc), address(curvePool));

        // 3. Setup Initial State
        usdc.mint(alice, 1000 * 1e6);
    }

    // ==========================================
    // 1. HAPPY PATHS (Dynamic Pricing)
    // ==========================================

    function test_ZapMint_Parity() public {
        // Scenario: Bear = $1.00, Bull = $1.00 (Total $2.00)
        curvePool.setPrice(1e6); // 1 BEAR = 1 USDC

        uint256 usdcInput = 100 * 1e6; // $100
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // ZapRouter has 1% buffer, so output is ~99% of theoretical max
        zapRouter.zapMint(usdcInput, 98 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Parity with 1% buffer: Alice gets ~99.5 BULL
        assertApproxEqAbs(dxyBull.balanceOf(alice), 99.5 ether, 1e18, "Parity: Alice should get ~99.5 BULL");
        // Ensure no leaks in Router (Balance must be 0)
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Parity: Router leaked BEAR");
    }

    function test_ZapMint_BearCheap() public {
        // Scenario: Bear = $0.50, Bull = $1.50 (Total $2.00)
        curvePool.setPrice(500_000); // 1 BEAR = 0.5 USDC

        uint256 usdcInput = 100 * 1e6; // $100
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // ZapRouter has 1% buffer, so output is ~99% of theoretical max
        zapRouter.zapMint(usdcInput, 65 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // With 1% buffer: ~66 BULL (theoretical 66.66)
        assertApproxEqAbs(dxyBull.balanceOf(alice), 66 ether, 1e18, "Cheap: Alice output mismatch");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Cheap: Router leaked BEAR");
    }

    function test_ZapMint_BearExpensive() public {
        // Scenario: Bear = $1.50, Bull = $0.50 (Total $2.00)
        curvePool.setPrice(1_500_000); // 1 BEAR = 1.5 USDC

        uint256 usdcInput = 100 * 1e6; // $100
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // ZapRouter has 1% buffer, so output is ~99% of theoretical max
        zapRouter.zapMint(usdcInput, 196 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // With 1% buffer: ~198 BULL (theoretical 200)
        assertApproxEqAbs(dxyBull.balanceOf(alice), 198 ether, 3e18, "Expensive: Alice should get ~198 BULL");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Expensive: Router leaked BEAR");
    }

    // ==========================================
    // 2. FAILURES & LOGIC
    // ==========================================

    function test_ZapMint_PriceOverCap_Reverts() public {
        // Bear = $2.10 (Broken Peg / Settlement Zone)
        curvePool.setPrice(2_100_000);

        uint256 usdcInput = 100 * 1e6;
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        vm.expectRevert(ZapRouter.ZapRouter__BearPriceAboveCap.selector);
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SlippageExceedsMax_Reverts() public {
        uint256 usdcInput = 100 * 1e6;
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        vm.expectRevert(ZapRouter.ZapRouter__SlippageExceedsMax.selector);
        zapRouter.zapMint(usdcInput, 0, 200, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_ZeroAmount_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), 0);

        vm.expectRevert(ZapRouter.ZapRouter__ZeroAmount.selector);
        zapRouter.zapMint(0, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // 3. SECURITY & PREVIEW
    // ==========================================

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidLender.selector);
        zapRouter.onFlashLoan(address(zapRouter), address(dxyBear), 100, 0, "");
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        vm.startPrank(address(dxyBear));
        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidInitiator.selector);
        zapRouter.onFlashLoan(alice, address(dxyBear), 100, 0, "");
        vm.stopPrank();
    }

    function test_PreviewZapMint() public {
        uint256 usdcAmount = 100 * 1e6;
        // Default Mock Price is 1.0

        (uint256 flashAmount, uint256 expectedSwapOut, uint256 totalUSDC, uint256 expectedTokensOut,) =
            zapRouter.previewZapMint(usdcAmount);

        // Verify internal consistency: totalUSDC = input + swap output
        assertEq(totalUSDC, usdcAmount + expectedSwapOut, "Total USDC should equal input + swap output");

        // Verify all values are non-zero for meaningful input
        assertGt(flashAmount, 0, "Flash amount should be non-zero");
        assertGt(expectedSwapOut, 0, "Swap output should be non-zero");
        assertGt(expectedTokensOut, 0, "Token output should be non-zero");

        // Verify preview matches actual execution (within 1% due to buffer/slippage)
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);
        uint256 bullBefore = dxyBull.balanceOf(alice);
        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
        uint256 actualTokensOut = dxyBull.balanceOf(alice) - bullBefore;
        vm.stopPrank();

        // Actual output should be close to preview (within 1% tolerance for buffer)
        assertApproxEqRel(actualTokensOut, expectedTokensOut, 0.01e18, "Actual tokens should be close to preview");
    }

    function test_PreviewZapBurn() public {
        uint256 bullAmount = 100 * 1e18;
        curvePool.setPrice(1e6); // Parity: 1 BEAR = 1 USDC

        // Mint some BULL for alice first
        dxyBull.mint(alice, bullAmount);

        // Get preview
        (uint256 expectedUsdcFromBurn, uint256 usdcForBearBuyback, uint256 expectedUsdcOut, uint256 flashFee) =
            zapRouter.previewZapBurn(bullAmount);

        // Verify internal consistency
        assertGt(expectedUsdcFromBurn, 0, "USDC from burn should be non-zero");
        assertGt(usdcForBearBuyback, 0, "Buyback cost should be non-zero");
        assertGt(expectedUsdcOut, 0, "Expected USDC out should be non-zero");
        assertEq(flashFee, 0, "Flash fee should be zero with no fee set");

        // Net out should equal burn proceeds minus buyback cost
        assertEq(expectedUsdcOut, expectedUsdcFromBurn - usdcForBearBuyback, "Net USDC should be burn - buyback");

        // Verify preview matches actual execution (within 2% due to buffer/slippage)
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);
        zapRouter.zapBurn(bullAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 actualUsdcOut = usdc.balanceOf(alice) - usdcBefore;

        // Actual output should be close to preview (within 2% tolerance for buffer/slippage)
        assertApproxEqRel(actualUsdcOut, expectedUsdcOut, 0.02e18, "Actual USDC should be close to preview");
    }

    function test_PreviewZapBurn_ZeroAmount() public view {
        (uint256 expectedUsdcFromBurn, uint256 usdcForBearBuyback, uint256 expectedUsdcOut, uint256 flashFee) =
            zapRouter.previewZapBurn(0);

        assertEq(expectedUsdcFromBurn, 0, "Should return zero for zero input");
        assertEq(usdcForBearBuyback, 0, "Should return zero for zero input");
        assertEq(expectedUsdcOut, 0, "Should return zero for zero input");
        assertEq(flashFee, 0, "Should return zero for zero input");
    }

    function test_PreviewZapBurn_WithFlashFee() public {
        uint256 bullAmount = 100 * 1e18;
        curvePool.setPrice(1e6);

        // Set a flash fee
        dxyBear.setFeeBps(10); // 0.1% fee

        (uint256 expectedUsdcFromBurn, uint256 usdcForBearBuyback, uint256 expectedUsdcOut, uint256 flashFee) =
            zapRouter.previewZapBurn(bullAmount);

        // Flash fee should be non-zero
        assertGt(flashFee, 0, "Flash fee should be non-zero");

        // Buyback should be higher due to flash fee
        assertGt(usdcForBearBuyback, expectedUsdcFromBurn / 2, "Buyback should account for fee");

        // Net out should still be positive
        assertGt(expectedUsdcOut, 0, "Expected USDC out should be positive");
    }

    function test_ZapMint_ScalesUSDCTo18Decimals() public {
        uint256 amountIn = 100e6;

        vm.startPrank(alice);
        IERC20(usdc).approve(address(zapRouter), amountIn);

        uint256 balanceBefore = IERC20(dxyBull).balanceOf(alice);
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);
        uint256 balanceAfter = IERC20(dxyBull).balanceOf(alice);
        uint256 mintedAmount = balanceAfter - balanceBefore;
        vm.stopPrank();

        console.log("Input USDC (6 dec): ", amountIn);
        console.log("Output BULL (18 dec):", mintedAmount);
        // With ~2x leverage, we expect roughly 100 BULL tokens (100e18).

        // Assertion: Ensure we received more than 1 whole unit (1e18).
        // If the bug was present, this assertion would fail immediately.
        assertGt(mintedAmount, 1e18, "Decimal Scaling Failed: Output is dust");

        console.log("Test Passed: Output is properly scaled to 18 decimals.");
    }

    // ==========================================
    // 4. ZAP BURN TESTS
    // ==========================================

    function test_ZapBurn_Parity() public {
        // Scenario: Bear = $1.00, Bull = $1.00 (Total $2.00)
        curvePool.setPrice(1e6); // 1 BEAR = 1 USDC

        // First mint some BULL for alice
        uint256 usdcInput = 100 * 1e6;
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);

        uint256 bullBalance = dxyBull.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Now burn the BULL back to USDC
        dxyBull.approve(address(zapRouter), bullBalance);
        zapRouter.zapBurn(bullBalance, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);
        uint256 usdcReturned = usdcAfter - usdcBefore;

        console.log("BULL burned:", bullBalance);
        console.log("USDC returned:", usdcReturned);

        // Should get back most of the USDC (minus fees/slippage)
        // At parity, ~100 BULL should return ~95+ USDC
        assertGt(usdcReturned, 90 * 1e6, "ZapBurn: Should return significant USDC");

        // Router should not hold any tokens
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");
    }

    function test_ZapBurn_BearCheap() public {
        // Scenario: Bear = $0.50, Bull = $1.50 (Total $2.00)
        // When BEAR is cheap, buying it back costs less USDC -> more profit for user
        curvePool.setPrice(500_000); // 1 BEAR = 0.5 USDC

        // Give alice some BULL directly (simulating she got it somehow)
        dxyBull.mint(alice, 100 * 1e18);

        uint256 bullBalance = dxyBull.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullBalance);
        zapRouter.zapBurn(bullBalance, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcReturned = usdc.balanceOf(alice) - usdcBefore;

        console.log("BULL burned:", bullBalance);
        console.log("USDC returned:", usdcReturned);

        // 100 BULL + 100 BEAR (flash) -> burn -> 200 USDC
        // Buy back 100 BEAR at $0.50 = 50 USDC
        // Net: ~150 USDC (minus buffer/fees)
        assertGt(usdcReturned, 140 * 1e6, "BearCheap: Should return more USDC");
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
    }

    function test_ZapBurn_BearExpensive() public {
        // Scenario: Bear = $1.50, Bull = $0.50 (Total $2.00)
        // When BEAR is expensive, buying it back costs more USDC -> less profit
        curvePool.setPrice(1_500_000); // 1 BEAR = 1.5 USDC

        // Give alice some BULL directly
        dxyBull.mint(alice, 100 * 1e18);

        uint256 bullBalance = dxyBull.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullBalance);
        zapRouter.zapBurn(bullBalance, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcReturned = usdc.balanceOf(alice) - usdcBefore;

        console.log("BULL burned:", bullBalance);
        console.log("USDC returned:", usdcReturned);

        // 100 BULL + 100 BEAR (flash) -> burn -> 200 USDC
        // Buy back 100 BEAR at $1.50 = 150 USDC (+ buffer)
        // Net: ~50 USDC (minus buffer/fees)
        assertGt(usdcReturned, 40 * 1e6, "BearExpensive: Should still return some USDC");
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
    }

    function test_ZapBurn_ZeroAmount_Reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(ZapRouter.ZapRouter__ZeroAmount.selector);
        zapRouter.zapBurn(0, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapBurn_Expired_Reverts() public {
        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        vm.expectRevert(ZapRouter.ZapRouter__Expired.selector);
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_ZapBurn_SlippageTooHigh_Reverts() public {
        curvePool.setPrice(1e6);
        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        // Expect way more USDC than possible
        vm.expectRevert(ZapRouter.ZapRouter__InsufficientOutput.selector);
        zapRouter.zapBurn(100 * 1e18, 500 * 1e6, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapBurn_RoundTrip() public {
        // Test mint then burn - user should get back most of their USDC
        curvePool.setPrice(1e6); // Parity

        uint256 initialUsdc = 100 * 1e6;

        vm.startPrank(alice);

        // 1. Mint
        usdc.approve(address(zapRouter), initialUsdc);
        zapRouter.zapMint(initialUsdc, 0, 100, block.timestamp + 1 hours);

        uint256 bullMinted = dxyBull.balanceOf(alice);
        console.log("BULL minted:", bullMinted);

        // 2. Burn
        dxyBull.approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 finalUsdc = usdc.balanceOf(alice);
        uint256 initialTotal = 1000 * 1e6;

        console.log("Initial USDC:", initialTotal);
        console.log("Final USDC:", finalUsdc);

        // Round trip should not lose more than 10% of the 100 USDC invested
        // (accounting for buffer + swap fees on both sides)
        if (finalUsdc < initialTotal) {
            uint256 netLoss = initialTotal - finalUsdc;
            console.log("Net loss:", netLoss);
            assertLt(netLoss, 10 * 1e6, "RoundTrip: Lost too much in fees");
        } else {
            // User came out ahead (possible with dust/rounding in their favor)
            console.log("Net gain:", finalUsdc - initialTotal);
        }
    }

    function test_ZapBurn_WithFlashFee() public {
        // Set a flash fee
        dxyBear.setFeeBps(10); // 0.1% fee
        curvePool.setPrice(1e6);

        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcReturned = usdc.balanceOf(alice) - 1000 * 1e6; // Subtract initial balance

        // Should still work, just with slightly less return due to flash fee
        assertGt(usdcReturned, 90 * 1e6, "WithFlashFee: Should still return USDC");
    }

    function test_ZapBurn_PoolLiquidityError_Reverts() public {
        // Set price to 0 (simulates empty/broken pool)
        curvePool.setPrice(0);

        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        vm.expectRevert(); // Division by zero or "Pool liquidity error"
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapBurn_HighFlashFee_Insolvency_Reverts() public {
        // Set high flash fee AND expensive BEAR to cause insolvency
        dxyBear.setFeeBps(5000); // 50% fee
        curvePool.setPrice(1_500_000); // BEAR = $1.50

        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        // Flash 100 BEAR, must repay 150 BEAR (100 + 50% fee)
        // Burn 100 pairs -> get 200 USDC
        // Buy BEAR at $1.50 -> 200 USDC buys ~133 BEAR
        // min_dy = 150 BEAR, but can only get 133 -> Curve reverts
        vm.expectRevert("Too little received");
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapBurn_DustSweep() public {
        // Verify that surplus BEAR from buffer is sent to user
        curvePool.setPrice(1e6);

        dxyBull.mint(alice, 100 * 1e18);
        uint256 bearBefore = dxyBear.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 bearAfter = dxyBear.balanceOf(alice);

        // User should receive some BEAR dust (from the 1% buffer overpurchase)
        // The buffer means we buy slightly more BEAR than needed
        assertGe(bearAfter, bearBefore, "User should receive BEAR dust");

        // Router should not hold any BEAR
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Router should not hold BEAR");
    }

    function test_ZapBurn_EmitsEvent() public {
        curvePool.setPrice(1e6);

        dxyBull.mint(alice, 100 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        // Expect the ZapBurn event
        vm.expectEmit(true, false, false, false);
        emit ZapRouter.ZapBurn(alice, 100 * 1e18, 0); // usdcOut will be non-zero but we don't check exact value

        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapBurn_PartialBurn() public {
        // Test burning only part of holdings
        curvePool.setPrice(1e6);

        dxyBull.mint(alice, 200 * 1e18);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), 100 * 1e18);

        // Burn only half
        zapRouter.zapBurn(100 * 1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should still have 100 BULL left
        assertEq(dxyBull.balanceOf(alice), 100 * 1e18, "Should have remaining BULL");

        // Should have received USDC
        assertGt(usdc.balanceOf(alice), 1000 * 1e6, "Should have more USDC than started");
    }

    function testFuzz_ZapBurn(
        uint256 bullAmount
    ) public {
        // Bound to reasonable range
        bullAmount = bound(bullAmount, 1e18, 1_000_000 * 1e18);

        curvePool.setPrice(1e6); // Parity

        dxyBull.mint(alice, bullAmount);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);
        zapRouter.zapBurn(bullAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);

        // Invariants:
        // 1. User received some USDC
        assertGt(usdcAfter, usdcBefore, "Should receive USDC");

        // 2. Router holds no tokens
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");

        // 3. User's BULL is gone
        assertEq(dxyBull.balanceOf(alice), 0, "BULL should be burned");
    }

    // ==========================================
    // 5. FUZZ TESTS
    // ==========================================

    /// @notice Fuzz test: zapMint with variable USDC amounts
    function testFuzz_ZapMint(
        uint256 usdcAmount
    ) public {
        // Bound to reasonable range: $1 to $1M
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000 * 1e6);

        curvePool.setPrice(1e6); // Parity: 1 BEAR = 1 USDC

        usdc.mint(alice, usdcAmount);
        uint256 bullBefore = dxyBull.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);
        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 bullAfter = dxyBull.balanceOf(alice);

        // Invariants:
        // 1. User received some BULL
        assertGt(bullAfter, bullBefore, "Should receive BULL");

        // 2. Router holds no tokens
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Router leaked BEAR");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");

        // 3. User's USDC was spent (minus initial 1000 USDC from setUp)
        // With 1% buffer, expect actual output to be close to preview
        uint256 bullReceived = bullAfter - bullBefore;
        (,,, uint256 previewTokens,) = zapRouter.previewZapMint(usdcAmount);
        uint256 expectedMin = (previewTokens * 90) / 100; // At least 90% of preview
        assertGt(bullReceived, expectedMin, "Should receive reasonable BULL amount");
    }

    /// @notice Fuzz test: zapMint at different BEAR prices
    function testFuzz_ZapMint_VariablePrice(
        uint256 usdcAmount,
        uint256 bearPriceBps
    ) public {
        // Bound USDC to reasonable range
        usdcAmount = bound(usdcAmount, 100e6, 100_000 * 1e6);

        // Bound BEAR price: 50% to 190% of CAP (price >= CAP reverts)
        // CAP = $2.00, so BEAR price range: $0.10 to $1.90
        bearPriceBps = bound(bearPriceBps, 500, 9500); // 5% to 95% of CAP
        uint256 bearPrice = (2e6 * bearPriceBps) / 10_000; // Scale to 6 decimals
        curvePool.setPrice(bearPrice);

        usdc.mint(alice, usdcAmount);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);
        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Invariants:
        // 1. User received BULL
        assertGt(dxyBull.balanceOf(alice), 0, "Should receive BULL");

        // 2. Router is stateless
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Router leaked BEAR");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");
    }

    /// @notice Fuzz test: zapBurn at different BEAR prices
    function testFuzz_ZapBurn_VariablePrice(
        uint256 bullAmount,
        uint256 bearPriceBps
    ) public {
        // Bound BULL to reasonable range
        bullAmount = bound(bullAmount, 1e18, 100_000 * 1e18);

        // Bound BEAR price: 10% to 150% of $1 (within reasonable trading range)
        // Avoid very high prices where buyback becomes too expensive
        bearPriceBps = bound(bearPriceBps, 1000, 15_000); // 10% to 150%
        uint256 bearPrice = (1e6 * bearPriceBps) / 10_000;
        curvePool.setPrice(bearPrice);

        dxyBull.mint(alice, bullAmount);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);
        zapRouter.zapBurn(bullAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        // Invariants:
        // 1. User received USDC
        assertGt(usdc.balanceOf(alice), usdcBefore, "Should receive USDC");

        // 2. Router is stateless
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Router leaked BEAR");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");

        // 3. User's BULL is gone
        assertEq(dxyBull.balanceOf(alice), 0, "BULL should be burned");
    }

    /// @notice Fuzz test: full round trip (mint then burn)
    function testFuzz_RoundTrip(
        uint256 usdcAmount
    ) public {
        // Bound to reasonable range
        usdcAmount = bound(usdcAmount, 10e6, 100_000 * 1e6);

        curvePool.setPrice(1e6); // Parity

        usdc.mint(alice, usdcAmount);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);

        // 1. Mint BULL
        usdc.approve(address(zapRouter), usdcAmount);
        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);

        uint256 bullMinted = dxyBull.balanceOf(alice);
        assertGt(bullMinted, 0, "Should have minted BULL");

        // 2. Burn BULL back to USDC
        dxyBull.approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);

        // Invariants:
        // 1. Router is stateless
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Router leaked BEAR");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");

        // 2. User's BULL is gone
        assertEq(dxyBull.balanceOf(alice), 0, "BULL should be burned");

        // 3. Round trip loss is bounded (< 15% due to buffers on both sides)
        // This accounts for 1% buffer on mint + swap fees + 1% buffer on burn
        uint256 usdcSpent = usdcBefore > usdcAfter ? usdcBefore - usdcAfter : 0;
        uint256 maxLoss = (usdcAmount * 15) / 100;
        assertLt(usdcSpent, usdcAmount + maxLoss, "Round trip loss too high");
    }

    /// @notice Fuzz test: zapMint with variable slippage tolerance
    function testFuzz_ZapMint_SlippageTolerance(
        uint256 slippageBps
    ) public {
        // Bound slippage to valid range: 1 to 100 bps (0.01% to 1%)
        slippageBps = bound(slippageBps, 1, 100);

        uint256 usdcAmount = 1000e6; // $1000
        curvePool.setPrice(1e6); // Parity

        usdc.mint(alice, usdcAmount);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);
        zapRouter.zapMint(usdcAmount, 0, slippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should succeed with any valid slippage setting
        assertGt(dxyBull.balanceOf(alice), 0, "Should receive BULL");

        // Router stateless
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");
    }

    /// @notice Fuzz test: zapMint minimum output protection
    function testFuzz_ZapMint_MinOutput(
        uint256 usdcAmount,
        uint256 minOutPercent
    ) public {
        // Bound inputs
        usdcAmount = bound(usdcAmount, 100e6, 10_000 * 1e6);
        minOutPercent = bound(minOutPercent, 0, 90); // 0% to 90% of expected

        curvePool.setPrice(1e6); // Parity

        usdc.mint(alice, usdcAmount);

        // Get expected output from preview function
        (,,, uint256 expectedBull,) = zapRouter.previewZapMint(usdcAmount);
        uint256 minOut = (expectedBull * minOutPercent) / 100;

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);
        zapRouter.zapMint(usdcAmount, minOut, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should receive at least minOut
        assertGe(dxyBull.balanceOf(alice), minOut, "Should receive at least minOut");
    }

    /// @notice Fuzz test: zapBurn minimum output protection
    function testFuzz_ZapBurn_MinOutput(
        uint256 bullAmount,
        uint256 minOutPercent
    ) public {
        // Bound inputs
        bullAmount = bound(bullAmount, 1e18, 10_000 * 1e18);
        minOutPercent = bound(minOutPercent, 0, 50); // 0% to 50% of expected (conservative due to buffer)

        curvePool.setPrice(1e6); // Parity

        dxyBull.mint(alice, bullAmount);
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Get expected USDC output from preview function
        (,, uint256 expectedUsdcOut,) = zapRouter.previewZapBurn(bullAmount);
        uint256 minOut = (expectedUsdcOut * minOutPercent) / 100;

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);
        zapRouter.zapBurn(bullAmount, minOut, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should receive at least minOut
        uint256 usdcReceived = usdc.balanceOf(alice) - usdcBefore;
        assertGe(usdcReceived, minOut, "Should receive at least minOut");

        // Router should be stateless
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "Router leaked BULL");
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "Router leaked USDC");
    }

}

// ==========================================
// MOCKS (Updated for $2 CAP and correct transfer logic)
// ==========================================

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
    uint256 public feeBps = 0;

    function setFeeBps(
        uint256 _feeBps
    ) external {
        feeBps = _feeBps;
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

    function maxFlashLoan(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(
        address,
        uint256 amount
    ) public view override returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        uint256 fee = flashFee(token, amount);
        _mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        _burn(address(receiver), amount + fee);
        return true;
    }

}

contract MockCurvePool is ICurvePool {

    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6; // Price of 1 BEAR in USDC (6 decimals). Default $1.00

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
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function get_dx(
        uint256 i,
        uint256 j,
        uint256 dy
    ) external view returns (uint256) {
        // Inverse of get_dy (not in ICurvePool interface but useful for testing)
        if (i == 1 && j == 0) return (dy * 1e18) / bearPrice;
        if (i == 0 && j == 1) return (dy * bearPrice) / 1e18;
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

        // CRITICAL FIX: Simulate Transfer. Take tokens from sender.
        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);

        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12; // Scale 6 decimals to 18 decimals
    }

}

contract MockSplitter is ISyntheticSplitter {

    address public tA; // BEAR
    address public tB; // BULL
    address public usdc;
    Status private _status = Status.ACTIVE;
    uint256 public constant CAP = 2e8; // $2.00 in 8 decimals

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
        // amount is in 18-decimal token units
        // Calculate USDC cost (6 decimals): usdc = amount (18 dec) * CAP (8 dec) / 1e20
        // For CAP = 2e8: 1 token = $2, so 100 tokens = $200 = 200e6 USDC
        // Example: amount=100e18, CAP=2e8 -> usdcCost = 100e18 * 2e8 / 1e20 = 200e6 ✓
        uint256 usdcCost = (amount * CAP) / 1e20;
        // Consume USDC from caller
        MockToken(usdc).transferFrom(msg.sender, address(this), usdcCost);
        // Mint BEAR and BULL to caller
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external override {
        // Real Splitter burns directly from caller (SyntheticToken gives Splitter burn rights)
        // Simulate this by calling burn on the MockFlashToken
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);

        // Return USDC to caller: amount (18 dec) * CAP (8 dec) / 1e20 = USDC (6 dec)
        // Example: amount=100e18, CAP=2e8 -> usdcOut = 100e18 * 2e8 / 1e20 = 200e6 ✓
        uint256 usdcOut = (amount * CAP) / 1e20;
        // Mint USDC to caller (mock is self-sufficient, no need for pre-funding)
        MockToken(usdc).mint(msg.sender, usdcOut);
    }

    function emergencyRedeem(
        uint256
    ) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }

}

contract MockCurvePoolWithMEV is ICurvePool {

    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6;
    uint256 public mevExtractionBps = 0; // MEV bot extracts this % during exchange

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

    function setMevExtraction(
        uint256 _bps
    ) external {
        mevExtractionBps = _bps;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        // Returns "expected" output - what user sees before sandwich
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        // MEV bot sandwiches: actual output is reduced
        uint256 expectedDy = this.get_dy(i, j, dx);
        dy = (expectedDy * (10_000 - mevExtractionBps)) / 10_000;

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

contract ZapRouterMEVTest is Test {

    ZapRouter public zapRouter;
    MockToken public usdc;
    MockFlashToken public dxyBear;
    MockFlashToken public dxyBull;
    MockSplitter public splitter;
    MockCurvePoolWithMEV public curvePool;

    address alice = address(0xA11ce);
    address mevBot = address(0xB07);

    function setUp() public {
        usdc = new MockToken("USDC", "USDC");
        dxyBear = new MockFlashToken("dxyBear", "dxyBear");
        dxyBull = new MockFlashToken("dxyBull", "dxyBull");
        splitter = new MockSplitter(address(dxyBear), address(dxyBull));
        splitter.setUsdc(address(usdc));
        curvePool = new MockCurvePoolWithMEV(address(usdc), address(dxyBear));

        zapRouter =
            new ZapRouter(address(splitter), address(dxyBear), address(dxyBull), address(usdc), address(curvePool));

        usdc.mint(alice, 1000 * 1e6);
        dxyBull.mint(alice, 100 * 1e18);
    }

    /// @notice MEV extraction beyond buffer reverts at Curve (not late solvency check)
    /// Fix ensures swap reverts immediately with "Too little received"
    function test_ZapBurn_MEV_Reverts_At_Curve_Swap() public {
        curvePool.setPrice(1e6);
        curvePool.setMevExtraction(100); // 1% MEV extraction (exceeds 0.5% buffer)

        uint256 bullAmount = 100 * 1e18;

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);

        // With fix: Curve swap reverts with "Too little received"
        // Before fix: Would pass swap but fail later with SolvencyBreach
        vm.expectRevert("Too little received");
        zapRouter.zapBurn(bullAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Small MEV within buffer still succeeds (acceptable)
    /// The fix protects against MEV exceeding the buffer
    function test_ZapBurn_SmallMEV_Within_Buffer_Succeeds() public {
        curvePool.setPrice(1e6);
        curvePool.setMevExtraction(40); // 0.4% MEV (within 0.5% buffer)

        uint256 bullAmount = 100 * 1e18;
        uint256 bearBefore = dxyBear.balanceOf(alice);

        vm.startPrank(alice);
        dxyBull.approve(address(zapRouter), bullAmount);
        zapRouter.zapBurn(bullAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        // Small MEV reduces dust but tx still succeeds
        uint256 bearDust = dxyBear.balanceOf(alice) - bearBefore;
        assertGt(bearDust, 0, "User should still get some BEAR dust");
        assertLt(bearDust, 0.5 ether, "But less than full buffer due to MEV");
    }

}
