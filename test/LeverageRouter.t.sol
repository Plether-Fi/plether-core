// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import {LeverageRouterBase} from "../src/base/LeverageRouterBase.sol";
import "../src/interfaces/ICurvePool.sol";
import {IMorpho, IMorphoFlashLoanCallback, MarketParams} from "../src/interfaces/IMorpho.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public router;

    // Mocks
    MockToken public usdc;
    MockToken public dxyBear;
    MockStakedToken public stakedDxyBear;
    MockCurvePool public curvePool;
    MockMorpho public morpho;

    // FIX: Make params a state variable so we can reuse it correctly
    MarketParams public params;

    address alice = address(0xA11ce);

    function setUp() public {
        usdc = new MockToken("USDC", "USDC");
        dxyBear = new MockToken("DXY-BEAR", "BEAR");
        stakedDxyBear = new MockStakedToken(address(dxyBear));
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        morpho = new MockMorpho(address(usdc), address(stakedDxyBear));

        // FIX: Assign to state variable
        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedDxyBear),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        router = new LeverageRouter(
            address(morpho), address(curvePool), address(usdc), address(dxyBear), address(stakedDxyBear), params
        );

        usdc.mint(alice, 1000 * 1e6);
        // Fund Morpho for flash loans
        usdc.mint(address(morpho), 100_000 * 1e6);
    }

    // ==========================================
    // TESTS
    // ==========================================

    function test_OpenLeverage_Success() public {
        // Alice has 1000 USDC. Wants 3x (3e18).
        // Loan = 2000 USDC. Total = 3000 USDC.
        // Bear Price $1.00. 3000 USDC -> 3000 BEAR.

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true); // CRITICAL STEP

        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Check Morpho State
        // Alice should have Collateral = 3000 BEAR
        // Alice should have Debt = 2000 USDC
        assertEq(morpho.collateralBalance(alice), 3000 * 1e18, "Collateral mismatch");
        assertEq(morpho.borrowBalance(alice), 2000 * 1e6, "Debt mismatch");
    }

    function test_OpenLeverage_BearExpensive() public {
        // Bear Price $1.50.
        curvePool.setPrice(1_500_000);

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true);

        // 3x Leverage on $1000 = Borrow $2000. Total $3000 USDC.
        // $3000 USDC / $1.50 = 2000 BEAR.
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(morpho.collateralBalance(alice), 2000 * 1e18, "Expensive: Collateral mismatch");
    }

    function test_CloseLeverage_Success() public {
        // Setup existing position: 3000 sDXY-BEAR Collateral, 2000 USDC Debt
        usdc.mint(address(morpho), 2000 * 1e6); // Fund morpho for borrowing

        vm.startPrank(alice);
        // Manually create position in mock: mint BEAR -> stake to sBEAR -> supply to Morpho
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        stakedDxyBear.deposit(3000 * 1e18, alice); // Alice gets 3000 sDXY-BEAR

        stakedDxyBear.approve(address(morpho), 3000 * 1e18);
        morpho.supplyCollateral(params, 3000 * 1e18, alice, "");
        morpho.borrow(params, 2000 * 1e6, 0, alice, alice); // Alice holds the debt

        // Now Close
        morpho.setAuthorization(address(router), true);
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(morpho.collateralBalance(alice), 0, "Collateral not cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt not cleared");
        assertGt(usdc.balanceOf(alice), 0, "Alice got no money back");
    }

    /// @notice Test closing a position with zero debt (no flash loan needed)
    function test_CloseLeverage_ZeroDebt_Success() public {
        // Setup: Alice has collateral but NO debt
        // This tests the _executeCloseNoDebt() path
        vm.startPrank(alice);

        // Mint BEAR -> stake to sBEAR -> supply to Morpho as collateral
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        stakedDxyBear.deposit(3000 * 1e18, alice);

        stakedDxyBear.approve(address(morpho), 3000 * 1e18);
        morpho.supplyCollateral(params, 3000 * 1e18, alice, "");
        // NOTE: No borrow() call - Alice has collateral but zero debt

        // Verify starting state
        assertEq(morpho.collateralBalance(alice), 3000 * 1e18, "Should have collateral");
        assertEq(morpho.borrowBalance(alice), 0, "Should have zero debt");

        // Close with zero debt - should use _executeCloseNoDebt path
        morpho.setAuthorization(address(router), true);
        uint256 usdcBefore = usdc.balanceOf(alice);

        router.closeLeverage(0, 3000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify: collateral withdrawn, USDC returned to Alice
        assertEq(morpho.collateralBalance(alice), 0, "Collateral should be cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt should remain zero");
        assertGt(usdc.balanceOf(alice), usdcBefore, "Alice should receive USDC");
    }

    /// @notice Test closing partial collateral with zero debt
    function test_CloseLeverage_ZeroDebt_PartialWithdraw() public {
        vm.startPrank(alice);

        // Setup: 3000 sBEAR collateral, 0 debt
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        stakedDxyBear.deposit(3000 * 1e18, alice);

        stakedDxyBear.approve(address(morpho), 3000 * 1e18);
        morpho.supplyCollateral(params, 3000 * 1e18, alice, "");

        morpho.setAuthorization(address(router), true);

        // Withdraw only 1000 of 3000 collateral
        router.closeLeverage(0, 1000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify: only partial collateral withdrawn
        assertEq(morpho.collateralBalance(alice), 2000 * 1e18, "Should have 2000 collateral remaining");
        assertGt(usdc.balanceOf(alice), 0, "Alice should receive some USDC");
    }

    function test_Unauthorized_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        // Forgot setAuthorization!

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__NotAuthorized.selector);
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_PreviewOpenLeverage_Success() public view {
        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBear, uint256 expectedDebt) =
            router.previewOpenLeverage(1000 * 1e6, 3e18);

        assertEq(loanAmount, 2000 * 1e6, "Loan amount mismatch");
        assertEq(totalUSDC, 3000 * 1e6, "Total USDC mismatch");
        assertGt(expectedDxyBear, 0, "Expected DXY-BEAR should be > 0");
        assertEq(expectedDebt, 2000 * 1e6, "Expected debt mismatch (no fee)");
    }

    function test_PreviewOpenLeverage_MatchesActual() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        // Get preview
        (, uint256 totalUSDC, uint256 expectedDxyBear, uint256 expectedDebt) =
            router.previewOpenLeverage(principal, leverage);

        // Execute actual operation
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), principal);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify actual matches preview
        uint256 actualCollateral = morpho.collateralBalance(alice);
        uint256 actualDebt = morpho.borrowBalance(alice);

        // Collateral is in staked tokens (18 decimals), preview gives DXY-BEAR amount
        // Allow 1% tolerance due to curve slippage/rounding
        assertApproxEqRel(actualCollateral, expectedDxyBear, 0.01e18, "Collateral should match preview");
        assertEq(actualDebt, expectedDebt, "Debt should match preview");
    }

    function test_PreviewOpenLeverage_RevertOnLowLeverage() public {
        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__LeverageTooLow.selector);
        router.previewOpenLeverage(1000 * 1e6, 1e18);
    }

    function test_PreviewCloseLeverage_Success() public view {
        (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) =
            router.previewCloseLeverage(2000 * 1e6, 3000 * 1e18);

        assertGt(expectedUSDC, 0, "Expected USDC should be > 0");
        assertEq(flashFee, 0, "Flash fee should be 0 (mock)");
        assertGt(expectedReturn, 0, "Expected return should be > 0");
    }

    function test_PreviewCloseLeverage_MatchesActual() public {
        // First open a position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), principal);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        // Get preview for closing
        (uint256 expectedUSDC,, uint256 expectedReturn) = router.previewCloseLeverage(debt, collateral);

        // Record balance before close
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Close the position
        router.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify actual matches preview
        uint256 actualReturn = usdc.balanceOf(alice) - usdcBefore;

        // Allow 2% tolerance due to curve slippage/rounding
        assertApproxEqRel(actualReturn, expectedReturn, 0.02e18, "Return should match preview");

        // Position should be closed
        assertEq(morpho.collateralBalance(alice), 0, "Collateral should be zero");
        assertEq(morpho.borrowBalance(alice), 0, "Debt should be zero");
    }

    function test_PreviewCloseLeverage_ZeroReturn() public view {
        // When debt is huge relative to collateral, return should be 0
        (,, uint256 expectedReturn) = router.previewCloseLeverage(10000 * 1e6, 100 * 1e18);
        assertEq(expectedReturn, 0, "Expected return should be 0 when insolvent");
    }

    function test_OpenLeverage_ZeroPrincipal_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__ZeroPrincipal.selector);
        router.openLeverage(0, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_LeverageAtMinimum_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // Leverage = 1x exactly should revert
        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__LeverageTooLow.selector);
        router.openLeverage(1000 * 1e6, 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_LeverageTooLow_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1e6); // 1 USDC

        // Leverage = 1.0001x with 1 USDC = 0.0001 USDC loan which rounds to 0
        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__LeverageTooLow.selector);
        router.openLeverage(1e6, 1e18 + 100, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Deadline_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__Expired.selector);
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_CloseLeverage_Deadline_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__Expired.selector);
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_SlippageExceedsMax_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SlippageExceedsMax.selector);
        router.openLeverage(1000 * 1e6, 3e18, 200, block.timestamp + 1 hours); // 200 bps > 100 max
        vm.stopPrank();
    }

    function test_CloseLeverage_SlippageExceedsMax_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__SlippageExceedsMax.selector);
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 200, block.timestamp + 1 hours); // 200 bps > 100 max
        vm.stopPrank();
    }

    /// @notice Test that swap reverts when Curve returns less than minOut (MEV protection)
    function test_OpenLeverage_MinOut_Enforced_Reverts() public {
        // Simulate MEV attack: price moves after get_dy but before exchange
        // get_dy returns expected amount, but exchange returns less
        curvePool.setSlippage(500); // 5% slippage during swap (exceeds 1% max)

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // Router calculates minOut based on get_dy - 1%, but actual swap gives 5% less
        vm.expectRevert("Too little received");
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test that close swap reverts when Curve returns less than minOut
    function test_CloseLeverage_MinOut_Enforced_Reverts() public {
        // Setup existing position
        usdc.mint(address(morpho), 2000 * 1e6);

        vm.startPrank(alice);
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        stakedDxyBear.deposit(3000 * 1e18, alice);
        stakedDxyBear.approve(address(morpho), 3000 * 1e18);
        morpho.supplyCollateral(params, 3000 * 1e18, alice, "");
        morpho.borrow(params, 2000 * 1e6, 0, alice, alice);

        // Simulate MEV attack during close
        curvePool.setSlippage(500); // 5% slippage

        morpho.setAuthorization(address(router), true);
        vm.expectRevert("Too little received");
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test that small slippage within tolerance succeeds
    function test_OpenLeverage_SlippageWithinTolerance_Succeeds() public {
        // 0.5% slippage is within 1% max tolerance
        curvePool.setSlippage(50); // 0.5% slippage

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // Should succeed because actual slippage (0.5%) < tolerance (1%)
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position created (with slightly less collateral due to slippage)
        assertGt(morpho.collateralBalance(alice), 0, "Should have collateral");
    }

    // ==========================================
    // EDGE CASE TESTS (Phase 2.5)
    // ==========================================

    /// @notice Test extreme leverage: 100x
    function test_OpenLeverage_ExtremeLeverage_100x() public {
        // Alice wants 100x leverage
        // With $1000 principal at 100x, loan = $99,000
        // Morpho is already funded in setUp with 100k USDC for flash loans

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        router.openLeverage(1000 * 1e6, 100e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should have $100,000 worth of collateral and $99,000 debt
        assertEq(morpho.collateralBalance(alice), 100_000 * 1e18, "Collateral should be 100x");
        assertEq(morpho.borrowBalance(alice), 99_000 * 1e6, "Debt should be 99x");
    }

    /// @notice Test leverage just above 1x (1.1x)
    function test_OpenLeverage_MinimalLeverage_1_1x() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // 1.1x leverage = borrow 10%
        router.openLeverage(1000 * 1e6, 1_100_000_000_000_000_000, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should have $1100 collateral and $100 debt
        assertEq(morpho.collateralBalance(alice), 1100 * 1e18, "Collateral should be 1.1x");
        assertEq(morpho.borrowBalance(alice), 100 * 1e6, "Debt should be 0.1x");
    }

    function test_OpenLeverage_SucceedsWithMinimalPrincipal() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1);

        router.openLeverage(1, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(morpho.collateralBalance(alice), 0, "Should have tiny collateral");
        assertEq(morpho.borrowBalance(alice), 2, "Debt should be 2 wei");
    }

    /// @notice Test small but viable principal
    function test_OpenLeverage_SmallPrincipal_1000Wei() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000);

        // With 1000 wei USDC and 3x leverage, loan = 2000 wei
        router.openLeverage(1000, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify tiny position created
        assertGt(morpho.collateralBalance(alice), 0, "Should have some collateral");
        assertEq(morpho.borrowBalance(alice), 2000, "Debt should be 2000 wei");
    }

    /// @notice Test authorization revoked after callback started (simulated)
    function test_OpenLeverage_AuthorizationRequired_BeforeCallback() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        // Not authorized

        vm.expectRevert(LeverageRouterBase.LeverageRouterBase__NotAuthorized.selector);
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test pause blocks operations
    function test_OpenLeverage_WhenPaused_Reverts() public {
        // Owner pauses router
        router.pause();

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        vm.expectRevert();
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test close when paused also reverts
    function test_CloseLeverage_WhenPaused_Reverts() public {
        // First create a position
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Owner pauses router
        router.pause();

        // Alice tries to close
        vm.startPrank(alice);
        vm.expectRevert();
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @notice Test unpause allows operations
    function test_Unpause_AllowsOperations() public {
        // Pause then unpause
        router.pause();
        router.unpause();

        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // Should work after unpause
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(morpho.collateralBalance(alice), 0, "Position should be created");
    }

    /// @notice Test flash loan from unauthorized caller reverts
    function test_FlashLoanCallback_UnauthorizedCaller_Reverts() public {
        // Try to call onMorphoFlashLoan directly (not from Morpho)
        bytes memory data = abi.encode(uint8(1), alice, block.timestamp + 1 hours, uint256(1000e6), uint256(1000e18));

        vm.expectRevert(); // Should revert with InvalidLender
        router.onMorphoFlashLoan(1000e6, data);
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    /// @notice Fuzz test: openLeverage with random principal and leverage
    /// @dev Tests that openLeverage succeeds or reverts gracefully for valid inputs
    function testFuzz_OpenLeverage(uint256 principal, uint256 leverage) public {
        // Bound inputs to reasonable ranges
        principal = bound(principal, 1e6, 10_000_000e6); // $1 to $10M USDC
        leverage = bound(leverage, 1.01e18, 100e18); // 1.01x to 100x

        // Setup
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100); // Fund morpho for flash loans

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Execute
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position was created
        assertGt(morpho.collateralBalance(alice), 0, "Should have collateral");

        // Verify leverage math: collateral should be approximately principal * leverage / bearPrice
        // With bearPrice = $1, collateral (in 18 decimals) ≈ principal * leverage / 1e6
        uint256 expectedCollateral = (principal * leverage) / 1e6;
        uint256 actualCollateral = morpho.collateralBalance(alice);

        // Allow 1% tolerance for rounding
        assertApproxEqRel(actualCollateral, expectedCollateral, 0.01e18, "Collateral should match leverage");
    }

    /// @notice Fuzz test: closeLeverage with random debt and collateral ratios
    /// @dev Tests partial closes with various debt/collateral combinations
    /// @dev Ensures collateral ratio is sufficient to cover debt (with margin for slippage)
    function testFuzz_CloseLeverage(uint256 debtRatio, uint256 collateralRatio) public {
        // Bound ratios to 0-100%
        debtRatio = bound(debtRatio, 0, 100);

        // Setup: Create a position first (3x leverage on $1000)
        // Position: 3000e18 collateral (worth ~3000e6 USDC), 2000e6 debt
        // To repay X% of debt, we need at least X% * (2/3) of collateral value
        // We use collateralRatio >= debtRatio to ensure sufficient collateral with margin
        uint256 minCollateralRatio = debtRatio > 0 ? debtRatio : 1;
        collateralRatio = bound(collateralRatio, minCollateralRatio, 100);

        uint256 principal = 1000e6;
        uint256 leverage = 3e18;

        usdc.mint(alice, principal);
        usdc.mint(address(morpho), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Get position state
        uint256 totalCollateral = morpho.collateralBalance(alice);
        uint256 totalDebt = morpho.borrowBalance(alice);

        // Calculate amounts to close based on ratios
        uint256 debtToRepay = (totalDebt * debtRatio) / 100;
        uint256 collateralToWithdraw = (totalCollateral * collateralRatio) / 100;

        // Skip if withdrawing too little collateral
        if (collateralToWithdraw == 0) {
            vm.stopPrank();
            return;
        }

        // Close partial position
        router.closeLeverage(debtToRepay, collateralToWithdraw, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify state after close
        uint256 remainingCollateral = morpho.collateralBalance(alice);
        uint256 remainingDebt = morpho.borrowBalance(alice);

        assertEq(remainingCollateral, totalCollateral - collateralToWithdraw, "Collateral should decrease");
        assertEq(remainingDebt, totalDebt - debtToRepay, "Debt should decrease");
    }

    /// @notice Fuzz test: Full round trip (open then close) returns reasonable value
    /// @dev Verifies user doesn't lose excessive funds in a round trip
    function testFuzz_RoundTrip(uint256 principal, uint256 leverage) public {
        // Bound inputs
        principal = bound(principal, 100e6, 1_000_000e6); // $100 to $1M
        leverage = bound(leverage, 2e18, 10e18); // 2x to 10x (reasonable range)

        // Setup
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Open position
        router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        // Immediately close entire position
        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        router.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);

        // User should get back at least 95% (allowing for swap fees, slippage)
        // In mock environment with no fees, should be close to 100%
        assertGe(usdcAfter, (usdcBefore * 95) / 100, "Round trip should return >= 95%");

        // Position should be fully closed
        assertEq(morpho.collateralBalance(alice), 0, "All collateral withdrawn");
        assertEq(morpho.borrowBalance(alice), 0, "All debt repaid");
    }

    /// @notice Fuzz test: Various BEAR prices shouldn't break the router
    function testFuzz_OpenLeverage_VariableBearPrice(uint256 principal, uint256 bearPriceBps) public {
        // Bound inputs
        principal = bound(principal, 100e6, 100_000e6); // $100 to $100k
        bearPriceBps = bound(bearPriceBps, 5000, 20000); // $0.50 to $2.00 per BEAR

        // Set BEAR price (in 6 decimals for mock)
        uint256 bearPrice = (bearPriceBps * 1e6) / 10000;
        curvePool.setPrice(bearPrice);

        // Setup
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Open 2x position
        router.openLeverage(principal, 2e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position exists
        assertGt(morpho.collateralBalance(alice), 0, "Should have collateral");
        assertGt(morpho.borrowBalance(alice), 0, "Should have debt");
    }

    /// @notice Fuzz test: Slippage within bounds should succeed
    function testFuzz_OpenLeverage_SlippageTolerance(uint256 slippageBps) public {
        // Bound slippage to valid range (0 to MAX_SLIPPAGE_BPS which is 100)
        slippageBps = bound(slippageBps, 0, 100);

        uint256 principal = 1000e6;
        usdc.mint(alice, principal);
        usdc.mint(address(morpho), principal * 100);

        vm.startPrank(alice);
        usdc.approve(address(router), principal);
        morpho.setAuthorization(address(router), true);

        // Should succeed with any valid slippage setting
        router.openLeverage(principal, 3e18, slippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(morpho.collateralBalance(alice), 0, "Position should be created");
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

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

contract MockCurvePool is ICurvePool {
    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6;
    uint256 public slippageBps = 0; // Simulated slippage in basis points

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(uint256 _price) external {
        bearPrice = _price;
    }

    /// @notice Set slippage to simulate MEV attacks
    /// @param _slippageBps Slippage in basis points (100 = 1%)
    function setSlippage(uint256 _slippageBps) external {
        slippageBps = _slippageBps;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view override returns (uint256) {
        // get_dy returns the "quoted" price without slippage
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable override returns (uint256 dy) {
        // exchange applies slippage to simulate MEV/price movement
        uint256 quotedDy = this.get_dy(i, j, dx);
        dy = (quotedDy * (10000 - slippageBps)) / 10000; // Apply slippage
        require(dy >= min_dy, "Too little received");
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // Correct Transfer Logic
        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12; // Scale 6 decimals to 18 decimals
    }
}

contract MockMorpho is IMorpho {
    address public usdc;
    address public stakedToken; // sDXY-BEAR
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public _isAuthorized;

    constructor(address _usdc, address _stakedToken) {
        usdc = _usdc;
        stakedToken = _stakedToken;
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external override {
        _isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function isAuthorized(address authorizer, address authorized) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(MarketParams memory) external override {}

    function idToMarketParams(bytes32) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    // Flash loan (fee-free like real Morpho)
    function flashLoan(address token, uint256 assets, bytes calldata data) external override {
        // Mint tokens to borrower (simulating flash loan)
        MockToken(token).mint(msg.sender, assets);

        // Call the borrower's callback
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        // Verify repayment (pull and burn tokens)
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        MockToken(token).burn(address(this), assets);
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
        IERC20(stakedToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
    }

    function withdrawCollateral(MarketParams memory, uint256 assets, address onBehalfOf, address receiver)
        external
        override
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        collateralBalance[onBehalfOf] -= assets;
        IERC20(stakedToken).transfer(receiver, assets);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        MockToken(usdc).mint(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        MockToken(usdc).transferFrom(msg.sender, address(this), assets);
        borrowBalance[onBehalfOf] -= assets;
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

// ==========================================
// MOCK WITH OFFSET (like real StakedToken)
// ==========================================

/// @notice Mock that simulates StakedToken's 1000x decimals offset
/// @dev Real StakedToken has _decimalsOffset() = 3, meaning shares = assets * 1000
contract MockStakedTokenWithOffset is ERC20 {
    MockToken public underlying;
    uint256 public constant OFFSET = 1000; // 10^3 like real StakedToken

    constructor(address _underlying) ERC20("Staked Token With Offset", "sTKN") {
        underlying = MockToken(_underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets * OFFSET; // 1000x more shares than assets
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares / OFFSET; // Convert back to assets
        underlying.transfer(receiver, assets);
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares / OFFSET; // Correctly converts shares to assets
    }
}

// ==========================================
// OFFSET TESTS
// Tests that verify previewCloseLeverage handles decimals offset correctly
// ==========================================

contract LeverageRouterOffsetTest is Test {
    LeverageRouter public router;

    MockToken public usdc;
    MockToken public dxyBear;
    MockStakedTokenWithOffset public stakedDxyBear;
    MockCurvePool public curvePool;
    MockMorpho public morpho;

    MarketParams public params;
    address alice = address(0xA11ce);

    function setUp() public {
        usdc = new MockToken("USDC", "USDC");
        dxyBear = new MockToken("DXY-BEAR", "BEAR");
        stakedDxyBear = new MockStakedTokenWithOffset(address(dxyBear)); // Uses offset mock!
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        morpho = new MockMorpho(address(usdc), address(stakedDxyBear));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedDxyBear),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        router = new LeverageRouter(
            address(morpho), address(curvePool), address(usdc), address(dxyBear), address(stakedDxyBear), params
        );

        usdc.mint(alice, 1000 * 1e6);
        usdc.mint(address(morpho), 10_000 * 1e6);
    }

    /// @notice Test that previewCloseLeverage correctly handles 1000x offset
    /// @dev This test would FAIL with the bug (passing shares directly to get_dy)
    ///      With bug: 3000e18 shares passed to get_dy -> 3000e18 * 1e6 / 1e18 = 3000e6 USDC
    ///      Fixed: 3000e18 shares / 1000 = 3e18 BEAR -> 3e18 * 1e6 / 1e18 = 3e6 USDC
    function test_PreviewCloseLeverage_WithOffset_ReturnsCorrectValue() public view {
        // Simulate: user has 3 BEAR staked, which is 3000 shares (3e18 * 1000 = 3e21)
        uint256 bearAmount = 3e18; // 3 BEAR tokens
        uint256 stakedShares = bearAmount * 1000; // 3e21 shares (1000x offset)
        uint256 debt = 2e6; // 2 USDC debt

        (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) =
            router.previewCloseLeverage(debt, stakedShares);

        // With 1:1 BEAR/USDC price in mock, 3 BEAR should give ~3 USDC (scaled)
        // MockCurvePool.get_dy(1, 0, 3e18) = 3e18 * 1e6 / 1e18 = 3e6 USDC
        assertEq(expectedUSDC, 3e6, "Should return 3 USDC for 3 BEAR");
        assertEq(flashFee, 0, "Flash fee should be 0");
        assertEq(expectedReturn, 1e6, "Return should be 3 USDC - 2 USDC debt = 1 USDC");
    }

    /// @notice Verify the math: shares vs assets distinction
    /// @dev Demonstrates why passing shares directly to get_dy would be wrong
    function test_PreviewCloseLeverage_SharesVsAssets_Distinction() public view {
        // 1000 BEAR tokens staked = 1,000,000 shares (1e21 shares for 1e18 BEAR... no wait)
        // Let me recalculate: 1000 BEAR = 1000e18 wei BEAR
        // With 1000x offset: shares = 1000e18 * 1000 = 1000e21 = 1e24 shares
        uint256 bearAmount = 1000e18; // 1000 BEAR tokens
        uint256 stakedShares = bearAmount * 1000; // 1e24 shares

        (uint256 expectedUSDC,,) = router.previewCloseLeverage(0, stakedShares);

        // Correct behavior: previewRedeem(1e24) = 1e24 / 1000 = 1e21 = 1000e18 BEAR
        // Then get_dy(1, 0, 1000e18) = 1000e18 * 1e6 / 1e18 = 1000e6 = 1000 USDC
        assertEq(expectedUSDC, 1000e6, "1000 BEAR should return 1000 USDC");

        // BUG would have returned: get_dy(1, 0, 1e24) = 1e24 * 1e6 / 1e18 = 1e12 USDC
        // That's 1,000,000 USDC instead of 1000 USDC! (1000x wrong)
        assertTrue(expectedUSDC != 1e12, "Should NOT return buggy 1000x value");
    }

    /// @notice Test close leverage flow with offset mock
    function test_CloseLeverage_WithOffset_Success() public {
        // Setup: Create a position with 3000 BEAR collateral
        usdc.mint(address(morpho), 2000 * 1e6);

        vm.startPrank(alice);

        // Mint BEAR, stake to get shares (with 1000x offset)
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        uint256 shares = stakedDxyBear.deposit(3000 * 1e18, alice);

        // Verify offset: 3000 BEAR -> 3,000,000 shares (3e21 in wei)
        assertEq(shares, 3000 * 1e18 * 1000, "Shares should be 1000x BEAR amount");

        // Supply to Morpho and borrow
        stakedDxyBear.approve(address(morpho), shares);
        morpho.supplyCollateral(params, shares, alice, "");
        morpho.borrow(params, 2000 * 1e6, 0, alice, alice);

        // Close leverage
        morpho.setAuthorization(address(router), true);
        router.closeLeverage(2000 * 1e6, shares, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        // Verify position closed
        assertEq(morpho.collateralBalance(alice), 0, "Collateral should be cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt should be cleared");
        assertGt(usdc.balanceOf(alice), 0, "Alice should receive USDC");
    }

    /// @notice Test that demonstrates the 1000x difference with offset
    function test_Offset_PreviewRedeem_Conversion() public view {
        uint256 shares = 1e24; // 1 million in 18 decimals... wait, 1e24 / 1e18 = 1e6 tokens

        // previewRedeem should divide by 1000
        uint256 assets = stakedDxyBear.previewRedeem(shares);
        assertEq(assets, shares / 1000, "previewRedeem should divide shares by 1000");
        assertEq(assets, 1e21, "1e24 shares = 1e21 BEAR (1000 BEAR tokens)");
    }
}
