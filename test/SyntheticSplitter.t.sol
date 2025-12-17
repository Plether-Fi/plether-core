// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

// 6 Decimal USDC
contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
}

contract SyntheticSplitterTest is Test {
    SyntheticSplitter splitter;
    YieldAdapter adapter;
    
    // Mocks
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;

    address alice = address(0x1);
    address treasury = address(0x999);
    address staking = address(0x888);
    
    // Constants
    uint256 constant CAP = 200_000_000; // $2.00 (8 decimals)
    uint256 constant INITIAL_BALANCE = 10_000 * 1e6; // $10,000 USDC

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc)); 
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket");

        // Fund Pool for withdrawals
        usdc.mint(address(pool), 1_000_000 * 1e6);

        adapter = new YieldAdapter(
            IERC20(address(usdc)),
            address(pool),
            address(aUsdc),
            address(this)
        );

        // Deploy Splitter with YieldAdapter injected
        splitter = new SyntheticSplitter(
            address(oracle), 
            address(usdc), 
            address(adapter),
            CAP,
            treasury
        );

        // Fund Alice
        usdc.mint(alice, INITIAL_BALANCE);
    }

    // ==========================================
    // 1. MINT / BURN
    // ==========================================
    function test_Mint_Success() public {
        uint256 mintAmount = 100 * 1e18; // 100 Tokens
        uint256 expectedCost = 200 * 1e6; // $200 USDC

        vm.startPrank(alice);
        usdc.approve(address(splitter), expectedCost);
        splitter.mint(mintAmount);
        
        assertEq(splitter.tokenA().balanceOf(alice), mintAmount);
        assertEq(splitter.tokenB().balanceOf(alice), mintAmount);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - expectedCost);
        
        // Vault should hold the funds
        assertEq(adapter.balanceOf(address(splitter)), expectedCost);
        vm.stopPrank();
    }

    function test_Burn_Success() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Burn half
        splitter.burn(50 * 1e18);

        // Check refund
        assertEq(splitter.tokenA().balanceOf(alice), 50 * 1e18);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 100 * 1e6);
        vm.stopPrank();
    }

    // ==========================================
    // 2. LIQUIDATION
    // ==========================================
    function test_Liquidation_And_EmergencyRedeem() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 1. Crash Price ($2.50)
        oracle.updatePrice(250_000_000);

        // 2. Alice redeems ONLY Bear Token
        vm.startPrank(alice);
        splitter.emergencyRedeem(100 * 1e18);
        
        // Got full $200 back
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE);
        assertEq(splitter.tokenA().balanceOf(alice), 0);
        vm.stopPrank();
    }

    // ==========================================
    // 3. YIELD HARVESTING (With Surplus)
    // ==========================================
    function test_HarvestYield_Success() public {
        // 1. Alice mints
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Setup Staking Address (Using new governance flow)
        splitter.proposeFeeReceivers(treasury, staking);
        vm.warp(block.timestamp + 7 days);
        splitter.finalizeFeeReceivers();

        // 3. Simulate Yield (Adapter gains 100 USDC profit)
        // Manual mint to adapter to simulate interest accrual
        aUsdc.mint(address(adapter), 100 * 1e6);

        // 4. Harvest
        splitter.harvestYield();

        // 5. Verify Split
        // Total Profit: 100 USDC -> Treasury 20, Staking 80
        assertEq(usdc.balanceOf(treasury), 20 * 1e6);
        assertEq(usdc.balanceOf(staking), 80 * 1e6);
    }

    function test_Harvest_RevertsIfNoSurplus() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        vm.expectRevert(SyntheticSplitter.Splitter__NoSurplus.selector);
        splitter.harvestYield();
    }

    // ==========================================
    // 4. GOVERNANCE: TIME LOCKS
    // ==========================================
    function test_Governance_UpdateFeeReceivers() public {
        // 1. Propose
        splitter.proposeFeeReceivers(address(0x111), address(0x222));
        
        // 2. Try Finalize Early (Should Fail)
        vm.expectRevert(SyntheticSplitter.Splitter__TimelockActive.selector);
        splitter.finalizeFeeReceivers();

        // 3. Wait
        vm.warp(block.timestamp + 7 days);

        // 4. Finalize
        splitter.finalizeFeeReceivers();
        
        assertEq(splitter.treasury(), address(0x111));
        assertEq(splitter.staking(), address(0x222));
    }

    function test_Governance_MigrateAdapter() public {
        // 1. Deploy New Adapter
        YieldAdapter adapter2 = new YieldAdapter(
            IERC20(address(usdc)), address(pool), address(aUsdc), address(this)
        );

        // 2. Propose
        splitter.proposeAdapter(address(adapter2));

        // 3. Wait
        vm.warp(block.timestamp + 7 days);

        // 4. Finalize
        // (Assuming alice has funds in old adapter, they should move)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        splitter.finalizeAdapter();

        assertEq(address(splitter.yieldAdapter()), address(adapter2));
        // Check funds moved (200 USDC)
        assertEq(adapter2.balanceOf(address(splitter)), 200 * 1e6);
        assertEq(adapter.balanceOf(address(splitter)), 0);
    }
}
