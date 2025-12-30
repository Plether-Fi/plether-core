// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/ZapRouter.sol";
import "../src/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "../src/interfaces/ISyntheticSplitter.sol";

contract ZapRouterTest is Test {
    ZapRouter public zapRouter;

    // Mocks
    MockToken public usdc;
    MockFlashToken public mDXY;
    MockFlashToken public mInvDXY;
    MockSplitter public splitter;
    MockCurvePool public curvePool;

    address alice = address(0xA11ce);

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockToken("USDC", "USDC");
        mDXY = new MockFlashToken("mDXY", "mDXY");
        mInvDXY = new MockFlashToken("mInvDXY", "mInvDXY");
        splitter = new MockSplitter(address(mDXY), address(mInvDXY));
        curvePool = new MockCurvePool(address(usdc), address(mDXY));

        // 2. Deploy ZapRouter
        zapRouter = new ZapRouter(address(splitter), address(mDXY), address(mInvDXY), address(usdc), address(curvePool));

        // 3. Setup Initial State
        usdc.mint(alice, 1000 * 1e6);
    }

    // ==========================================
    // 1. HAPPY PATHS
    // ==========================================

    function test_ZapMint_Success() public {
        uint256 usdcInput = 100 * 1e6; // $100

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // Expect ~200 units of pldxy-bull (mInvDXY)
        // Flash mint 100e18 mDXY, swap for 100 USDC, total 200 USDC, mint 200e18 pairs
        // Using 1% slippage tolerance (100 bps)
        zapRouter.zapMint(usdcInput, 190 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGe(mInvDXY.balanceOf(alice), 190 * 1e18, "Alice didn't get enough mInvDXY");
        assertEq(usdc.balanceOf(alice), 900 * 1e6, "Alice spent wrong amount of USDC");
    }

    function test_ZapMint_EmitsEvent() public {
        uint256 usdcInput = 100 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // Check event emission
        vm.expectEmit(true, false, false, true);
        emit ZapRouter.ZapMint(
            alice,
            usdcInput,
            200 * 1e18, // tokensOut (at 100% rate: 100+100=200 USDC -> 200e18 tokens)
            100, // maxSlippageBps
            100 * 1e6 // actualSwapOut (at 100% rate)
        );

        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // 2. LOGIC & MATH CHECKS
    // ==========================================

    function test_ZapMint_FinalSlippage_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        // Configure Curve pool to give slightly bad rates (0.5% slippage)
        curvePool.setRate(9950);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // The user receives less than `minAmountOut` for final tokens
        vm.expectRevert("Slippage too high");
        zapRouter.zapMint(usdcInput, 200 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SwapSlippage_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        // Configure Curve pool to give bad rates (2% slippage)
        curvePool.setRate(9800);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // User sets 1% tolerance but market moves 2% -> reverts
        vm.expectRevert("Too little received");
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SlippageExceedsMax_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // User tries to set 2% slippage (exceeds 1% max)
        vm.expectRevert("Slippage exceeds maximum");
        zapRouter.zapMint(usdcInput, 0, 200, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SlippageAtMax_Succeeds() public {
        uint256 usdcInput = 100 * 1e6;

        // Configure Curve pool to give 0.5% slippage
        curvePool.setRate(9950);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // User sets exactly 1% (100 bps) - at the max limit
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(mInvDXY.balanceOf(alice), 0, "Should have received tokens");
    }

    function test_ZapMint_Insolvency_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        // Configure rate at 1% slippage (passes slippage check)
        curvePool.setRate(9900);

        // Set a very high flash fee (200%) that causes insolvency
        mDXY.setFeeBps(20000);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);
        vm.expectRevert("Insolvent Zap: Swap didn't cover mint cost");
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // 3. SECURITY & INPUT VALIDATION
    // ==========================================

    function test_ZapMint_Expired_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // Try with expired deadline
        vm.expectRevert("Transaction expired");
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);

        // Alice pretends to be a Flash Lender calling the callback
        vm.expectRevert("Untrusted lender");
        zapRouter.onFlashLoan(address(zapRouter), address(mDXY), 100, 0, "");
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        // We pretend to be the legitimate mDXY token calling the callback...
        vm.startPrank(address(mDXY));

        // ...BUT the 'initiator' arg is Alice, not the ZapRouter itself.
        vm.expectRevert("Untrusted initiator");
        zapRouter.onFlashLoan(
            alice, // <--- Malicious initiator
            address(mDXY),
            100,
            0,
            ""
        );
        vm.stopPrank();
    }

    // ==========================================
    // 4. FUZZ TESTS
    // ==========================================

    function testFuzz_ZapMint(uint256 usdcAmount) public {
        // Bound inputs: $1 to $1M USDC
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000 * 1e6);

        usdc.mint(alice, usdcAmount);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);

        zapRouter.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify invariants:
        // 1. User spent exactly usdcAmount
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - usdcAmount, "Incorrect USDC spent");

        // 2. User receives mInvDXY tokens
        // At 1:1 mock rate: flash usdcAmount*1e12 mDXY, swap for usdcAmount USDC
        // Total: 2*usdcAmount USDC -> mint 2*usdcAmount*1e12 of each token
        uint256 expectedTokens = 2 * usdcAmount * 1e12;
        assertEq(mInvDXY.balanceOf(alice), expectedTokens, "Incorrect mInvDXY received");

        // 3. Router has no leftover mInvDXY (the output token)
        assertEq(mInvDXY.balanceOf(address(zapRouter)), 0, "Router has leftover mInvDXY");
    }

    function testFuzz_ZapMint_SlippageBound(uint256 slippageBps) public {
        uint256 usdcAmount = 100 * 1e6;

        usdc.mint(alice, usdcAmount);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);

        if (slippageBps > 100) {
            vm.expectRevert("Slippage exceeds maximum");
            zapRouter.zapMint(usdcAmount, 0, slippageBps, block.timestamp + 1 hours);
        } else {
            zapRouter.zapMint(usdcAmount, 0, slippageBps, block.timestamp + 1 hours);
            assertGt(mInvDXY.balanceOf(alice), 0, "Should have received tokens");
        }
        vm.stopPrank();
    }

    function testFuzz_ZapMint_MinAmountOut(uint256 usdcAmount, uint256 minAmountOut) public {
        // Bound inputs
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000 * 1e6);

        // Expected output at 1:1 rate
        uint256 expectedOutput = 2 * usdcAmount * 1e12;

        usdc.mint(alice, usdcAmount);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcAmount);

        if (minAmountOut > expectedOutput) {
            vm.expectRevert("Slippage too high");
            zapRouter.zapMint(usdcAmount, minAmountOut, 100, block.timestamp + 1 hours);
        } else {
            zapRouter.zapMint(usdcAmount, minAmountOut, 100, block.timestamp + 1 hours);
            assertGe(mInvDXY.balanceOf(alice), minAmountOut, "Received less than minAmountOut");
        }
        vm.stopPrank();
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
}

