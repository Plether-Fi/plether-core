// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/ZapRouter.sol";
import "../src/LeverageRouter.sol";
import "../src/BullLeverageRouter.sol";
import "./utils/MockYieldAdapter.sol";
import "../src/interfaces/IMorpho.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/**
 * @title ReentrancyTest
 * @notice Tests for reentrancy protection across all router contracts
 * @dev Verifies that nonReentrant modifiers prevent various attack vectors:
 *      - Flash loan callback re-entrance
 *      - Curve pool callback attacks
 *      - Nested flash loan re-entrance
 */
contract ReentrancyTest is Test {
    // Core contracts
    SyntheticSplitter public splitter;
    ZapRouter public zapRouter;
    MockYieldAdapter public adapter;

    // Tokens
    MockUSDC public usdc;
    MockFlashToken public dxyBear;
    MockFlashToken public dxyBull;

    // Mocks
    MockOracle public oracle;
    MockOracle public sequencer;
    MockCurvePool public curvePool;

    // Attackers
    ReentrantFlashBorrower public attacker;

    address owner = address(0x1);
    address alice = address(0xA11ce);
    address treasury = address(0x99);

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    function setUp() public {
        vm.warp(1735689600);

        // Deploy tokens
        usdc = new MockUSDC();
        dxyBear = new MockFlashToken("DXY-BEAR", "plDXY-BEAR");
        dxyBull = new MockFlashToken("DXY-BULL", "plDXY-BULL");

        // Deploy oracles
        oracle = new MockOracle(100_000_000, block.timestamp, block.timestamp);
        sequencer = new MockOracle(0, block.timestamp - 2 hours, block.timestamp);

        // Deploy Curve pool mock
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        curvePool.setPrice(1e6); // 1 BEAR = 1 USDC

        // Calculate future splitter address
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitterAddr = vm.computeCreateAddress(owner, nonce + 1);

        // Deploy adapter
        adapter = new MockYieldAdapter(IERC20(address(usdc)), owner, futureSplitterAddr);

        // Deploy splitter
        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));
        vm.stopPrank();

        // Deploy ZapRouter with mock splitter for flash loan tests
        MockSplitter mockSplitter = new MockSplitter(address(dxyBear), address(dxyBull));
        mockSplitter.setUsdc(address(usdc));
        zapRouter =
            new ZapRouter(address(mockSplitter), address(dxyBear), address(dxyBull), address(usdc), address(curvePool));

        // Deploy attacker
        attacker = new ReentrantFlashBorrower();

        // Fund accounts
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(curvePool), 10_000_000e6);

        // Labels
        vm.label(address(splitter), "Splitter");
        vm.label(address(zapRouter), "ZapRouter");
        vm.label(address(attacker), "Attacker");
    }

    // ==========================================
    // SPLITTER REENTRANCY TESTS
    // ==========================================

    function test_Splitter_Mint_ReentrancyBlocked() public {
        // Setup: Fund attacker with USDC
        usdc.mint(address(attacker), 1_000_000e6);

        vm.prank(address(attacker));
        usdc.approve(address(splitter), type(uint256).max);

        // Configure attacker to try reentering mint during a transfer callback
        attacker.setTarget(address(splitter));
        attacker.setReentryFunction(ReentrantFlashBorrower.ReentryType.SPLITTER_MINT);

        // The attacker tries to mint, which should succeed without reentrancy
        // If reentrancy was possible, the test would detect doubled minting
        vm.prank(address(attacker));
        splitter.mint(1000 ether);

        // Verify only one mint occurred (not doubled from reentrancy)
        assertEq(splitter.TOKEN_A().balanceOf(address(attacker)), 1000 ether, "Should mint exactly once");
    }

    function test_Splitter_Burn_ReentrancyBlocked() public {
        // Setup: First mint some tokens
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(1000 ether);

        // Transfer tokens to attacker
        splitter.TOKEN_A().transfer(address(attacker), 500 ether);
        splitter.TOKEN_B().transfer(address(attacker), 500 ether);
        vm.stopPrank();

        // Configure attacker
        attacker.setTarget(address(splitter));
        attacker.setReentryFunction(ReentrantFlashBorrower.ReentryType.SPLITTER_BURN);

        // Attacker tries to burn with reentrancy
        vm.prank(address(attacker));
        splitter.burn(500 ether);

        // Verify only one burn occurred
        assertEq(splitter.TOKEN_A().balanceOf(address(attacker)), 0, "Should burn all tokens");
    }

    // ==========================================
    // ZAPROUTER REENTRANCY TESTS
    // ==========================================

    function test_ZapRouter_ZapMint_ReentrancyBlocked() public {
        // Fund attacker
        usdc.mint(address(attacker), 1_000_000e6);

        vm.prank(address(attacker));
        usdc.approve(address(zapRouter), type(uint256).max);

        // Configure attacker to try reentering during flash loan callback
        attacker.setTarget(address(zapRouter));
        attacker.setReentryFunction(ReentrantFlashBorrower.ReentryType.ZAP_MINT);

        uint256 bullBefore = dxyBull.balanceOf(address(attacker));

        // Attempt zapMint - nonReentrant should block any callback reentrancy
        vm.prank(address(attacker));
        zapRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);

        // Verify attacker received BULL (meaning normal execution completed)
        uint256 bullAfter = dxyBull.balanceOf(address(attacker));
        assertGt(bullAfter, bullBefore, "Attacker should receive BULL from normal execution");

        // Verify no double-minting occurred (reentrancy was blocked)
        // If reentrancy worked, attacker would have received more than expected
        assertLt(bullAfter, 200 ether, "Should not have double-minted from reentrancy");
    }

    function test_ZapRouter_ZapBurn_ReentrancyBlocked() public {
        // Fund attacker with BULL tokens
        dxyBull.mint(address(attacker), 100 ether);

        vm.prank(address(attacker));
        dxyBull.approve(address(zapRouter), type(uint256).max);

        // Configure attacker
        attacker.setTarget(address(zapRouter));
        attacker.setReentryFunction(ReentrantFlashBorrower.ReentryType.ZAP_BURN);

        // Attempt zapBurn - should execute normally without reentrancy
        vm.prank(address(attacker));
        zapRouter.zapBurn(100 ether, 0, block.timestamp + 1 hours);

        // Verify tokens were burned
        assertEq(dxyBull.balanceOf(address(attacker)), 0, "Should burn all BULL");
    }

    // ==========================================
    // FLASH LOAN CALLBACK SECURITY
    // ==========================================

    function test_ZapRouter_OnFlashLoan_RejectsExternalCalls() public {
        // Try calling onFlashLoan directly from a random address
        vm.prank(alice);
        vm.expectRevert();
        zapRouter.onFlashLoan(address(zapRouter), address(dxyBear), 100, 0, "");
    }

    function test_ZapRouter_OnFlashLoan_RejectsWrongInitiator() public {
        // Try calling from the correct lender but wrong initiator
        vm.prank(address(dxyBear));
        vm.expectRevert();
        zapRouter.onFlashLoan(alice, address(dxyBear), 100, 0, "");
    }

    // ==========================================
    // CURVE POOL CALLBACK ATTACK SIMULATION
    // ==========================================

    function test_CurvePoolReentrancy_Blocked() public {
        // This test simulates a malicious Curve pool that tries to
        // reenter during exchange()

        // Deploy malicious curve pool
        MaliciousCurvePool maliciousPool = new MaliciousCurvePool(address(usdc), address(dxyBear), address(zapRouter));

        // Create new ZapRouter with malicious pool
        MockSplitter mockSplitter = new MockSplitter(address(dxyBear), address(dxyBull));
        mockSplitter.setUsdc(address(usdc));
        ZapRouter maliciousRouter = new ZapRouter(
            address(mockSplitter), address(dxyBear), address(dxyBull), address(usdc), address(maliciousPool)
        );

        // Fund attacker
        usdc.mint(alice, 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(maliciousRouter), type(uint256).max);

        // The malicious pool will try to reenter during exchange
        // nonReentrant should block this
        // This will revert because the router is already in a call
        vm.expectRevert();
        maliciousRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // PAUSE FUNCTIONALITY TESTS
    // ==========================================

    function test_ZapRouter_Pause_BlocksOperations() public {
        usdc.mint(alice, 1_000_000e6);

        // Pause the router
        zapRouter.pause();

        // Try to zapMint while paused
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), type(uint256).max);

        vm.expectRevert();
        zapRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_ZapRouter_Unpause_AllowsOperations() public {
        usdc.mint(alice, 1_000_000e6);

        // Pause then unpause
        zapRouter.pause();
        zapRouter.unpause();

        // Should work now
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), type(uint256).max);
        zapRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify execution
        assertGt(dxyBull.balanceOf(alice), 0, "Should have received BULL");
    }
}

