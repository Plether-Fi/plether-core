// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
}

contract SyntheticSplitterTest is Test {
    SyntheticSplitter splitter;
    YieldAdapter adapter;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;

    address alice = address(0x1);
    address treasury = address(0x999);
    address staking = address(0x888);
    
    uint256 constant CAP = 200_000_000; // $2.00

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc)); 
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket");

        // Fund Pool and Alice
        usdc.mint(address(pool), 1_000_000 * 1e6);
        usdc.mint(alice, 10_000 * 1e6);

        adapter = new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this));

        splitter = new SyntheticSplitter(
            address(oracle), 
            address(usdc), 
            address(adapter),
            CAP,
            treasury
        );
    }

    // --- MINT WITH BUFFER ---
    function test_Mint_SplitsToBuffer() public {
        uint256 mintAmount = 100 * 1e18; // 100 Tokens
        uint256 cost = 200 * 1e6;        // $200 USDC

        vm.startPrank(alice);
        usdc.approve(address(splitter), cost);
        splitter.mint(mintAmount);
        vm.stopPrank();

        // 1. Check Splitter Buffer (10%)
        // 10% of 200 = 20 USDC
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6);

        // 2. Check Adapter Deposit (90%)
        // 90% of 200 = 180 USDC
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6);
    }

    // --- BURN WITH BUFFER ---
    function test_Burn_UsesBufferFirst() public {
        // Setup: Mint 100 ($200 cost -> 20 in Buffer, 180 in Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Act: Burn 10 ($20 Refund)
        // Since Buffer has 20, it should cover this entirely
        splitter.burn(10 * 1e18);
        vm.stopPrank();

        // Check:
        // Buffer should now be 0
        assertEq(usdc.balanceOf(address(splitter)), 0);
        // Adapter should be untouched (still 180)
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6);
    }

    function test_Burn_UsesAdapterIfBufferEmpty() public {
        // Setup: Mint 100 ($20 Buffer, 180 Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Act: Burn 50 ($100 Refund)
        // Buffer (20) < Refund (100). 
        // Logic: Pulls full 100 from Adapter.
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        // Check:
        // Buffer remains 20 (untouched because logic chose path B)
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6);
        // Adapter reduced by 100 (180 - 100 = 80)
        assertEq(adapter.balanceOf(address(splitter)), 80 * 1e6);
    }

    // --- EJECTION SEAT ---
    function test_EjectLiquidity() public {
        // Setup: Mint 100 ($20 Buffer, 180 Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Emergency! Aave is scary.
        splitter.ejectLiquidity();

        // Check:
        // Adapter Balance = 0
        assertEq(adapter.balanceOf(address(splitter)), 0);
        // Splitter Balance = 200 (20 Buffer + 180 Ejected)
        assertEq(usdc.balanceOf(address(splitter)), 200 * 1e6);

        // User can still burn (uses local balance)
        vm.startPrank(alice);
        splitter.burn(100 * 1e18);
        vm.stopPrank();
        
        assertEq(usdc.balanceOf(alice), 10_000 * 1e6); // Full refund
    }

    // --- YIELD HARVESTING ---
    function test_Harvest_WithBufferIncluded() public {
        // Setup: Mint 100 ($20 Buffer, 180 Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Simulate Yield: Adapter gains 50 USDC.
        // Adapter Assets: 180 + 50 = 230.
        // Local Buffer: 20.
        // Total Holdings: 250.
        // Required: 200.
        // Surplus: 50.
        aUsdc.mint(address(adapter), 50 * 1e6);

        splitter.harvestYield();

        // 20% of 50 = 10 (Treasury)
        // 80% of 50 = 40 (Staking -> Treasury Fallback if 0x0)
        assertEq(usdc.balanceOf(treasury), 50 * 1e6); 
    }
}