contract MockFlashToken is ERC20, IERC3156FlashLender {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    uint256 public feeBps = 0; // Configurable fee in basis points (default 0)

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
        _mint(address(receiver), amount); // optimistic mint
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        _burn(address(receiver), amount + fee); // repay
        return true;
    }
}

contract MockCurvePool is ICurvePool {
    address public token0; // USDC (index 0)
    address public token1; // mDXY (index 1)
    uint256 public rate = 10000; // 100.00%

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setRate(uint256 _r) external {
        rate = _r;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external override returns (uint256 dy) {
        // mDXY (18 decimals) -> USDC (6 decimals)
        // Apply rate for slippage simulation
        dy = (dx / 1e12) * rate / 10000;

        // MEV protection: revert if output below minimum
        require(dy >= min_dy, "Too little received");

        address tokenOut = j == 0 ? token0 : token1;
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }
}

contract MockSplitter is ISyntheticSplitter {
    address public tA;
    address public tB;

    constructor(address _tA, address _tB) {
        tA = _tA;
        tB = _tB;
    }

    function mint(uint256 amount) external override {
        uint256 mintAmount = amount * 1e12;
        MockFlashToken(tA).mint(msg.sender, mintAmount);
        MockFlashToken(tB).mint(msg.sender, mintAmount);
    }

    // Stubs for Missing Implementation Errors
    function currentStatus() external view override returns (Status) {
        return Status.ACTIVE;
    }

    function getSystemSolvency() external view override returns (uint256, uint256) {
        return (0, 0);
    }
    function redeemPair(uint256) external override {}
    function redeemSettled(address, uint256) external override {}
    function setTreasury(address) external override {}
    function setVault(address) external override {}

    function settledPrice() external view override returns (uint256) {
        return 0;
    }
    function skimYield() external override {}
}