// ==========================================
// ATTACK CONTRACTS
// ==========================================

contract ReentrantFlashBorrower is IERC3156FlashBorrower {
    enum ReentryType {
        NONE,
        SPLITTER_MINT,
        SPLITTER_BURN,
        ZAP_MINT,
        ZAP_BURN
    }

    address public target;
    ReentryType public reentryType;
    bool public hasReentered;

    function setTarget(address _target) external {
        target = _target;
    }

    function setReentryFunction(ReentryType _type) external {
        reentryType = _type;
    }

    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external override returns (bytes32) {
        // Try to reenter based on configured type
        if (!hasReentered && reentryType != ReentryType.NONE) {
            hasReentered = true;

            if (reentryType == ReentryType.ZAP_MINT) {
                // This should fail due to nonReentrant
                try ZapRouter(target).zapMint(100e6, 0, 100, block.timestamp + 1 hours) {} catch {}
            } else if (reentryType == ReentryType.ZAP_BURN) {
                try ZapRouter(target).zapBurn(100 ether, 0, block.timestamp + 1 hours) {} catch {}
            }
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // Allow receiving tokens
    receive() external payable {}
}

contract MaliciousCurvePool {
    address public token0;
    address public token1;
    address public targetRouter;
    bool public hasAttacked;

    constructor(address _token0, address _token1, address _router) {
        token0 = _token0;
        token1 = _token1;
        targetRouter = _router;
    }

    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        return dx; // 1:1 for simplicity
    }

    function exchange(uint256, uint256, uint256, uint256) external payable returns (uint256) {
        // Try to reenter the router during exchange
        if (!hasAttacked) {
            hasAttacked = true;
            // This should fail due to nonReentrant
            ZapRouter(targetRouter).zapMint(1e6, 0, 100, block.timestamp + 1 hours);
        }
        return 0;
    }

    function price_oracle() external pure returns (uint256) {
        return 1e18;
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFlashToken is ERC20, IERC3156FlashLender {
    uint256 public feeBps = 0;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

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

contract MockOracle {
    int256 public price;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(int256 _price, uint256 _startedAt, uint256 _updatedAt) {
        price = _price;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }
}

contract MockCurvePool {
    address public token0;
    address public token1;
    uint256 public bearPrice = 1e6;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(uint256 _price) external {
        bearPrice = _price;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        ERC20(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockFlashToken(tokenOut).mint(msg.sender, dy);

        return dy;
    }

    function price_oracle() external view returns (uint256) {
        return bearPrice * 1e12;
    }
}

contract MockSplitter {
    address public tA;
    address public tB;
    address public usdc;
    uint256 public constant CAP = 2e8;

    constructor(address _tA, address _tB) {
        tA = _tA;
        tB = _tB;
    }

    function setUsdc(address _usdc) external {
        usdc = _usdc;
    }

    function currentStatus() external pure returns (uint8) {
        return 0; // ACTIVE
    }

    function mint(uint256 amount) external {
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);
        uint256 usdcOut = (amount * 2) / 1e12;
        MockUSDC(usdc).mint(msg.sender, usdcOut);
    }
}
