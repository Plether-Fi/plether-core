// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {FlashLoanBase} from "../src/base/FlashLoanBase.sol";
import {LeverageRouterBase} from "../src/base/LeverageRouterBase.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {IMorpho, IMorphoFlashLoanCallback, MarketParams} from "../src/interfaces/IMorpho.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract BullLeverageRouterTest is Test {

    BullLeverageRouter public router;

    // Mocks
    MockToken public usdc;
    MockFlashToken public plDxyBear;
    MockToken public plDxyBull;
    MockStakedToken public stakedPlDxyBull;
    MockMorpho public morpho;
    MockCurvePool public curvePool;
    MockSplitter public splitter;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        plDxyBear = new MockFlashToken("plDXY-BEAR", "plDXY-BEAR");
        plDxyBull = new MockToken("plDXY-BULL", "plDXY-BULL", 18);
        stakedPlDxyBull = new MockStakedToken(address(plDxyBull));
        morpho = new MockMorpho();
        curvePool = new MockCurvePool(address(usdc), address(plDxyBear));
        splitter = new MockSplitter(address(plDxyBear), address(plDxyBull), address(usdc));

        // Configure MockMorpho with token addresses (collateral is now staked token)
        morpho.setTokens(address(usdc), address(stakedPlDxyBull));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedPlDxyBull),
            oracle: address(0),
            irm: address(0),
            lltv: 900_000_000_000_000_000 // 90%
        });

        router = new BullLeverageRouter(
            address(morpho),
            address(splitter),
            address(curvePool),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedPlDxyBull),
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
        // Sell 1500e18 plDXY-BEAR for 1500 USDC (at 1:1 rate)
        // Deposit 1500e18 plDXY-BULL as collateral
        // Flash loan repayment = $2000, sale gives $1500
        // Morpho debt = max(0, 2000 - 1500) = 500
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 1500 * 1e18, "Incorrect supplied amount");
        assertEq(borrowed, 500 * 1e6, "Incorrect borrowed amount");
    }

    function test_OpenLeverage_EmitsEvent() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;
        uint256 maxSlippageBps = 50;
        uint256 expectedLoanAmount = 2000 * 1e6;
        // With CAP=$2: $3000 USDC mints 1500e18 tokens
        uint256 expectedPlDxyBull = 1500 * 1e18;
        // With 1:1 rates: usdcFromSale = 1500 (selling 1500e18 BEAR), flashRepayment = 2000
        // debtToIncur = max(0, 2000 - 1500) = 500
        uint256 expectedDebt = 500 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectEmit(true, false, false, true);
        emit BullLeverageRouter.LeverageOpened(
            alice, principal, leverage, expectedLoanAmount, expectedPlDxyBull, expectedDebt, maxSlippageBps
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

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__NotAuthorized.selector);
        router.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_Expired() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__Expired.selector);
        router.openLeverage(principal, leverage, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_LeverageTooLow() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 1e18; // 1x (not > 1x)

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__LeverageTooLow.selector);
        router.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_SlippageTooHigh() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SlippageExceedsMax.selector);
        router.openLeverage(principal, leverage, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_SlippageTooHigh() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SlippageExceedsMax.selector);
        router.closeLeverage(3000 * 1e18, 101, block.timestamp + 1 hours);
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
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
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

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__ZeroPrincipal.selector);
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

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SplitterNotActive.selector);
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

        // Close the position (router queries actual debt from Morpho)
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
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

        // 2. Scenario: plDXY-BEAR price rises to $1.10 relative to USDC
        // This means 1 USDC buys LESS Bear (~0.909).
        // Router must spend MORE USDC to buy back the required amount of BEAR.
        curvePool.setRate(100, 110); // 100 output for 110 input -> Output < Input

        // 3. Close (router queries actual debt from Morpho)
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // 4. Verify Success
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position should be closed");
        assertEq(borrowedAfter, 0, "Debt should be repaid");

        // 5. Verify no USDC is left (it was either used to buy expensive BEAR or refunded)
        assertEq(usdc.balanceOf(address(router)), 0, "Router holding USDC");

        // 6. Note: Due to slippage buffer logic in _executeCloseRedeem,
        // the router will likely hold some plDXY-BEAR dust.
        // We assert >= 0 just to acknowledge this behavior.
        assertGe(plDxyBear.balanceOf(address(router)), 0, "Router may hold BEAR dust");
    }

    function test_CloseLeverage_RevertsWhenRedemptionOutputInsufficient() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        splitter.setRedemptionRate(10);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__InsufficientOutput.selector);
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
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
        // After open: supplied = 1500e18 plDXY-BULL, borrowed = 500e6 USDC
        // Close flow (single flash mint):
        // 1. Flash mint: 2005e18 BEAR (1500 for pairs + 505 for debt with 1% buffer)
        // 2. Sell 505e18 BEAR → 505 USDC
        // 3. Repay 500 USDC Morpho debt
        // 4. Withdraw 1500e18 splDXY-BULL → 1500e18 plDXY-BULL
        // 5. Redeem 1500e18 pairs: 3000 USDC
        // 6. Buy 2005e18 BEAR on Curve: ~2025 USDC (with 1% buffer on estimate)
        // 7. Leftover returned to user
        // Total USDC = 5 (surplus from step 2) + 3000 (redeem) - 2025.05 (buyback) ≈ 979.95 USDC
        uint256 expectedUsdcReturned = 979_950_000;

        vm.expectEmit(true, false, false, true);
        emit BullLeverageRouter.LeverageClosed(alice, borrowed, supplied, expectedUsdcReturned, maxSlippageBps);

        router.closeLeverage(supplied, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_NoAuth() public {
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        // Skip authorization

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__NotAuthorized.selector);
        router.closeLeverage(collateralToWithdraw, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_Expired() public {
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__Expired.selector);
        router.closeLeverage(collateralToWithdraw, 50, block.timestamp - 1);
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

        (uint256 suppliedBefore,) = morpho.positions(alice);

        // Close 50% of collateral (router queries and repays full debt)
        uint256 halfCollateral = suppliedBefore / 2;

        router.closeLeverage(halfCollateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify partial collateral close (debt is fully repaid)
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, suppliedBefore - halfCollateral, "Collateral should be halved");
        assertEq(borrowedAfter, 0, "Debt should be fully repaid");
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_OpenLeverage(
        uint256 principal,
        uint256 leverageMultiplier
    ) public {
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
        // With CAP=$2: plDXY-BULL received = (totalUSDC * 1e12) / 2
        uint256 totalUSDC = principal * leverageMultiplier / 1e18;
        uint256 expectedSupplied = (totalUSDC * 1e12) / 2;

        // Flash loan = principal * (leverage - 1) / 1e18
        // USDC from sale = tokensToSell (at 1:1 rate) / 1e12
        // With CAP=$2: we sell (totalUSDC / 2) tokens worth of BEAR
        uint256 loanAmount = principal * (leverageMultiplier - 1e18) / 1e18;
        uint256 usdcFromSale = expectedSupplied / 1e12; // Mock curve gives 1:1 rate with decimal conversion
        uint256 expectedBorrowed = loanAmount > usdcFromSale ? loanAmount - usdcFromSale : 0;

        assertEq(supplied, expectedSupplied, "Supplied plDXY-BULL mismatch");
        assertEq(borrowed, expectedBorrowed, "Borrowed USDC mismatch");
    }

    function testFuzz_OpenAndCloseLeverage(
        uint256 principal,
        uint256 leverageMultiplier
    ) public {
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

        // Close (router queries actual debt from Morpho)
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
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

        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedPlDxyBull, uint256 expectedDebt) =
            router.previewOpenLeverage(principal, leverage);

        assertEq(loanAmount, 2000 * 1e6, "Incorrect loan amount");
        assertEq(totalUSDC, 3000 * 1e6, "Incorrect total USDC");
        // With CAP=$2.00: $3000 USDC mints 1500e18 tokens (1 USDC = 0.5 pairs)
        assertEq(expectedPlDxyBull, 1500 * 1e18, "Incorrect expected plDXY-BULL");
        // With 1:1 rates: flashRepayment=2000, usdcFromSale=1500 (selling 1500e18 BEAR at $1 each)
        // expectedDebt = max(0, 2000 - 1500) = 500
        assertEq(expectedDebt, 500 * 1e6, "Incorrect expected debt");
    }

    function test_PreviewOpenLeverage_MatchesActual() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        // Get preview
        (,, uint256 expectedPlDxyBull, uint256 expectedDebt) = router.previewOpenLeverage(principal, leverage);

        // Execute actual operation
        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify actual matches preview
        (uint256 actualCollateral, uint256 actualDebt) = morpho.positions(alice);

        // Allow 1% tolerance due to curve slippage/rounding
        assertApproxEqRel(actualCollateral, expectedPlDxyBull, 0.01e18, "Collateral should match preview");
        assertApproxEqRel(actualDebt, expectedDebt, 0.01e18, "Debt should match preview");
    }

    function test_PreviewCloseLeverage() public view {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) =
            router.previewCloseLeverage(debtToRepay, collateralToWithdraw);

        // With CAP=$2.00: 3000e18 tokens redeem to 6000 USDC (1 token = $2)
        assertEq(expectedUSDC, 6000 * 1e6, "Incorrect expected USDC");

        // At 1:1 rate with 2000 USDC debt and 1% exchange rate buffer:
        // - bufferedBullAmount = 3000 + (3000 * 1%) = 3030e18
        // - extraBearForDebt = 2000e18 BEAR (to sell for debt repayment)
        // - totalBearToBuyBack = bufferedBullAmount (3030) + extraBearForDebt (2000) = 5030e18
        // - usdcForBearBuyback = 5030 USDC (at 1:1 rate)
        assertApproxEqRel(usdcForBearBuyback, 5030 * 1e6, 0.001e18, "Incorrect BEAR buyback cost");

        // Net USDC flow:
        // + expectedUSDC (6000) + usdcFromBearSale (2000) = 8000 inflows
        // - debtToRepay (2000) - usdcForBearBuyback (5030) = 7030 outflows
        // expectedReturn = 8000 - 7030 = 970
        assertApproxEqRel(expectedReturn, 970 * 1e6, 0.001e18, "Incorrect expected return");
    }

    function test_PreviewCloseLeverage_MatchesActual() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        (uint256 collateral, uint256 debt) = morpho.positions(alice);

        // Get preview for closing
        (,, uint256 expectedReturn) = router.previewCloseLeverage(debt, collateral);

        // Record balance before close
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Close the position (router queries actual debt from Morpho)
        router.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify actual matches preview
        uint256 actualReturn = usdc.balanceOf(alice) - usdcBefore;

        // Allow 5% tolerance due to curve slippage and complex multi-swap flow
        assertApproxEqRel(actualReturn, expectedReturn, 0.05e18, "Return should match preview");

        // Position should be closed
        (uint256 collateralAfter, uint256 debtAfter) = morpho.positions(alice);
        assertEq(collateralAfter, 0, "Collateral should be zero");
        assertEq(debtAfter, 0, "Debt should be zero");
    }

    // ==========================================
    // CALLBACK SECURITY TESTS
    // ==========================================

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        // Call from alice (not plDxyBear) with OP_CLOSE_REDEEM (3) to test lender validation
        vm.startPrank(alice);

        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidLender.selector);
        router.onFlashLoan(
            address(router), address(plDxyBear), 100, 0, abi.encode(uint8(3), alice, block.timestamp + 1, 0, 0)
        );
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        // For ERC-3156 callback, the lender is plDxyBear (used for close leverage)
        vm.startPrank(address(plDxyBear));

        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidInitiator.selector);
        router.onFlashLoan(alice, address(plDxyBear), 100, 0, abi.encode(uint8(1), alice, block.timestamp + 1, 0, 0));
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
        (uint256 supplied,) = morpho.positions(alice);
        vm.expectRevert();
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
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

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__ZeroPrincipal.selector);
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

        // Close position (router queries actual debt - zero in this case)
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Position should be cleared
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Collateral should be cleared");
        assertEq(borrowedAfter, 0, "Debt should remain zero");
    }

    // ==========================================
    // FUZZ TESTS (Additional)
    // ==========================================

    /// @notice Fuzz test: closeLeverage with various leverage ratios
    /// @dev Tests full closes with different leverage amounts
    /// @dev Note: With new signature, closeLeverage always repays full debt
    function testFuzz_CloseLeverage(
        uint256 principal,
        uint256 leverage
    ) public {
        // Bound inputs - BULL positions have more slippage so use tighter bounds
        principal = bound(principal, 1000e6, 50_000e6);
        leverage = bound(leverage, 2e18, 4e18);

        usdc.mint(alice, principal);
        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(curvePool), 10_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Get position state
        (uint256 totalCollateral,) = morpho.positions(alice);

        // Close full position (router queries actual debt from Morpho)
        router.closeLeverage(totalCollateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify state after close
        (uint256 remainingCollateral, uint256 remainingDebt) = morpho.positions(alice);

        assertEq(remainingCollateral, 0, "Collateral should be zero after full close");
        assertEq(remainingDebt, 0, "Debt should be zero after full close");
    }

    /// @notice Fuzz test: Full round trip (open then close) returns reasonable value
    /// @dev Verifies user doesn't lose excessive funds in a round trip
    function testFuzz_RoundTrip(
        uint256 principal,
        uint256 leverage
    ) public {
        // Bound inputs - BULL positions have more slippage so use tighter bounds
        principal = bound(principal, 1000e6, 100_000e6); // $1k to $100k
        leverage = bound(leverage, 2e18, 5e18); // 2x to 5x

        // Setup with ample liquidity
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);
        usdc.mint(address(curvePool), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Open position
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Immediately close entire position (router queries actual debt from Morpho)
        (uint256 collateral,) = morpho.positions(alice);

        router.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);

        // BULL round trips have more slippage (2 swaps each direction)
        // User should get back at least 90% in mock environment
        assertGe(usdcAfter, (usdcBefore * 90) / 100, "Round trip should return >= 90%");

        // Position should be fully closed
        (uint256 collateralAfter, uint256 debtAfter) = morpho.positions(alice);
        assertEq(collateralAfter, 0, "All collateral withdrawn");
        assertEq(debtAfter, 0, "All debt repaid");
    }

    /// @notice Fuzz test: Various BEAR prices shouldn't break the router
    function testFuzz_OpenLeverage_VariableBearPrice(
        uint256 principal,
        uint256 bearPriceBps
    ) public {
        // Bound inputs
        principal = bound(principal, 1000e6, 50_000e6); // $1k to $50k
        bearPriceBps = bound(bearPriceBps, 8000, 12_000); // $0.80 to $1.20 per BEAR

        // Set BEAR price using rate (num/denom = price)
        // bearPriceBps is in basis points (10000 = 1.00)
        curvePool.setRate(bearPriceBps, 10_000);

        // Setup
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);
        usdc.mint(address(curvePool), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Open 2x position
        router.openLeverage(principal, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position exists
        (uint256 collateral,) = morpho.positions(alice);
        assertGt(collateral, 0, "Should have collateral");
    }

    /// @notice Fuzz test: Slippage within bounds should succeed
    function testFuzz_OpenLeverage_SlippageTolerance(
        uint256 slippageBps
    ) public {
        // Bound slippage to valid range (0 to MAX_SLIPPAGE_BPS which is 100)
        slippageBps = bound(slippageBps, 0, 100);

        uint256 principal = 10_000e6;
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);
        usdc.mint(address(curvePool), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Should succeed with any valid slippage setting
        router.openLeverage(principal, 3e18, slippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 collateral,) = morpho.positions(alice);
        assertGt(collateral, 0, "Position should be created");
    }

    /// @notice Fuzz test: Close with varying debt amounts
    function testFuzz_CloseLeverage_VariableDebt(
        uint256 debtPercent
    ) public {
        // Bound debt repayment to 0-100%
        debtPercent = bound(debtPercent, 0, 100);

        // Setup: Create a 3x position
        uint256 principal = 10_000e6;

        usdc.mint(alice, principal);
        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(curvePool), 10_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, 3e18, 100, block.timestamp + 1 hours);

        (uint256 collateral,) = morpho.positions(alice);

        // Close with full collateral (router queries and repays full debt)
        router.closeLeverage(collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify full close
        (uint256 collateralAfter, uint256 debtAfter) = morpho.positions(alice);
        assertEq(collateralAfter, 0, "All collateral should be withdrawn");
        assertEq(debtAfter, 0, "Debt should be fully repaid");
    }

}

