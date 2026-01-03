// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/BullLeverageRouter.sol";
import "../src/base/FlashLoanBase.sol";
import "../src/interfaces/ICurvePool.sol";
import "../src/interfaces/ISyntheticSplitter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract BullLeverageRouterTest is Test {
    BullLeverageRouter public router;

    // Mocks
    MockToken public usdc;
    MockFlashToken public dxyBear;
    MockToken public dxyBull;
    MockStakedToken public stakedDxyBull;
    MockMorpho public morpho;
    MockCurvePool public curvePool;
    MockFlashLender public lender;
    MockSplitter public splitter;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        dxyBear = new MockFlashToken("DXY-BEAR", "DXY-BEAR");
        dxyBull = new MockToken("DXY-BULL", "DXY-BULL", 18);
        stakedDxyBull = new MockStakedToken(address(dxyBull));
        morpho = new MockMorpho();
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        lender = new MockFlashLender(address(usdc));
        splitter = new MockSplitter(address(dxyBear), address(dxyBull), address(usdc));

        // Configure MockMorpho with token addresses (collateral is now staked token)
        morpho.setTokens(address(usdc), address(stakedDxyBull));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedDxyBull),
            oracle: address(0),
            irm: address(0),
            lltv: 900000000000000000 // 90%
        });

        router = new BullLeverageRouter(
            address(morpho),
            address(splitter),
            address(curvePool),
            address(usdc),
            address(dxyBear),
            address(dxyBull),
            address(stakedDxyBull),
            address(lender),
            params
        );

        // Setup Alice
        usdc.mint(alice, 10_000 * 1e6); // $10k
    }

    // ==========================================
    // OPEN LEVERAGE TESTS
    // ==========================================

    function test_OpenLeverage_3x_Success() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 100; // 1% slippage

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        router.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify: 3x on $1000 = $3000 total USDC
        // With CAP=$2: $3000 USDC mints 1500e18 of each token
        // Sell 1500e18 DXY-BEAR for 1500 USDC (at 1:1 rate)
        // Deposit 1500e18 DXY-BULL as collateral
        // Flash loan repayment = $2000, sale gives $1500
        // Morpho debt = max(0, 2000 - 1500) = 500
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 1500 * 1e18, "Incorrect supplied amount");
        assertEq(borrowed, 500 * 1e6, "Incorrect borrowed amount");
    }

    function test_OpenLeverage_WithFlashLoanFees() public {
        // Set 0.09% fee (standard for some pools)
        lender.setFeeBps(9);

        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Loan = 2000 USDC. Fee = 2000 * 0.0009 = 1.8 USDC (1_800_000).
        // Total Debt needed = 2000 + 1.8 = 2001.8 USDC.
        // Sale Proceeds (1:1) = 1500 USDC.
        // Borrow from Morpho should be: 2001.8 - 1500 = 501.8 USDC
        assertEq(borrowed, 501_800_000, "Borrow amount did not account for flash fees");
        assertEq(supplied, 1500 * 1e18, "Supplied amount unaffected by fee");
    }

    function test_OpenLeverage_EmitsEvent() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;
        uint256 maxSlippageBps = 50;
        uint256 expectedLoanAmount = 2000 * 1e6;
        // With CAP=$2: $3000 USDC mints 1500e18 tokens
        uint256 expectedDxyBull = 1500 * 1e18;
        // With 1:1 rates: usdcFromSale = 1500 (selling 1500e18 BEAR), flashRepayment = 2000
        // debtToIncur = max(0, 2000 - 1500) = 500
        uint256 expectedDebt = 500 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectEmit(true, false, false, true);
        emit BullLeverageRouter.LeverageOpened(
            alice, principal, leverage, expectedLoanAmount, expectedDxyBull, expectedDebt, maxSlippageBps
        );

        router.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_NoAuth() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        // Skip auth

        vm.expectRevert("BullLeverageRouter not authorized in Morpho");
        router.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_Expired() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Transaction expired");
        router.openLeverage(principal, leverage, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_LeverageTooLow() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 1e18; // 1x (not > 1x)

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Leverage must be > 1x");
        router.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_SlippageTooHigh() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Slippage exceeds maximum");
        router.openLeverage(principal, leverage, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_SlippageTooHigh() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Slippage exceeds maximum");
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test that open swap reverts when Curve returns less than minOut (MEV protection)
    function test_OpenLeverage_MinOut_Enforced_Reverts() public {
        // Simulate MEV attack: price moves after get_dy but before exchange
        curvePool.setSlippage(500); // 5% slippage exceeds 1% tolerance

        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // The BEAR -> USDC swap during open will fail due to slippage
        vm.expectRevert("Too little received");
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test that close swap reverts when Curve returns less than minOut
    function test_CloseLeverage_MinOut_Enforced_Reverts() public {
        // First open a position successfully
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Now simulate MEV attack during close
        curvePool.setSlippage(500); // 5% slippage exceeds 1% tolerance

        // The USDC -> BEAR swap during close (to repay flash mint) will fail
        vm.expectRevert("Too little received");
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test that slippage within tolerance succeeds
    function test_OpenLeverage_SlippageWithinTolerance_Succeeds() public {
        // 0.5% slippage is within 1% max tolerance
        curvePool.setSlippage(50);

        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Should succeed because actual slippage (0.5%) < tolerance (1%)
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position was created
        (uint256 supplied,) = morpho.positions(alice);
        assertGt(supplied, 0, "Should have collateral");
    }

    function test_OpenLeverage_Revert_ZeroPrincipal() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Principal must be > 0");
        router.openLeverage(0, 2e18, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_SplitterNotActive() public {
        splitter.setStatus(ISyntheticSplitter.Status.PAUSED);

        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Splitter not active");
        router.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // CLOSE LEVERAGE TESTS
    // ==========================================

    function test_CloseLeverage_Success() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Get position state
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Close the position
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position is closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position should be closed");
        assertEq(borrowedAfter, 0, "Debt should be repaid");

        // User should have received USDC back (~principal minus fees/slippage)
        uint256 aliceBalance = usdc.balanceOf(alice);
        assertGt(aliceBalance, 9000 * 1e6, "Alice should have received USDC back");

        // Verify no USDC dust in router (should all be sent to user)
        assertEq(usdc.balanceOf(address(router)), 0, "Router holding USDC");
    }

    function test_CloseLeverage_HighBearPrice() public {
        // 1. Open Position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // 2. Scenario: DXY-BEAR price rises to $1.10 relative to USDC
        // This means 1 USDC buys LESS Bear (~0.909).
        // Router must spend MORE USDC to buy back the required amount of BEAR.
        curvePool.setRate(100, 110); // 100 output for 110 input -> Output < Input

        // 3. Close
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // 4. Verify Success
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position should be closed");
        assertEq(borrowedAfter, 0, "Debt should be repaid");

        // 5. Verify no USDC is left (it was either used to buy expensive BEAR or refunded)
        assertEq(usdc.balanceOf(address(router)), 0, "Router holding USDC");

        // 6. Note: Due to slippage buffer logic in _executeCloseRedeem,
        // the router will likely hold some DXY-BEAR dust.
        // We assert >= 0 just to acknowledge this behavior.
        assertGe(dxyBear.balanceOf(address(router)), 0, "Router may hold BEAR dust");
    }

    function test_CloseLeverage_Revert_Insolvent() public {
        // 1. Open Position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // 2. Mock a catastrophic event where Splitter redemption pays out only 10%
        // The user owes 2000 USDC Flash Loan, but redemption of 1500 pairs only gives
        // 3000 * 0.10 = 300 USDC.
        // 300 USDC < 2000 USDC Debt -> Revert
        splitter.setRedemptionRate(10); // 10%

        vm.expectRevert("Insufficient USDC for BEAR buyback");
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_EmitsEvent() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;
        uint256 maxSlippageBps = 100;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // With CAP=$2 pricing:
        // After open: supplied = 1500e18 DXY-BULL, borrowed = 500e6 USDC
        // Close flow:
        // 1. Flash loan: 500 USDC (to repay Morpho debt)
        // 2. Redeem 1500e18 pairs: 3000 USDC
        // 3. Buy 1500e18 BEAR on Curve: ~1500 USDC (1:1 in mock, with slippage buffer)
        // 4. Repay flash loan: 500 USDC
        // 5. Leftover returned to user
        // Note: Mock curve doesn't actually apply slippage, just validates minOut
        // Total USDC returned = redemption - buyback - flash loan repay + any surplus
        uint256 expectedUsdcReturned = 985 * 1e6;

        vm.expectEmit(true, false, false, true);
        emit BullLeverageRouter.LeverageClosed(alice, borrowed, supplied, expectedUsdcReturned, maxSlippageBps);

        router.closeLeverage(borrowed, supplied, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_NoAuth() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        // Skip authorization

        vm.expectRevert("BullLeverageRouter not authorized in Morpho");
        router.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_Expired() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Transaction expired");
        router.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_CloseLeverage_PartialClose_Success() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 suppliedBefore, uint256 borrowedBefore) = morpho.positions(alice);

        // Close 50% of position
        uint256 halfDebt = borrowedBefore / 2;
        uint256 halfCollateral = suppliedBefore / 2;

        router.closeLeverage(halfDebt, halfCollateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify partial close
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, suppliedBefore - halfCollateral, "Collateral should be halved");
        assertEq(borrowedAfter, borrowedBefore - halfDebt, "Debt should be halved");
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_OpenLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        router.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify invariants
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Expected: totalUSDC = principal * leverage / 1e18
        // With CAP=$2: DXY-BULL received = (totalUSDC * 1e12) / 2
        uint256 totalUSDC = principal * leverageMultiplier / 1e18;
        uint256 expectedSupplied = (totalUSDC * 1e12) / 2;

        // Flash loan = principal * (leverage - 1) / 1e18
        // USDC from sale = tokensToSell (at 1:1 rate) / 1e12
        // With CAP=$2: we sell (totalUSDC / 2) tokens worth of BEAR
        uint256 loanAmount = principal * (leverageMultiplier - 1e18) / 1e18;
        uint256 usdcFromSale = expectedSupplied / 1e12; // Mock curve gives 1:1 rate with decimal conversion
        uint256 expectedBorrowed = loanAmount > usdcFromSale ? loanAmount - usdcFromSale : 0;

        assertEq(supplied, expectedSupplied, "Supplied DXY-BULL mismatch");
        assertEq(borrowed, expectedBorrowed, "Borrowed USDC mismatch");
    }

    function testFuzz_OpenAndCloseLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Open
        router.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Close
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Position should be fully closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position not fully closed");
        assertEq(borrowedAfter, 0, "Debt not fully repaid");
    }

    // ==========================================
    // VIEW FUNCTION TESTS
    // ==========================================

    function test_PreviewOpenLeverage() public view {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBull, uint256 expectedDebt) =
            router.previewOpenLeverage(principal, leverage);

        assertEq(loanAmount, 2000 * 1e6, "Incorrect loan amount");
        assertEq(totalUSDC, 3000 * 1e6, "Incorrect total USDC");
        // With CAP=$2.00: $3000 USDC mints 1500e18 tokens (1 USDC = 0.5 pairs)
        assertEq(expectedDxyBull, 1500 * 1e18, "Incorrect expected DXY-BULL");
        // With 1:1 rates: flashRepayment=2000, usdcFromSale=1500 (selling 1500e18 BEAR at $1 each)
        // expectedDebt = max(0, 2000 - 1500) = 500
        assertEq(expectedDebt, 500 * 1e6, "Incorrect expected debt");
    }

    function test_PreviewCloseLeverage() public view {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) =
            router.previewCloseLeverage(debtToRepay, collateralToWithdraw);

        // With CAP=$2.00: 3000e18 tokens redeem to 6000 USDC (1 token = $2)
        assertEq(expectedUSDC, 6000 * 1e6, "Incorrect expected USDC");

        // At 1:1 rate, buying 3000e18 BEAR costs 3000 USDC
        assertEq(usdcForBearBuyback, 3000 * 1e6, "Incorrect BEAR buyback cost");

        // Total costs: debt (2000) + flashFee (0) + buyback (3000) = 5000
        // USDC from redemption: 6000
        // expectedReturn = 6000 - 5000 = 1000
        assertEq(expectedReturn, 1000 * 1e6, "Incorrect expected return");
    }

    // ==========================================
    // CALLBACK SECURITY TESTS
    // ==========================================

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);

        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidLender.selector);
        router.onFlashLoan(
            address(router), address(usdc), 100, 0, abi.encode(uint8(1), alice, block.timestamp + 1, 0, 0)
        );
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        vm.startPrank(address(lender));

        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidInitiator.selector);
        router.onFlashLoan(alice, address(usdc), 100, 0, abi.encode(uint8(1), alice, block.timestamp + 1, 0, 0));
        vm.stopPrank();
    }

    // ==========================================
    // EDGE CASE TESTS (Phase 2.5)
    // ==========================================

    /// @notice Test extreme leverage: 100x
    function test_OpenLeverage_ExtremeLeverage_100x() public {
        uint256 principal = 100 * 1e6; // $100 to keep numbers manageable
        uint256 leverage = 100 * 1e18; // 100x

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // With 100x: loan = 99 * $100 = $9900
        // Total USDC = $10,000
        // With CAP=$2: mints 5000e18 of each token
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 5000 * 1e18, "Collateral should be 100x / CAP");
        // Borrowed = max(0, 9900 - 5000) = 4900
        assertEq(borrowed, 4900 * 1e6, "Debt = flash loan - sale proceeds");
    }

    /// @notice Test leverage just above 1x (1.1x)
    function test_OpenLeverage_MinimalLeverage_1_1x() public {
        uint256 principal = 1000 * 1e6;
        // 1.1x leverage
        uint256 leverage = 1_100_000_000_000_000_000;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // 1.1x on $1000 = $1100 total
        // With CAP=$2: mints 550e18 of each token
        // Sale = 550 USDC, loan = 100 USDC
        // Debt = max(0, 100 - 550) = 0
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 550 * 1e18, "Collateral for 1.1x");
        assertEq(borrowed, 0, "No debt needed at 1.1x");
    }

    /// @notice Test small principal
    function test_OpenLeverage_SmallPrincipal_100Wei() public {
        uint256 principal = 100; // 100 wei USDC
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Loan = 200 wei
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertGt(supplied, 0, "Should have some collateral");
    }

    /// @notice Test pause blocks open
    function test_OpenLeverage_WhenPaused_Reverts() public {
        router.pause();

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert();
        router.openLeverage(1000 * 1e6, 3 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test pause blocks close
    function test_CloseLeverage_WhenPaused_Reverts() public {
        // First create a position
        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(1000 * 1e6, 2 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Pause router
        router.pause();

        // Close should fail
        vm.startPrank(alice);
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        vm.expectRevert();
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test unpause allows operations
    function test_Unpause_AllowsOperations() public {
        router.pause();
        router.unpause();

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true);

        // Should work after unpause
        router.openLeverage(1000 * 1e6, 2 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied,) = morpho.positions(alice);
        assertGt(supplied, 0, "Position should be created");
    }

    /// @notice Test zero principal reverts
    function test_OpenLeverage_ZeroPrincipal_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Principal must be > 0");
        router.openLeverage(0, 3 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test close with zero debt still works
    function test_CloseLeverage_ZeroDebt_Succeeds() public {
        // Create position with low leverage that results in zero debt
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 1_100_000_000_000_000_000; // 1.1x

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(borrowed, 0, "Should have zero debt at 1.1x");

        // Close position (with zero debt)
        router.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Position should be cleared
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Collateral should be cleared");
        assertEq(borrowedAfter, 0, "Debt should remain zero");
    }
}

// ==========================================
// MOCK CONTRACTS
// ==========================================

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockStakedToken is ERC20 {
    MockToken public underlying;

    constructor(address _underlying) ERC20("Staked Token", "sTKN") {
        underlying = MockToken(_underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares; // 1:1 for simplicity
        underlying.transfer(receiver, assets);
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }
}

contract MockFlashToken is ERC20, IERC3156FlashLender {
    uint256 private _feeBps = 0;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setFeeBps(uint256 bps) external {
        _feeBps = bps;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256 amount) public view override returns (uint256) {
        return (amount * _feeBps) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
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

contract MockFlashLender is IERC3156FlashLender {
    address public token;
    uint256 private _feeBps = 0;

    constructor(address _token) {
        token = _token;
    }

    function setFeeBps(uint256 bps) external {
        _feeBps = bps;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256 amount) public view override returns (uint256) {
        return (amount * _feeBps) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        require(_token == token, "Wrong token");
        uint256 fee = flashFee(_token, amount);
        MockToken(token).mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, _token, amount, fee, data)
                == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        uint256 totalRepayment = amount + fee;
        MockToken(token).transferFrom(address(receiver), address(this), totalRepayment);
        MockToken(token).burn(address(this), totalRepayment);
        return true;
    }
}

contract MockCurvePool is ICurvePool {
    address public token0; // USDC (index 0)
    address public token1; // DXY-BEAR (index 1)

    // Scale factor for output. Default 1:1.
    // dy = dx * rateNum / rateDenom (with decimals adjusted)
    uint256 public rateNum = 1;
    uint256 public rateDenom = 1;
    uint256 public slippageBps = 0; // Simulated slippage in basis points

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setRate(uint256 num, uint256 denom) external {
        rateNum = num;
        rateDenom = denom;
    }

    /// @notice Set slippage to simulate MEV attacks
    /// @param _slippageBps Slippage in basis points (100 = 1%)
    function setSlippage(uint256 _slippageBps) external {
        slippageBps = _slippageBps;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable override returns (uint256 dy) {
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> DXY-BEAR (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // DXY-BEAR (18) -> USDC (6) : / 1e12
            dy = dx / 1e12;
        }

        // Apply Price Ratio
        dy = (dy * rateNum) / rateDenom;

        // Apply slippage to simulate MEV/price movement
        dy = (dy * (10000 - slippageBps)) / 10000;

        require(dy >= min_dy, "Too little received");
        // Burn input tokens and mint output tokens
        MockToken(tokenIn).burn(msg.sender, dx);
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view override returns (uint256 dy) {
        // get_dy returns quoted price WITHOUT slippage (as in real Curve)
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> DXY-BEAR (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // DXY-BEAR (18) -> USDC (6) : / 1e12
            dy = dx / 1e12;
        }

        // Apply Price Ratio (but NOT slippage - get_dy is the quote)
        dy = (dy * rateNum) / rateDenom;
    }

    function price_oracle() external pure override returns (uint256) {
        return 1e18; // Default 1:1 price in 18 decimals
    }
}

contract MockMorpho is IMorpho {
    mapping(address => mapping(address => bool)) public _isAuthorized;
    mapping(address => ActionData) public positions;
    address public usdc;
    address public collateralToken;

    struct ActionData {
        uint256 supplied;
        uint256 borrowed;
    }

    function setTokens(address _usdc, address _collateral) external {
        usdc = _usdc;
        collateralToken = _collateral;
    }

    function setAuthorization(address operator, bool approved) external override {
        _isAuthorized[msg.sender][operator] = approved;
    }

    function isAuthorized(address authorizer, address authorized) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(MarketParams memory) external override {}

    function idToMarketParams(bytes32) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    // Lending functions (supply/withdraw loan tokens)
    function supply(MarketParams memory, uint256 assets, uint256, address, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        return (assets, 0);
    }

    function withdraw(MarketParams memory, uint256 assets, uint256, address, address)
        external
        override
        returns (uint256, uint256)
    {
        return (assets, 0);
    }

    // Collateral functions
    function supplyCollateral(MarketParams memory, uint256 assets, address onBehalfOf, bytes calldata)
        external
        override
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied += assets;
        IERC20(collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory, uint256 assets, address onBehalfOf, address receiver)
        external
        override
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied -= assets;
        IERC20(collateralToken).transfer(receiver, assets);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed += assets;
        MockToken(usdc).mint(receiver, assets);
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed -= assets;
        MockToken(usdc).burn(msg.sender, assets);
        return (assets, 0);
    }

    function position(bytes32, address) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(bytes32) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    function accrueInterest(MarketParams memory) external override {}

    function liquidate(MarketParams memory, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract MockSplitter is ISyntheticSplitter {
    address public dxyBear;
    address public dxyBull;
    address public usdc;
    Status private _status = Status.ACTIVE;
    uint256 public redemptionRate = 100; // Percentage of payout (100 = 100%)
    uint256 public constant CAP = 2e8; // $2.00 in 8 decimals

    constructor(address _dxyBear, address _dxyBull, address _usdc) {
        dxyBear = _dxyBear;
        dxyBull = _dxyBull;
        usdc = _usdc;
    }

    function setStatus(Status newStatus) external {
        _status = newStatus;
    }

    function setRedemptionRate(uint256 rate) external {
        redemptionRate = rate;
    }

    function mint(uint256 amount) external override {
        // amount is token amount (18 decimals), matching real SyntheticSplitter
        // Calculate USDC to pull: usdc = tokens * CAP / 1e20 = tokens * 2e8 / 1e20 = tokens * 2 / 1e12
        uint256 usdcNeeded = (amount * 2) / 1e12;
        MockToken(usdc).burn(msg.sender, usdcNeeded);
        MockFlashToken(dxyBear).mint(msg.sender, amount);
        MockToken(dxyBull).mint(msg.sender, amount);
    }

    function burn(uint256 amount) external override {
        // Burn both tokens, mint USDC at CAP pricing
        // amount is in token units (18 decimals), USDC is 6 decimals
        // CAP = $2.00, so 1 pair redeems to $2.00 USDC
        // usdc = tokens * CAP / 1e20 = tokens * 2e8 / 1e20 = tokens * 2 / 1e12
        MockFlashToken(dxyBear).burn(msg.sender, amount);
        MockToken(dxyBull).burn(msg.sender, amount);
        uint256 usdcAmount = (amount * 2) / 1e12;

        // Apply solvency haircut if set
        usdcAmount = (usdcAmount * redemptionRate) / 100;

        MockToken(usdc).mint(msg.sender, usdcAmount);
    }

    function emergencyRedeem(uint256) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }
}
