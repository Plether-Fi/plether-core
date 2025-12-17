// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

// 1. Specialized Mock for USDC (6 Decimals)
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
    address bob = address(0x2);
    
    // Constants
    uint256 constant CAP = 200_000_000; // $2.00 (8 decimals)
    uint256 constant INITIAL_BALANCE = 10_000 * 1e6; // $10,000 USDC

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockUSDC();
        // Note: aToken usually matches underlying decimals
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc)); 
        pool = new MockPool(address(usdc), address(aUsdc));
        
        // Oracle starts at $1.00 (Healthy)
        oracle = new MockOracle(100_000_000, "Basket");

        // Fund Pool so it can pay back withdrawals
        usdc.mint(address(pool), 1_000_000 * 1e6);

        // 2. Deploy Yield Adapter
        adapter = new YieldAdapter(
            IERC20(address(usdc)),
            address(pool),
            address(aUsdc),
            address(this) // We (Test) own it initially
        );

        // 3. Deploy Splitter (Injecting the Adapter!)
        splitter = new SyntheticSplitter(
            address(oracle), 
            address(usdc), 
            address(adapter),
            CAP
        );

        // 4. Transfer Ownership of Adapter to Splitter (Important!)
        // Since we removed 'recoverAdapterFunds', the Splitter doesn't *need* to own the adapter
        // strictly speaking if we treat it as a vault. 
        // HOWEVER, for 'withdrawAll' or 'rescue' logic if kept, ownership matters.
        // In the final ERC4626 implementation, the Splitter is just a user. 
        // Ownership stays with YOU (the Admin).
        adapter.transferOwnership(address(this));

        // 5. Setup Alice
        usdc.mint(alice, INITIAL_BALANCE);
    }

    // ==========================================
    // 1. Core Logic (Mint/Burn)
    // ==========================================

    function test_Mint_Success_With6Decimals() public {
        uint256 mintAmount = 100 * 1e18; // Mint 100 Synthetic Tokens
        
        // Math Check:
        // Cap = $2.00. Total Value = $200.
        // USDC Needed = 200 * 1e6 = 200,000,000
        uint256 expectedCost = 200 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(splitter), expectedCost);
        
        splitter.mint(mintAmount);
        
        // Check 1: Tokens received
        assertEq(splitter.tokenA().balanceOf(alice), mintAmount);
        assertEq(splitter.tokenB().balanceOf(alice), mintAmount);
        
        // Check 2: USDC spent
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - expectedCost);

        // Check 3: Funds are in the Vault (Adapter)
        // Splitter should hold shares of the adapter
        uint256 shares = adapter.balanceOf(address(splitter));
        // Since exchange rate is 1:1 in mock, shares = assets
        assertEq(shares, expectedCost);
        
        vm.stopPrank();
    }

    function test_Burn_Success() public {
        // Setup: Mint 100 first
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Act: Burn 50
        // Refund should be $100 USDC (100 * 1e6)
        splitter.burn(50 * 1e18);

        // Check balances
        assertEq(splitter.tokenA().balanceOf(alice), 50 * 1e18);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 100 * 1e6);
        
        vm.stopPrank();
    }

    // ==========================================
    // 2. Liquidation Logic
    // ==========================================

    function test_Liquidation_RevertsMint() public {
        // 1. Oracle pumps to $2.01 (Above Cap)
        oracle.updatePrice(201_000_000);

        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);

        // 2. Expect Revert
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.mint(10 * 1e18);
    }

    function test_EmergencyRedeem() public {
        // Setup: Alice has tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // 1. Crash the Dollar (Basket > $2.00)
        oracle.updatePrice(250_000_000);

        // 2. Alice tries to redeem ONLY Bear Token (tokenA)
        // She should get full $2.00 value per token
        // 100 tokens * $2.00 = $200 USDC
        
        // Note: She keeps tokenB, but it's worthless now
        splitter.emergencyRedeem(100 * 1e18);

        // Check: She got full refund
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE);
        assertEq(splitter.tokenA().balanceOf(alice), 0);
        // Token B still in wallet (worthless souvenir)
        assertEq(splitter.tokenB().balanceOf(alice), 100 * 1e18); 
    }

    // ==========================================
    // 3. Adapter Migration (The Complex One)
    // ==========================================

    function test_Migration_Flow() public {
        // 1. Alice puts money in Adapter 1 via Splitter
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Deploy Adapter 2 (New Yield Source)
        YieldAdapter adapter2 = new YieldAdapter(
            IERC20(address(usdc)),
            address(pool),
            address(aUsdc),
            address(this)
        );

        // 3. Propose Adapter 2
        splitter.proposeAdapter(address(adapter2));

        // 4. Try to finalize early (Should Fail)
        vm.expectRevert(SyntheticSplitter.Splitter__TimelockActive.selector);
        splitter.finalizeAdapter();

        // 5. Wait 7 days
        vm.warp(block.timestamp + 7 days);

        // 6. Finalize
        splitter.finalizeAdapter();

        // CHECK RESULTS:
        // Adapter 1 should be empty (Splitter redeemed everything)
        assertEq(adapter.balanceOf(address(splitter)), 0);
        
        // Adapter 2 should hold the funds (Splitter deposited everything)
        // Note: 200 USDC
        assertEq(adapter2.balanceOf(address(splitter)), 200 * 1e6);
        
        // Splitter state updated
        assertEq(address(splitter.yieldAdapter()), address(adapter2));
    }

    // ==========================================
    // 4. Admin / Pausable
    // ==========================================

    function test_Pause_PreventsMinting() public {
        splitter.pause();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        splitter.mint(10 * 1e18);
        vm.stopPrank();

        splitter.unpause();
        
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(10 * 1e18); // Works now
    }
}