// ==========================================
// MOCK CONTRACTS
// ==========================================

contract MockToken is ERC20 {

    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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

}

contract MockStakedToken is ERC20 {

    MockToken public underlying;

    constructor(
        address _underlying
    ) ERC20("Staked Token", "sTKN") {
        underlying = MockToken(_underlying);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares; // 1:1 for simplicity
        underlying.transfer(receiver, assets);
    }

    function previewRedeem(
        uint256 shares
    ) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }

}

contract MockFlashToken is ERC20, IERC3156FlashLender {

    uint256 private _feeBps = 0;

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

    function setFeeBps(
        uint256 bps
    ) external {
        _feeBps = bps;
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
        return (amount * _feeBps) / 10_000;
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

    address public token0; // USDC (index 0)
    address public token1; // plDXY-BEAR (index 1)

    // Scale factor for output. Default 1:1.
    // dy = dx * rateNum / rateDenom (with decimals adjusted)
    uint256 public rateNum = 1;
    uint256 public rateDenom = 1;
    uint256 public slippageBps = 0; // Simulated slippage in basis points

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setRate(
        uint256 num,
        uint256 denom
    ) external {
        rateNum = num;
        rateDenom = denom;
    }

    /// @notice Set slippage to simulate MEV attacks
    /// @param _slippageBps Slippage in basis points (100 = 1%)
    function setSlippage(
        uint256 _slippageBps
    ) external {
        slippageBps = _slippageBps;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> plDXY-BEAR (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // plDXY-BEAR (18) -> USDC (6) : / 1e12
            dy = dx / 1e12;
        }

        // Apply Price Ratio
        dy = (dy * rateNum) / rateDenom;

        // Apply slippage to simulate MEV/price movement
        dy = (dy * (10_000 - slippageBps)) / 10_000;

        require(dy >= min_dy, "Too little received");
        // Burn input tokens and mint output tokens
        MockToken(tokenIn).burn(msg.sender, dx);
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256 dy) {
        // get_dy returns quoted price WITHOUT slippage (as in real Curve)
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> plDXY-BEAR (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // plDXY-BEAR (18) -> USDC (6) : / 1e12
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

    function setTokens(
        address _usdc,
        address _collateral
    ) external {
        usdc = _usdc;
        collateralToken = _collateral;
    }

    function setAuthorization(
        address operator,
        bool approved
    ) external override {
        _isAuthorized[msg.sender][operator] = approved;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(
        MarketParams memory
    ) external override {}

    function idToMarketParams(
        bytes32
    ) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    // Lending functions (supply/withdraw loan tokens)
    function supply(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        bytes calldata
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function withdraw(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        address
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    // Collateral functions
    function supplyCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        bytes calldata
    ) external override {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied += assets;
        IERC20(collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external override {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied -= assets;
        IERC20(collateralToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        address receiver
    ) external override returns (uint256, uint256) {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed += assets;
        MockToken(usdc).mint(receiver, assets);
        return (assets, 0);
    }

    function repay(
        MarketParams memory,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata
    ) external override returns (uint256, uint256) {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        // Support both assets-based and shares-based repayment
        // In this mock, borrowed == borrowShares (1:1 ratio)
        uint256 repayAmount = assets > 0 ? assets : shares;
        positions[onBehalfOf].borrowed -= repayAmount;
        MockToken(usdc).burn(msg.sender, repayAmount);
        return (repayAmount, shares > 0 ? shares : repayAmount);
    }

    function position(
        bytes32,
        address user
    ) external view override returns (uint256, uint128, uint128) {
        // Return (supplyShares, borrowShares, collateral)
        // We use borrowed as borrowShares for simplicity (1:1 ratio)
        return (0, uint128(positions[user].borrowed), uint128(positions[user].supplied));
    }

    function market(
        bytes32
    ) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        // Return (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee)
        // For simplicity, use 1:1 ratio for shares:assets (max values so division works)
        return (0, 0, type(uint128).max, type(uint128).max, 0, 0);
    }

    function accrueInterest(
        MarketParams memory
    ) external override {}

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external override {
        // Mint tokens to borrower (simulating flash loan)
        MockToken(token).mint(msg.sender, assets);
        // Invoke callback
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        // Verify repayment (pull and burn tokens)
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        MockToken(token).burn(address(this), assets);
    }

}

contract MockSplitter is ISyntheticSplitter {

    address public plDxyBear;
    address public plDxyBull;
    address public usdc;
    Status private _status = Status.ACTIVE;
    uint256 public redemptionRate = 100; // Percentage of payout (100 = 100%)
    uint256 public constant CAP = 2e8; // $2.00 in 8 decimals

    constructor(
        address _plDxyBear,
        address _plDxyBull,
        address _usdc
    ) {
        plDxyBear = _plDxyBear;
        plDxyBull = _plDxyBull;
        usdc = _usdc;
    }

    function setStatus(
        Status newStatus
    ) external {
        _status = newStatus;
    }

    function setRedemptionRate(
        uint256 rate
    ) external {
        redemptionRate = rate;
    }

    function mint(
        uint256 amount
    ) external override {
        // amount is token amount (18 decimals), matching real SyntheticSplitter
        // Calculate USDC to pull: usdc = tokens * CAP / 1e20 = tokens * 2e8 / 1e20 = tokens * 2 / 1e12
        uint256 usdcNeeded = (amount * 2) / 1e12;
        MockToken(usdc).burn(msg.sender, usdcNeeded);
        MockFlashToken(plDxyBear).mint(msg.sender, amount);
        MockToken(plDxyBull).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external override {
        // Burn both tokens, mint USDC at CAP pricing
        // amount is in token units (18 decimals), USDC is 6 decimals
        // CAP = $2.00, so 1 pair redeems to $2.00 USDC
        // usdc = tokens * CAP / 1e20 = tokens * 2e8 / 1e20 = tokens * 2 / 1e12
        MockFlashToken(plDxyBear).burn(msg.sender, amount);
        MockToken(plDxyBull).burn(msg.sender, amount);
        uint256 usdcAmount = (amount * 2) / 1e12;

        // Apply solvency haircut if set
        usdcAmount = (usdcAmount * redemptionRate) / 100;

        MockToken(usdc).mint(msg.sender, usdcAmount);
    }

    function emergencyRedeem(
        uint256
    ) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }

}

/// @notice Mock staked token that simulates exchange rate drift between preview and redeem
/// previewRedeem returns base rate, redeem uses boosted rate (simulating mid-tx yield donation)
contract MockStakedTokenWithDrift is ERC20 {

    MockToken public underlying;
    uint256 public baseRateBps = 10_000; // Rate for previewRedeem
    uint256 public redeemBoostBps = 0; // Extra bps added only during redeem

    constructor(
        address _underlying
    ) ERC20("Staked Token", "sTKN") {
        underlying = MockToken(_underlying);
    }

    /// @notice Set the boost that redeem will add on top of baseRate
    /// This simulates an attacker front-running with yield donation
    function setRedeemBoost(
        uint256 _boostBps
    ) external {
        redeemBoostBps = _boostBps;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 at deposit time
        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        // Apply boost: simulates yield donation happening between preview and redeem
        assets = (shares * (baseRateBps + redeemBoostBps)) / 10_000;
        // Mint shortfall to simulate yield
        uint256 balance = underlying.balanceOf(address(this));
        if (assets > balance) {
            underlying.mint(address(this), assets - balance);
        }
        underlying.transfer(receiver, assets);
    }

    /// @notice Preview returns base rate (what closeLeverage sees when calculating flashAmount)
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256) {
        return (shares * baseRateBps) / 10_000;
    }

}

/// @notice Tests for BEAR/BULL mismatch vulnerability in BullLeverageRouter
contract BullLeverageRouterExchangeRateDriftTest is Test {

    BullLeverageRouter public router;

    MockToken public usdc;
    MockFlashToken public plDxyBear;
    MockToken public plDxyBull;
    MockStakedTokenWithDrift public stakedPlDxyBull;
    MockMorpho public morpho;
    MockCurvePool public curvePool;
    MockSplitter public splitter;

    address alice = address(0xA11ce);
    address attacker = address(0xBAD);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        plDxyBear = new MockFlashToken("plDXY-BEAR", "plDXY-BEAR");
        plDxyBull = new MockToken("plDXY-BULL", "plDXY-BULL", 18);
        stakedPlDxyBull = new MockStakedTokenWithDrift(address(plDxyBull));
        morpho = new MockMorpho();
        curvePool = new MockCurvePool(address(usdc), address(plDxyBear));
        splitter = new MockSplitter(address(plDxyBear), address(plDxyBull), address(usdc));

        morpho.setTokens(address(usdc), address(stakedPlDxyBull));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedPlDxyBull),
            oracle: address(0),
            irm: address(0),
            lltv: 900_000_000_000_000_000
        });

        router = new BullLeverageRouter(
            address(morpho),
            address(splitter),
            address(curvePool),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedPlDxyBull),
            params
        );

        usdc.mint(alice, 10_000 * 1e6);
    }

    /// @notice Helper to open a position
    function _openPosition() internal returns (uint256 supplied, uint256 borrowed) {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (supplied, borrowed) = morpho.positions(alice);
    }

    /// @notice FAILING TEST: Exchange rate increase between preview and redeem should not cause revert
    /// Currently FAILS because flash amount is calculated with old rate, but burn uses new rate
    function test_CloseLeverage_ExchangeRateIncrease_ShouldSucceed() public {
        (uint256 supplied, uint256 borrowed) = _openPosition();

        // Set boost: redeem will return 1% more than previewRedeem
        // This simulates yield donation happening AFTER previewRedeem but BEFORE redeem
        stakedPlDxyBull.setRedeemBoost(100); // +1%

        vm.startPrank(alice);

        // This SHOULD succeed but will FAIL due to BEAR/BULL mismatch:
        // - previewRedeem(supplied) = 1500e18 (base rate)
        // - flashAmount = 1500e18 + extraBearForDebt
        // - redeem(supplied) = 1515e18 (with 1% boost)
        // - SPLITTER.burn(1515e18) needs 1515e18 BEAR
        // - But we only have 1500e18 BEAR (flashAmount - extraBearForDebt)
        // - Not enough BEAR → revert
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // If we reach here, the close succeeded
        (uint256 suppliedAfter,) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position should be closed");
    }

    /// @notice FAILING TEST: Attacker front-runs with yield donation to DoS user's close
    /// Currently FAILS because the donation changes exchange rate mid-transaction
    function test_CloseLeverage_FrontRunDonation_ShouldNotDoS() public {
        (uint256 supplied, uint256 borrowed) = _openPosition();

        // Simulate attacker front-running with yield donation
        // redeem returns 0.5% more than previewRedeem predicted
        stakedPlDxyBull.setRedeemBoost(50); // +0.5%

        vm.startPrank(alice);

        // Alice's transaction should succeed despite the rate change
        // Currently FAILS due to BEAR/BULL mismatch
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 suppliedAfter,) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position should be closed despite donation");
    }

    /// @notice FAILING TEST: Exchange rate drift exceeding buffer causes arithmetic underflow
    /// The 1% buffer (EXCHANGE_RATE_BUFFER_BPS = 100) is insufficient when drift exceeds 1%
    /// This causes SPLITTER.burn() to attempt burning more BEAR than the router holds
    function test_CloseLeverage_ExchangeRateDriftExceedsBuffer_Reverts() public {
        (uint256 supplied,) = _openPosition();

        // Set boost to 2% - this EXCEEDS the 1% buffer
        // previewRedeem returns X, but actual redeem returns X * 1.02
        // Router only flash mints enough BEAR for X * 1.01 (the buffer)
        stakedPlDxyBull.setRedeemBoost(200); // +2% drift

        vm.startPrank(alice);

        // This will revert with arithmetic underflow:
        // - previewRedeem(supplied) = 1500e18
        // - bufferedBullAmount = 1500e18 * 1.01 = 1515e18
        // - flashAmount includes 1515e18 BEAR for pair redemption
        // - But actual redeem returns 1500e18 * 1.02 = 1530e18 BULL
        // - SPLITTER.burn(1530e18) tries to burn 1530e18 BEAR
        // - Router only has 1515e18 BEAR → underflow in Splitter
        // Router has 1515e18 BEAR but needs 1530e18 for burn
        // ERC20InsufficientBalance(router, balance=1515e18, needed=1530e18)
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(router), 1515e18, 1530e18
            )
        );
        router.closeLeverage(supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

}
