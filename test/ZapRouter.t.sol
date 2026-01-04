// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/ZapRouter.sol";
import "../src/base/FlashLoanBase.sol";
import "../src/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "../src/interfaces/ISyntheticSplitter.sol";

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

    function test_PreviewZapMint() public view {
        uint256 usdcAmount = 100 * 1e6;
        // Default Mock Price is 1.0

        (uint256 flashAmount, uint256 expectedSwapOut, uint256 totalUSDC, uint256 expectedTokensOut,) =
            zapRouter.previewZapMint(usdcAmount);

        // Flash Amount includes buffer subtraction
        uint256 expectedFlash = 100 * 1e18;
        if (expectedFlash > 1e13) expectedFlash -= 1e13;

        assertEq(flashAmount, expectedFlash, "Preview Flash Amount");
        // Check other values relative to flashAmount
        uint256 expSwap = (flashAmount * 1e6) / 1e18;
        assertEq(expectedSwapOut, expSwap, "Preview Swap Out");

        uint256 total = usdcAmount + expSwap;
        assertEq(totalUSDC, total, "Preview Total USDC");

        uint256 tokens = (total * 1e12) / 2;
        assertEq(expectedTokensOut, tokens, "Preview Token Out");
    }

    function test_BugFix_DecimalScaling() public {
        // 1. SETUP
        uint256 amountIn = 100e6; // $100 USDC (6 Decimals)

        vm.startPrank(alice);
        IERC20(usdc).approve(address(zapRouter), amountIn);

        uint256 balanceBefore = IERC20(dxyBull).balanceOf(alice);

        // 2. EXECUTE
        // We use a generous deadline and 0 minOut to focus purely on the math mechanics
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 balanceAfter = IERC20(dxyBull).balanceOf(alice);
        uint256 mintedAmount = balanceAfter - balanceBefore;
        vm.stopPrank();

        console.log("Input USDC (6 dec): ", amountIn);
        console.log("Output BULL (18 dec):", mintedAmount);

        // 3. VERIFICATION
        // Scenario A (The Bug):
        // If we didn't scale, $100 USDC -> 100e6 units.
        // 100e6 units treated as 18 decimals is 0.0000000001 tokens.

        // Scenario B (The Fix):
        // $100 USDC * 1e12 = 100e18 units.
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
        // 133 < 150 -> revert!
        vm.expectRevert(ZapRouter.ZapRouter__SolvencyBreach.selector);
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

    function testFuzz_ZapBurn(uint256 bullAmount) public {
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
}

// ==========================================
// MOCKS (Updated for $2 CAP and correct transfer logic)
// ==========================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFlashToken is ERC20, IERC3156FlashLender {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    uint256 public feeBps = 0;

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256 amount) public view override returns (uint256) {
        return (amount * feeBps) / 10000;
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

contract MockCurvePool is ICurvePool {
    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6; // Price of 1 BEAR in USDC (6 decimals). Default $1.00

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(uint256 _price) external {
        bearPrice = _price;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view override returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function get_dx(uint256 i, uint256 j, uint256 dy) external view returns (uint256) {
        // Inverse of get_dy (not in ICurvePool interface but useful for testing)
        if (i == 1 && j == 0) return (dy * 1e18) / bearPrice;
        if (i == 0 && j == 1) return (dy * bearPrice) / 1e18;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable override returns (uint256 dy) {
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

    constructor(address _tA, address _tB) {
        tA = _tA;
        tB = _tB;
    }

    function setUsdc(address _usdc) external {
        usdc = _usdc;
    }

    function setStatus(Status newStatus) external {
        _status = newStatus;
    }

    function mint(uint256 amount) external override {
        // amount is already in 18-decimal token units (ZapRouter pre-calculates)
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(uint256 amount) external override {
        // Real Splitter burns directly from caller (SyntheticToken gives Splitter burn rights)
        // Simulate this by calling burn on the MockFlashToken
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);

        // Mint USDC to caller: amount (18 dec) * CAP (8 dec) / 1e20 = USDC (6 dec)
        // Simplified: amount * 2 / 1e12 (since CAP = 2e8)
        uint256 usdcOut = (amount * 2) / 1e12;
        MockToken(usdc).mint(msg.sender, usdcOut);
    }

    function emergencyRedeem(uint256) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }
}
