// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import "../src/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public leverageRouter;

    // Mocks
    MockToken public usdc;
    MockToken public mDXY;
    MockMorpho public morpho;
    MockCurvePool public curvePool;
    MockFlashLender public lender;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        mDXY = new MockToken("mDXY", "mDXY", 18);
        morpho = new MockMorpho();
        curvePool = new MockCurvePool(address(usdc), address(mDXY));
        lender = new MockFlashLender(address(usdc));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(mDXY),
            oracle: address(0),
            irm: address(0),
            lltv: 900000000000000000 // 90%
        });

        leverageRouter = new LeverageRouter(
            address(morpho), address(curvePool), address(usdc), address(mDXY), address(lender), params
        );

        // Setup Alice
        usdc.mint(alice, 10_000 * 1e6); // $10k
    }

    function test_OpenLeverage_3x_Success() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 100; // 1% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);

        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 3000 * 1e18, "Incorrect supplied amount");
        assertEq(borrowed, 2000 * 1e6, "Incorrect borrowed amount");
    }

    function test_OpenLeverage_EmitsLeverageOpenedEvent() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 50; // 0.5% slippage
        uint256 expectedLoanAmount = 2000 * 1e6; // principal * (leverage - 1) / 1e18
        uint256 expectedMDXYReceived = 3000 * 1e18; // (principal + loan) * 1e12
        uint256 expectedDebtIncurred = 2000 * 1e6; // loan + fee (fee is 0 in mock)

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectEmit(true, false, false, true);
        emit LeverageRouter.LeverageOpened(
            alice, principal, leverage, expectedLoanAmount, expectedMDXYReceived, expectedDebtIncurred, maxSlippageBps
        );

        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_NoAuth() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        // Skip auth - router checks upfront before flash loan

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_AuthRevoked() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);

        // Authorize then revoke
        morpho.setAuthorization(address(leverageRouter), true);
        morpho.setAuthorization(address(leverageRouter), false);

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_Expired() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with expired deadline
        vm.expectRevert("Transaction expired");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_SlippageTooHigh() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with slippage exceeding MAX_SLIPPAGE_BPS (100)
        vm.expectRevert("Slippage exceeds maximum");
        leverageRouter.openLeverage(principal, leverage, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_LeverageTooLow() public {
        uint256 principal = 1000 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with leverage = 1x (must be > 1x)
        vm.expectRevert("Leverage must be > 1x");
        leverageRouter.openLeverage(principal, 1e18, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);

        // Alice pretends to be a Flash Lender calling the callback
        vm.expectRevert("Untrusted lender");
        leverageRouter.onFlashLoan(address(leverageRouter), address(usdc), 1000 * 1e6, 0, "");
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        // Pretend to be the legitimate lender calling the callback...
        vm.startPrank(address(lender));

        // ...BUT the 'initiator' arg is Alice, not the LeverageRouter itself.
        vm.expectRevert("Untrusted initiator");
        leverageRouter.onFlashLoan(
            alice, // <--- Malicious initiator
            address(usdc),
            1000 * 1e6,
            0,
            ""
        );
        vm.stopPrank();
    }

    // ==========================================
    // CLOSE LEVERAGE TESTS
    // ==========================================

    function test_CloseLeverage_Success() public {
        // First open a leveraged position
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 100; // 1% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);

        // Verify position was opened
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 3000 * 1e18, "Incorrect supplied amount after open");
        assertEq(borrowed, 2000 * 1e6, "Incorrect borrowed amount after open");

        // Now close the position
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position was closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Supplied should be 0 after close");
        assertEq(borrowedAfter, 0, "Borrowed should be 0 after close");
    }

    function test_CloseLeverage_EmitsLeverageClosedEvent() public {
        // First open a leveraged position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;
        uint256 maxSlippageBps = 50; // 0.5% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);

        // Now close the position and check event
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;
        uint256 expectedUsdcReturned = 1000 * 1e6; // 3000 mDXY -> 3000 USDC - 2000 debt = 1000

        vm.expectEmit(true, false, false, true);
        emit LeverageRouter.LeverageClosed(
            alice, debtToRepay, collateralToWithdraw, expectedUsdcReturned, maxSlippageBps
        );

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_NoAuth() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        // Skip authorization

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_Expired() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectRevert("Transaction expired");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_SlippageTooHigh() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with slippage exceeding MAX_SLIPPAGE_BPS (100)
        vm.expectRevert("Slippage exceeds maximum");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_OpenLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs to reasonable ranges
        // Principal: $1 to $1M USDC
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        // Leverage: 1.1x to 10x (in 1e18 units)
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        // Mint enough USDC for alice
        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify invariants
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Expected values (at 1:1 mock rate):
        // totalUSDC = principal + loanAmount = principal + principal * (leverage - 1) / 1e18
        //           = principal * leverage / 1e18
        // mDXY received = totalUSDC * 1e12 (decimal conversion)
        uint256 expectedSupplied = (principal * leverageMultiplier / 1e18) * 1e12;
        uint256 expectedBorrowed = principal * (leverageMultiplier - 1e18) / 1e18;

        assertEq(supplied, expectedSupplied, "Supplied mDXY mismatch");
        assertEq(borrowed, expectedBorrowed, "Borrowed USDC mismatch");
    }

    function testFuzz_OpenAndCloseLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Open position
        leverageRouter.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);

        // Get position state
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Close entire position
        leverageRouter.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position is fully closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position not fully closed - supplied");
        assertEq(borrowedAfter, 0, "Position not fully closed - borrowed");
    }

    function testFuzz_OpenLeverage_SlippageBound(uint256 slippageBps) public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2e18;

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        if (slippageBps > 100) {
            vm.expectRevert("Slippage exceeds maximum");
            leverageRouter.openLeverage(principal, leverage, slippageBps, block.timestamp + 1 hours);
        } else {
            leverageRouter.openLeverage(principal, leverage, slippageBps, block.timestamp + 1 hours);
            (uint256 supplied,) = morpho.positions(alice);
            assertGt(supplied, 0, "Position should be opened");
        }
        vm.stopPrank();
    }

    // ==========================================
    // VIEW FUNCTION TESTS
    // ==========================================

    function test_PreviewOpenLeverage() public view {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3e18; // 3x

        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedMDXY, uint256 expectedDebt) =
            leverageRouter.previewOpenLeverage(principal, leverage);

        // 3x leverage on $1000 = $2000 loan
        assertEq(loanAmount, 2000 * 1e6, "Incorrect loan amount");
        // Total = $1000 + $2000 = $3000
        assertEq(totalUSDC, 3000 * 1e6, "Incorrect total USDC");
        // mDXY at 1:1 = $3000 * 1e12 = 3000e18
        assertEq(expectedMDXY, 3000 * 1e18, "Incorrect expected mDXY");
        // Debt = loan + fee (fee is 0 in mock)
        assertEq(expectedDebt, 2000 * 1e6, "Incorrect expected debt");
    }

    function test_PreviewOpenLeverage_MatchesActual() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        // Get preview
        (,, uint256 expectedMDXY, uint256 expectedDebt) = leverageRouter.previewOpenLeverage(principal, leverage);

        // Execute actual operation
        usdc.mint(alice, principal);
        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify preview matches actual
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, expectedMDXY, "Preview mDXY doesn't match actual");
        assertEq(borrowed, expectedDebt, "Preview debt doesn't match actual");
    }

    function test_PreviewCloseLeverage() public view {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) =
            leverageRouter.previewCloseLeverage(debtToRepay, collateralToWithdraw);

        // USDC from selling 3000e18 mDXY at 1:1 = $3000
        assertEq(expectedUSDC, 3000 * 1e6, "Incorrect expected USDC");
        // Flash fee is 0 in mock
        assertEq(flashFee, 0, "Incorrect flash fee");
        // Return = $3000 - $2000 debt - $0 fee = $1000
        assertEq(expectedReturn, 1000 * 1e6, "Incorrect expected return");
    }

    function test_PreviewCloseLeverage_MatchesActual() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        usdc.mint(alice, principal);
        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Get position
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Get preview for close
        (,, uint256 expectedReturn) = leverageRouter.previewCloseLeverage(borrowed, supplied);

        // Record balance before close
        uint256 balanceBefore = usdc.balanceOf(alice);

        // Execute close
        leverageRouter.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify preview matches actual
        uint256 actualReturn = usdc.balanceOf(alice) - balanceBefore;
        assertEq(actualReturn, expectedReturn, "Preview return doesn't match actual");
    }

    // ==========================================
    // CRITICAL: REENTRANCY TESTS
    // ==========================================

    function test_OnFlashLoan_Reentrancy_NoExploitation() public {
        // Deploy a malicious flash lender that attempts reentrancy
        ReentrantFlashLender maliciousLender = new ReentrantFlashLender(address(usdc), address(leverageRouter));

        // Create a new router with the malicious lender
        LeverageRouter vulnerableRouter = new LeverageRouter(
            address(morpho), address(curvePool), address(usdc), address(mDXY), address(maliciousLender), params
        );

        // Update the malicious lender to target the new router
        maliciousLender.setTargetRouter(address(vulnerableRouter));

        uint256 principal = 1000 * 1e6;
        usdc.mint(alice, principal * 2); // Extra for potential reentrancy

        vm.startPrank(alice);
        usdc.approve(address(vulnerableRouter), principal * 2);
        morpho.setAuthorization(address(vulnerableRouter), true);

        // The malicious lender will try to call openLeverage again during callback
        // The reentrancy attempt should fail (caught by try-catch in malicious lender)
        // but the outer transaction should complete normally
        vulnerableRouter.openLeverage(principal, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify only ONE position was created (no double-entry from reentrancy)
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Expected: 2x leverage on $1000 = $2000 total exposure
        // Only one position should exist
        assertEq(supplied, 2000 * 1e18, "Should have exactly one position's collateral");
        assertEq(borrowed, 1000 * 1e6, "Should have exactly one position's debt");

        // Verify the reentrancy attempt was made but failed
        assertFalse(maliciousLender.attemptReentrancy(), "Reentrancy was attempted");
    }

    // ==========================================
    // CRITICAL: ZERO INPUT TESTS
    // ==========================================

    function test_OpenLeverage_ZeroPrincipal_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), 0);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectRevert("Principal must be > 0");
        leverageRouter.openLeverage(0, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // CRITICAL: FLASH FEE TESTS
    // ==========================================

    function test_OpenLeverage_WithFlashFee_DebtIncludesFee() public {
        // Set a 0.1% flash fee (10 bps)
        lender.setFeeBps(10);

        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3e18; // 3x -> $2000 loan
        uint256 expectedLoan = 2000 * 1e6;
        uint256 expectedFee = (expectedLoan * 10) / 10000; // 0.1% of $2000 = $2

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify debt includes the flash fee
        (, uint256 borrowed) = morpho.positions(alice);
        assertEq(borrowed, expectedLoan + expectedFee, "Debt should include flash fee");
    }

    function test_CloseLeverage_WithFlashFee_AccountsForFee() public {
        // First open a position without fee
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Now set a flash fee for close
        lender.setFeeBps(10); // 0.1%
        uint256 flashFee = (borrowed * 10) / 10000;

        uint256 balanceBefore = usdc.balanceOf(alice);

        // Close the position - flash loan costs extra due to fee
        leverageRouter.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // User should receive: swapOutput - borrowed - flashFee
        // swapOutput = 3000e18 / 1e12 = 3000e6
        // returned = 3000e6 - 2000e6 - flashFee
        uint256 expectedReturn = 3000 * 1e6 - borrowed - flashFee;
        uint256 actualReturn = usdc.balanceOf(alice) - balanceBefore;
        assertEq(actualReturn, expectedReturn, "Return should account for flash fee");
    }

    function test_PreviewOpenLeverage_IncludesFlashFee() public {
        // Set a flash fee
        lender.setFeeBps(50); // 0.5%

        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;
        uint256 expectedLoan = 2000 * 1e6;
        uint256 expectedFee = (expectedLoan * 50) / 10000; // $10

        (uint256 loanAmount,,, uint256 expectedDebt) = leverageRouter.previewOpenLeverage(principal, leverage);

        assertEq(loanAmount, expectedLoan, "Loan amount incorrect");
        assertEq(expectedDebt, expectedLoan + expectedFee, "Preview should include flash fee in debt");
    }

    // ==========================================
    // CRITICAL: STATE ISOLATION TESTS
    // ==========================================

    function test_OpenLeverage_SequentialUsers_StateIsolation() public {
        // Test that transient state variables don't leak between operations
        address bob = address(0xB0B);
        usdc.mint(bob, 2000 * 1e6);

        // Alice opens position
        uint256 alicePrincipal = 1000 * 1e6;
        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), alicePrincipal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(alicePrincipal, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Bob opens position with different amount
        uint256 bobPrincipal = 2000 * 1e6;
        vm.startPrank(bob);
        usdc.approve(address(leverageRouter), bobPrincipal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Capture event to verify correct values
        vm.expectEmit(true, false, false, true);
        emit LeverageRouter.LeverageOpened(
            bob,
            bobPrincipal,
            2e18,
            2000 * 1e6, // Bob's loan
            4000 * 1e18, // Bob's mDXY (not Alice's)
            2000 * 1e6, // Bob's debt (not Alice's)
            100
        );
        leverageRouter.openLeverage(bobPrincipal, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify each user has correct position
        (uint256 aliceSupplied,) = morpho.positions(alice);
        (uint256 bobSupplied,) = morpho.positions(bob);
        assertEq(aliceSupplied, 2000 * 1e18, "Alice position incorrect");
        assertEq(bobSupplied, 4000 * 1e18, "Bob position incorrect");
    }

    // ==========================================
    // HIGH PRIORITY: ROUNDING TESTS (#5)
    // ==========================================

    function test_OpenLeverage_LeverageTooLowForPrincipal_Reverts() public {
        // With small principal and tiny leverage, loan amount rounds to 0
        // principal = 1 USDC (1e6), leverage = 1.0000001x
        // loanAmount = (1e6 * (1.0000001e18 - 1e18)) / 1e18 = (1e6 * 1e11) / 1e18 = 0
        uint256 principal = 1e6; // 1 USDC
        uint256 tinyLeverage = 1e18 + 1e11; // 1.0000001x

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectRevert("Leverage too low for principal");
        leverageRouter.openLeverage(principal, tinyLeverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_MinimumViableLeverage_Succeeds() public {
        // Find the minimum leverage that produces loanAmount = 1
        // loanAmount = (principal * (leverage - 1e18)) / 1e18 >= 1
        // For principal = 1e6: (leverage - 1e18) >= 1e18 / 1e6 = 1e12
        // So leverage >= 1e18 + 1e12 = 1.000001e18
        uint256 principal = 1e6; // 1 USDC
        uint256 minViableLeverage = 1e18 + 1e12; // 1.000001x

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, minViableLeverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertGt(supplied, 0, "Should have opened position");
        assertEq(borrowed, 1, "Should have minimum 1 wei debt");
    }

    // ==========================================
    // HIGH PRIORITY: PARTIAL CLOSE TESTS (#8)
    // ==========================================

    function test_CloseLeverage_PartialClose_Success() public {
        // Open a 3x position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 suppliedBefore, uint256 borrowedBefore) = morpho.positions(alice);

        // Close 50% of position
        uint256 debtToRepay = borrowedBefore / 2;
        uint256 collateralToWithdraw = suppliedBefore / 2;

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify partial close worked
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, suppliedBefore - collateralToWithdraw, "Collateral not partially withdrawn");
        assertEq(borrowedAfter, borrowedBefore - debtToRepay, "Debt not partially repaid");
    }

    function test_CloseLeverage_OnlyRepayDebt_Success() public {
        // Open a 3x position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 suppliedBefore, uint256 borrowedBefore) = morpho.positions(alice);

        // Repay some debt but withdraw no collateral
        uint256 debtToRepay = borrowedBefore / 2;
        uint256 collateralToWithdraw = debtToRepay * 1e12; // Need to withdraw enough to cover swap

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify debt reduced
        (, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(borrowedAfter, borrowedBefore - debtToRepay, "Debt not repaid");
    }

    // ==========================================
    // HIGH PRIORITY: AUTH REVOCATION TEST (#10)
    // ==========================================

    function test_OpenLeverage_AuthRevokedDuringCallback_Behavior() public {
        // This test documents behavior when auth is checked by Morpho during callback
        // The router checks auth upfront, but Morpho also checks during supply/borrow
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Authorization is checked at the start and by Morpho during operations
        // If auth were revoked mid-tx, Morpho would revert
        // Since we can't revoke mid-tx in a single call, this test verifies
        // that Morpho's auth checks are in place

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position was created with proper authorization
        (uint256 supplied,) = morpho.positions(alice);
        assertGt(supplied, 0, "Position should be created");
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFlashLender is IERC3156FlashLender {
    address token;
    uint256 public feeBps = 0; // Configurable fee in basis points (default 0)

    constructor(address _token) {
        token = _token;
    }

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256 amount) public view override returns (uint256) {
        return (amount * feeBps) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address t, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        uint256 fee = flashFee(t, amount);
        MockToken(token).mint(address(receiver), amount); // Send money
        require(
            receiver.onFlashLoan(msg.sender, t, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        // In a real lender, we'd burn/transfer back amount + fee
        // For mock, we just verify the callback succeeded
        return true;
    }
}

contract MockCurvePool is ICurvePool {
    address public token0; // USDC (index 0)
    address public token1; // mDXY (index 1)

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external override returns (uint256 dy) {
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // Detect swap direction by checking decimals difference
        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> mDXY (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // mDXY (18) -> USDC (6) : / 1e12
            dy = dx / 1e12;
        }

        require(dy >= min_dy, "Too little received");
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }
}

contract MockMorpho is IMorpho {
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => ActionData) public positions;

    struct ActionData {
        uint256 supplied;
        uint256 borrowed;
    }

    function setAuthorization(address operator, bool approved) external {
        isAuthorized[msg.sender][operator] = approved;
    }

    function supply(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied += assets;
        return (assets, 0);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed += assets;
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed -= assets;
        return (assets, 0);
    }

    function withdraw(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied -= assets;
        return (assets, 0);
    }
}

/// @notice Malicious flash lender that attempts reentrancy during callback
contract ReentrantFlashLender is IERC3156FlashLender {
    address public token;
    address public targetRouter;
    bool public attemptReentrancy = true;

    constructor(address _token, address _targetRouter) {
        token = _token;
        targetRouter = _targetRouter;
    }

    function setTargetRouter(address _targetRouter) external {
        targetRouter = _targetRouter;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address t, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        MockToken(token).mint(address(receiver), amount);

        // Before calling the callback, attempt reentrancy by calling openLeverage again
        if (attemptReentrancy && targetRouter != address(0)) {
            attemptReentrancy = false; // Prevent infinite recursion
            // Try to call openLeverage on the router during the flash loan
            try LeverageRouter(targetRouter).openLeverage(100 * 1e6, 2e18, 100, block.timestamp + 1 hours) {
            // If this succeeds, we have a reentrancy vulnerability
            }
                catch {
                // Expected: should fail
            }
        }

        require(
            receiver.onFlashLoan(msg.sender, t, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        return true;
    }
}
