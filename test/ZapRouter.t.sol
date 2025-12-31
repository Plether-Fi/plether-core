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

        zapRouter.zapMint(usdcInput, 99 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Parity: Alice gets ~100 BULL.
        // Tolerance 1e15 (0.001 units) allows for buffer dust effects
        assertApproxEqAbs(dxyBull.balanceOf(alice), 100 * 1e18, 1e15, "Parity: Alice should get ~100 BULL");
        // Ensure no leaks in Router (Balance must be 0)
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Parity: Router leaked BEAR");
    }

    function test_ZapMint_BearCheap() public {
        // Scenario: Bear = $0.50, Bull = $1.50 (Total $2.00)
        curvePool.setPrice(500_000); // 1 BEAR = 0.5 USDC

        uint256 usdcInput = 100 * 1e6; // $100
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        zapRouter.zapMint(usdcInput, 66 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Exp: 66.666... BULL
        // Hardcoded integer approx for 66.66... ether
        uint256 expected = 66666666666666666666;

        assertApproxEqAbs(dxyBull.balanceOf(alice), expected, 1e15, "Cheap: Alice output mismatch");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "Cheap: Router leaked BEAR");
    }

    function test_ZapMint_BearExpensive() public {
        // Scenario: Bear = $1.50, Bull = $0.50 (Total $2.00)
        curvePool.setPrice(1_500_000); // 1 BEAR = 1.5 USDC

        uint256 usdcInput = 100 * 1e6; // $100
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        zapRouter.zapMint(usdcInput, 199 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Exp: 200 BULL
        assertApproxEqAbs(dxyBull.balanceOf(alice), 200 * 1e18, 1e15, "Expensive: Alice should get ~200 BULL");
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

        vm.expectRevert("Bear price > Cap");
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_SlippageExceedsMax_Reverts() public {
        uint256 usdcInput = 100 * 1e6;
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        vm.expectRevert("Slippage exceeds maximum");
        zapRouter.zapMint(usdcInput, 0, 200, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapMint_ZeroAmount_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), 0);

        vm.expectRevert("Amount must be > 0");
        zapRouter.zapMint(0, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // 3. SECURITY & PREVIEW
    // ==========================================

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);
        vm.expectRevert("Untrusted lender");
        zapRouter.onFlashLoan(address(zapRouter), address(dxyBear), 100, 0, "");
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        vm.startPrank(address(dxyBear));
        vm.expectRevert("Untrusted initiator");
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

    function get_dy(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external override returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // CRITICAL FIX: Simulate Transfer. Take tokens from sender.
        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);

        return dy;
    }
}

contract MockSplitter is ISyntheticSplitter {
    address public tA;
    address public tB;
    Status private _status = Status.ACTIVE;

    constructor(address _tA, address _tB) {
        tA = _tA;
        tB = _tB;
    }

    function setStatus(Status newStatus) external {
        _status = newStatus;
    }

    function mint(uint256 amount) external override {
        // CAP = 2 USDC. Input amount is USDC.
        // Logic: (amount * 1e12) / 2
        uint256 mintAmount = (amount * 1e12) / 2;
        MockFlashToken(tA).mint(msg.sender, mintAmount);
        MockFlashToken(tB).mint(msg.sender, mintAmount);
    }

    // Stubs
    function currentStatus() external view override returns (Status) {
        return _status;
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
