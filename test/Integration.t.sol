// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockYieldAdapter} from "./utils/MockYieldAdapter.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end integration tests using real contracts (not mocks)
 * @dev Tests full lifecycle flows:
 *      - Mint → ZapRouter → Burn
 *      - Multiple users interacting concurrently
 *      - State consistency across operations
 */
contract IntegrationTest is Test {

    // Core contracts
    SyntheticSplitter public splitter;
    ZapRouter public zapRouter;
    MockYieldAdapter public adapter;

    // Tokens
    MockUSDC public usdc;
    SyntheticToken public dxyBear;
    SyntheticToken public dxyBull;

    // Mocks (only for external dependencies)
    MockOracle public oracle;
    MockOracle public sequencer;
    MockCurvePool public curvePool;

    // Test accounts
    address owner = address(0x1);
    address alice = address(0xA11ce);
    address bob = address(0xB0b);
    address carol = address(0xCa701);
    address treasury = address(0x99);

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    function setUp() public {
        vm.warp(1_735_689_600);

        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy oracles
        oracle = new MockOracle(100_000_000, block.timestamp, block.timestamp); // $1.00
        sequencer = new MockOracle(0, block.timestamp - 2 hours, block.timestamp);

        // Calculate future splitter address for adapter
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitterAddr = vm.computeCreateAddress(owner, nonce + 1);

        // Deploy adapter
        adapter = new MockYieldAdapter(IERC20(address(usdc)), owner, futureSplitterAddr);

        // Deploy splitter (creates real SyntheticTokens)
        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));
        vm.stopPrank();

        // Get the real synthetic tokens created by splitter
        dxyBear = splitter.TOKEN_A();
        dxyBull = splitter.TOKEN_B();

        // Deploy Curve pool mock (external dependency)
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        curvePool.setPrice(1e6); // 1 BEAR = 1 USDC (parity)

        // Deploy ZapRouter with REAL splitter
        zapRouter =
            new ZapRouter(address(splitter), address(dxyBear), address(dxyBull), address(usdc), address(curvePool));

        // Fund test accounts
        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
        usdc.mint(carol, 10_000_000e6);

        // Fund curve pool for swaps
        usdc.mint(address(curvePool), 100_000_000e6);

        // Seed curve pool with BEAR reserves (needed for zapBurn flow)
        // Mint tokens via Splitter, then transfer BEAR to pool
        address poolSeeder = address(0xDEAD);
        usdc.mint(poolSeeder, 10_000_000e6);
        vm.startPrank(poolSeeder);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(1_000_000 ether); // Mint 1M BEAR+BULL pairs
        dxyBear.transfer(address(curvePool), 1_000_000 ether); // Seed pool with BEAR
        vm.stopPrank();

        // Labels
        vm.label(address(splitter), "Splitter");
        vm.label(address(zapRouter), "ZapRouter");
        vm.label(address(dxyBear), "DXY-BEAR");
        vm.label(address(dxyBull), "DXY-BULL");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(carol, "Carol");
    }

    // ==========================================
    // BASIC LIFECYCLE TESTS
    // ==========================================

    function test_FullLifecycle_MintBurn() public {
        uint256 mintAmount = 1000 ether;

        // 1. Alice mints tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        uint256 usdcBefore = usdc.balanceOf(alice);
        splitter.mint(mintAmount);
        uint256 usdcAfter = usdc.balanceOf(alice);

        // Verify mint
        assertEq(dxyBear.balanceOf(alice), mintAmount, "Should have BEAR");
        assertEq(dxyBull.balanceOf(alice), mintAmount, "Should have BULL");
        uint256 usdcSpent = usdcBefore - usdcAfter;
        assertGt(usdcSpent, 0, "Should have spent USDC");

        // 2. Alice burns tokens
        uint256 burnAmount = 500 ether;
        splitter.burn(burnAmount);

        assertEq(dxyBear.balanceOf(alice), mintAmount - burnAmount, "Should have remaining BEAR");
        assertEq(dxyBull.balanceOf(alice), mintAmount - burnAmount, "Should have remaining BULL");
        assertGt(usdc.balanceOf(alice), usdcAfter, "Should have received USDC back");
        vm.stopPrank();
    }

    function test_FullLifecycle_ZapMintZapBurn() public {
        // 1. Alice uses ZapRouter to get BULL only
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), type(uint256).max);

        uint256 usdcInput = 100e6;
        zapRouter.zapMint(usdcInput, 0, 100, block.timestamp + 1 hours);

        uint256 bullReceived = dxyBull.balanceOf(alice);
        assertGt(bullReceived, 0, "Should have received BULL");
        // Note: ZapRouter may sweep small dust amounts of BEAR to user
        // The key point is that BULL is the primary output
        assertLt(dxyBear.balanceOf(alice), 1 ether, "Should have minimal BEAR (only dust)");

        // 2. Alice uses ZapRouter to sell BULL back
        dxyBull.approve(address(zapRouter), bullReceived);
        uint256 usdcBefore = usdc.balanceOf(alice);
        zapRouter.zapBurn(bullReceived, 0, block.timestamp + 1 hours);

        assertEq(dxyBull.balanceOf(alice), 0, "Should have burned all BULL");
        assertGt(usdc.balanceOf(alice), usdcBefore, "Should have received USDC");
        vm.stopPrank();
    }

    // ==========================================
    // MULTI-USER CONCURRENT TESTS
    // ==========================================

    function test_ConcurrentMints_MaintainsSolvency() public {
        // Multiple users mint simultaneously
        uint256 aliceMint = 1000 ether;
        uint256 bobMint = 2000 ether;
        uint256 carolMint = 500 ether;

        // Record initial supply (from pool seeding in setUp)
        uint256 initialSupply = dxyBear.totalSupply();

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);

        // Execute mints
        vm.prank(alice);
        splitter.mint(aliceMint);
        vm.prank(bob);
        splitter.mint(bobMint);
        vm.prank(carol);
        splitter.mint(carolMint);

        // Verify individual balances
        assertEq(dxyBear.balanceOf(alice), aliceMint);
        assertEq(dxyBear.balanceOf(bob), bobMint);
        assertEq(dxyBear.balanceOf(carol), carolMint);

        // Verify total supply increased by the expected amount
        uint256 expectedNewTokens = aliceMint + bobMint + carolMint;
        assertEq(dxyBear.totalSupply(), initialSupply + expectedNewTokens);
        assertEq(dxyBull.totalSupply(), initialSupply + expectedNewTokens);

        // Verify solvency
        _verifySolvency();
    }

    function test_ConcurrentBurns_MaintainsSolvency() public {
        // First, everyone mints
        uint256 mintAmount = 1000 ether;

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        splitter.mint(mintAmount);

        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        splitter.mint(mintAmount);

        // Now everyone burns concurrently
        uint256 burnAmount = 500 ether;

        vm.prank(alice);
        splitter.burn(burnAmount);

        vm.prank(bob);
        splitter.burn(burnAmount);

        vm.prank(carol);
        splitter.burn(burnAmount);

        // Verify each user has remaining tokens
        assertEq(dxyBear.balanceOf(alice), mintAmount - burnAmount);
        assertEq(dxyBear.balanceOf(bob), mintAmount - burnAmount);
        assertEq(dxyBear.balanceOf(carol), mintAmount - burnAmount);

        // Verify solvency
        _verifySolvency();
    }

    function test_InterleavedMintBurn_MaintainsSolvency() public {
        // Complex interleaving of mints and burns
        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);

        // Interleaved operations
        vm.prank(alice);
        splitter.mint(1000 ether);

        vm.prank(bob);
        splitter.mint(500 ether);

        vm.prank(alice);
        splitter.burn(200 ether);

        vm.prank(carol);
        splitter.mint(2000 ether);

        vm.prank(bob);
        splitter.burn(500 ether);

        vm.prank(alice);
        splitter.mint(300 ether);

        vm.prank(carol);
        splitter.burn(1000 ether);

        // Final state verification
        assertEq(dxyBear.balanceOf(alice), 1100 ether); // 1000 - 200 + 300
        assertEq(dxyBear.balanceOf(bob), 0 ether); // 500 - 500
        assertEq(dxyBear.balanceOf(carol), 1000 ether); // 2000 - 1000

        _verifySolvency();
    }

    // ==========================================
    // ZAPROUTER INTEGRATION TESTS
    // ==========================================

    function test_ZapRouter_WithRealSplitter_Success() public {
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), type(uint256).max);

        uint256 usdcBefore = usdc.balanceOf(alice);
        zapRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);
        uint256 usdcAfter = usdc.balanceOf(alice);

        // Should have spent USDC
        assertLt(usdcAfter, usdcBefore, "Should have spent USDC");

        // Should have BULL tokens
        assertGt(dxyBull.balanceOf(alice), 0, "Should have BULL");

        // ZapRouter should not hold any tokens
        assertEq(usdc.balanceOf(address(zapRouter)), 0, "ZapRouter should not hold USDC");
        assertEq(dxyBear.balanceOf(address(zapRouter)), 0, "ZapRouter should not hold BEAR");
        assertEq(dxyBull.balanceOf(address(zapRouter)), 0, "ZapRouter should not hold BULL");

        vm.stopPrank();
    }

    function test_ZapRouter_MultipleUsers_Concurrent() public {
        // Multiple users use ZapRouter simultaneously
        vm.prank(alice);
        usdc.approve(address(zapRouter), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(zapRouter), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(zapRouter), type(uint256).max);

        vm.prank(alice);
        zapRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);

        vm.prank(bob);
        zapRouter.zapMint(200e6, 0, 100, block.timestamp + 1 hours);

        vm.prank(carol);
        zapRouter.zapMint(50e6, 0, 100, block.timestamp + 1 hours);

        // All should have BULL
        assertGt(dxyBull.balanceOf(alice), 0, "Alice should have BULL");
        assertGt(dxyBull.balanceOf(bob), 0, "Bob should have BULL");
        assertGt(dxyBull.balanceOf(carol), 0, "Carol should have BULL");

        // Bob invested more, should have more BULL
        assertGt(dxyBull.balanceOf(bob), dxyBull.balanceOf(alice), "Bob should have more BULL than Alice");

        _verifySolvency();
    }

    // ==========================================
    // PRICE CHANGE SCENARIOS
    // ==========================================

    function test_PriceIncrease_CorrectRedemption() public {
        // Mint at price $1.00
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(1000 ether);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Price increases to $1.50 (BEAR becomes more valuable)
        oracle.setPrice(150_000_000);

        // Burn should still work (price is below CAP)
        splitter.burn(500 ether);

        uint256 usdcAfter = usdc.balanceOf(alice);
        uint256 usdcReceived = usdcAfter - usdcBefore;

        // Should receive USDC based on CAP, not current price
        // 500 tokens * $2 CAP = $1000 worth of USDC
        assertEq(usdcReceived, 1000e6, "Should receive fixed CAP-based USDC");
        vm.stopPrank();
    }

    function test_PriceDecrease_CorrectRedemption() public {
        // Mint at price $1.00
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(1000 ether);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Price decreases to $0.50
        oracle.setPrice(50_000_000);

        // Burn should still work
        splitter.burn(500 ether);

        uint256 usdcAfter = usdc.balanceOf(alice);
        uint256 usdcReceived = usdcAfter - usdcBefore;

        // Should still receive CAP-based USDC
        assertEq(usdcReceived, 1000e6, "Should receive fixed CAP-based USDC");
        vm.stopPrank();
    }

    // ==========================================
    // ADAPTER INTERACTION TESTS
    // ==========================================

    function test_BufferManagement_LargeMint() public {
        uint256 largeAmount = 100_000 ether;

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(largeAmount);
        vm.stopPrank();

        // Check buffer (10% should stay in splitter)
        uint256 localBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterBalance = adapter.balanceOf(address(splitter));

        assertGt(localBuffer, 0, "Should have local buffer");
        assertGt(adapterBalance, 0, "Should have adapter balance");

        _verifySolvency();
    }

    function test_BufferDepletion_RecoveryFromAdapter() public {
        // First, mint to create buffer
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(1000 ether);
        vm.stopPrank();

        uint256 initialBuffer = usdc.balanceOf(address(splitter));

        // Burn more than buffer to force adapter withdrawal
        // 1000 tokens * $2 CAP = $2000 USDC needed
        // 10% buffer = $200 USDC local
        // Burning 500 tokens needs $1000 USDC -> more than buffer
        vm.prank(alice);
        splitter.burn(500 ether);

        // System should still be solvent
        _verifySolvency();

        // Alice should have received her USDC
        assertGt(usdc.balanceOf(alice), 10_000_000e6 - 2000e6, "Alice should have USDC back");
    }

    // ==========================================
    // HELPER FUNCTIONS
    // ==========================================

    function _verifySolvency() internal view {
        uint256 totalSupply = dxyBear.totalSupply();
        uint256 liabilities = (totalSupply * CAP) / splitter.USDC_MULTIPLIER();

        uint256 localBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterShares = adapter.balanceOf(address(splitter));
        uint256 adapterAssets = adapterShares > 0 ? adapter.convertToAssets(adapterShares) : 0;
        uint256 totalAssets = localBuffer + adapterAssets;

        assertGe(totalAssets, liabilities, "System should be solvent");
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

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockOracle is AggregatorV3Interface {

    int256 public price;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(
        int256 _price,
        uint256 _startedAt,
        uint256 _updatedAt
    ) {
        price = _price;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
    }

    function setPrice(
        int256 _price
    ) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }

}

contract MockCurvePool {

    address public token0; // USDC
    address public token1; // DXY-BEAR
    uint256 public bearPrice = 1e6; // 1 BEAR = 1 USDC (in 6 decimals)

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
    ) external view returns (uint256) {
        // i=1 (BEAR), j=0 (USDC): sell BEAR for USDC
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        // i=0 (USDC), j=1 (BEAR): buy BEAR with USDC
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // Take input token
        ERC20(tokenIn).transferFrom(msg.sender, address(this), dx);

        // For USDC output, we can mint (it's our mock)
        // For BEAR output, we need to have reserves (can't mint SyntheticToken)
        if (j == 0) {
            // Output is USDC - mint it
            MockUSDC(tokenOut).mint(msg.sender, dy);
        } else {
            // Output is BEAR - transfer from reserves
            ERC20(tokenOut).transfer(msg.sender, dy);
        }

        return dy;
    }

    function price_oracle() external view returns (uint256) {
        return bearPrice * 1e12;
    }

    // Allow seeding the pool with BEAR reserves
    function seedBearReserves(
        address bear,
        uint256 amount
    ) external {
        // Caller must have approved this contract
        ERC20(bear).transferFrom(msg.sender, address(this), amount);
    }

}
