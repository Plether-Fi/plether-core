// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

// 6 Decimal USDC Mock
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
    address bob = address(0x2); // Keeper
    address treasury = address(0x999);
    address staking = address(0x888);
    
    uint256 constant CAP = 200_000_000; // $2.00 (8 decimals)
    uint256 constant INITIAL_BALANCE = 100_000 * 1e6; 

    function setUp() public {

        // We move to year 2025 to avoid underflow when subtracting 24 hours
        vm.warp(1735689600);

        // 1. Deploy Mocks
        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc)); 
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket"); // $1.00 Start

        // 2. Fund Pool (So withdrawals work)
        usdc.mint(address(pool), 1_000_000 * 1e6);

        // 3. Deploy Adapter
        adapter = new YieldAdapter(
            IERC20(address(usdc)), 
            address(pool), 
            address(aUsdc), 
            address(this)
        );

        // 4. Deploy Splitter
        splitter = new SyntheticSplitter(
            address(oracle), 
            address(usdc), 
            address(adapter),
            CAP,
            treasury,
            address(0)
        );

        // 5. Setup Users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
    }

    // ==========================================
    // 1. CORE LOGIC (Mint/Burn/Buffer)
    // ==========================================

    function test_Mint_CorrectlySplitsFunds() public {
        uint256 mintAmount = 100 * 1e18; // 100 Tokens
        uint256 cost = 200 * 1e6;        // $200 USDC

        vm.startPrank(alice);
        usdc.approve(address(splitter), cost);
        splitter.mint(mintAmount);
        vm.stopPrank();

        // Check Buffer (10% of 200 = 20)
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6, "Buffer Incorrect");
        // Check Vault (90% of 200 = 180)
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Vault Incorrect");
        
        // Check Tokens
        assertEq(splitter.tokenA().balanceOf(alice), mintAmount);
        assertEq(splitter.tokenB().balanceOf(alice), mintAmount);
    }

    function test_Burn_UsesBufferFirst() public {
        // Setup: Mint 100 ($20 Buffer, 180 Vault)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Act: Burn 10 ($20 Refund)
        // Buffer has 20. Should barely cover it without touching vault.
        splitter.burn(10 * 1e18);
        vm.stopPrank();

        // Assertions
        assertEq(usdc.balanceOf(address(splitter)), 0, "Buffer should be empty");
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Vault should be untouched");
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 180 * 1e6); // Only spent 180 net
    }

    function test_Burn_UsesVaultIfBufferInsufficient() public {
        // Setup: Mint 100 ($20 Buffer, 180 Vault)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Act: Burn 50 ($100 Refund)
        // Buffer (20) < Refund (100). Must withdraw 100 from Vault.
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        // Assertions
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6, "Buffer should be ignored/preserved");
        assertEq(adapter.balanceOf(address(splitter)), 80 * 1e6, "Vault should decrease by 100");
    }

    function test_Burn_WorksWhilePaused_IfSolvent() public {
        // 1. Setup: Mint 100 Tokens ($200)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Admin Ejects Liquidity (Pauses + Moves funds to buffer)
        splitter.ejectLiquidity(); 
        assertTrue(splitter.paused());

        // 3. Alice tries to burn while Paused
        vm.startPrank(alice);
        
        // This should SUCCEED now (it used to revert)
        // Solvency check passes: 200 USDC assets == 200 USDC liabilities
        splitter.burn(50 * 1e18); 
        
        vm.stopPrank();

        // Check balance: Alice got $100 back
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 100 * 1e6);
    }

    function test_Burn_RevertsWhilePaused_IfInsolvent() public {
        // 1. Setup: Mint 100 Tokens ($200)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Admin Pauses
        splitter.pause();

        // 3. Simulate Loss: Someone hacked the wallet/adapter and stole 1 USDC
        // (We simulate this by burning 1 USDC from the splitter's local balance)
        // Realistically this would happen via adapter loss
        vm.mockCall(
            address(adapter), 
            abi.encodeWithSelector(IERC4626.convertToAssets.selector), 
            abi.encode(179 * 1e6) // Adapter reports it lost $1
        );

        // 4. Alice tries to burn
        vm.startPrank(alice);
        
        // Expect Revert due to Solvency Check
        // Assets ($20 Buffer + $179 Adapter = $199) < Liabilities ($200)
        vm.expectRevert(bytes("Paused & Insolvent: Burn Locked"));
        splitter.burn(50 * 1e18);
        
        vm.stopPrank();
    }

    // ==========================================
    // 2. SAFETY CHECKS (Oracle/Caps)
    // ==========================================

    function test_Revert_IfOracleStale() public {
        // Make oracle old (25 hours ago)
        oracle.setUpdatedAt(block.timestamp - 25 hours);

        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        
        vm.expectRevert(SyntheticSplitter.Splitter__StalePrice.selector);
        splitter.mint(10 * 1e18);
        vm.stopPrank();
    }

    function test_Revert_IfLiquidationTriggered() public {
        // Set price to $2.00 (CAP)
        oracle.updatePrice(200_000_000);

        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.mint(10 * 1e18);
        vm.stopPrank();
    }

    function test_EmergencyRedeem_OnlyWorksIfLiquidated() public {
        // Normal price
        oracle.updatePrice(100_000_000);

        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__NotLiquidated.selector);
        splitter.emergencyRedeem(10 ether);
        vm.stopPrank();
    }

    // ==========================================
    // 3. YIELD HARVESTING (Keeper Pattern)
    // ==========================================

    function test_Harvest_RevertsBelowThreshold() public {
        // 1. Mint
        vm.startPrank(alice);
        usdc.approve(address(splitter), 2000 * 1e6);
        splitter.mint(1000 * 1e18);
        vm.stopPrank();

        // 2. Simulate Yield ($10 profit)
        // Threshold is $50. This should fail.
        aUsdc.mint(address(adapter), 10 * 1e6);

        vm.expectRevert(SyntheticSplitter.Splitter__NoSurplus.selector);
        splitter.harvestYield();
    }

    function test_Harvest_SuccessWithRewards() public {
        // 1. Setup
        vm.startPrank(alice);
        usdc.approve(address(splitter), 2000 * 1e6);
        splitter.mint(1000 * 1e18);
        vm.stopPrank();

        // Setup Treasury/Staking
        splitter.proposeFeeReceivers(treasury, staking);
        vm.warp(block.timestamp + 8 days);
        splitter.finalizeFeeReceivers();

        // 2. Simulate Yield ($100 profit)
        // Threshold is $50. This should pass.
        aUsdc.mint(address(adapter), 100 * 1e6);
        
        // 3. Bob (Keeper) calls it
        vm.startPrank(bob);
        splitter.harvestYield();
        vm.stopPrank();

        // --- MATH CHECK ---
        // Surplus: 100 USDC
        // 1. Bob Reward (1%): 1 USDC
        assertApproxEqAbs(usdc.balanceOf(bob), INITIAL_BALANCE + 1 * 1e6, 10);
        
        // Treasury (20% of 99): ~19.8 USDC -> 19_800_000
        assertApproxEqAbs(usdc.balanceOf(treasury), 19_800_000, 10);
        
        // Staking (80% of 99): ~79.2 USDC -> 79_200_000
        assertApproxEqAbs(usdc.balanceOf(staking), 79_200_000, 10);
    }

    function test_Harvest_RevertsIfCountingOtherPeoplesMoney() public {
        // 1. Setup: Alice mints 100 tokens ($200 cost)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Setup: A "Whale" deposits $1,000,000 into the SAME Adapter
        address whale = address(0x999);
        usdc.mint(whale, 1_000_000 * 1e6);
        
        vm.startPrank(whale);
        usdc.approve(address(adapter), 1_000_000 * 1e6);
        adapter.deposit(1_000_000 * 1e6, whale);
        vm.stopPrank();

        // 3. Simulate Actual Yield
        // We need massive yield because the Splitter only owns ~0.018% of the pool.
        // To get > $50 surplus for Splitter, we need > $280k total yield.
        // Let's use $300,000.
        uint256 massiveYield = 300_000 * 1e6;
        aUsdc.mint(address(adapter), massiveYield); 

        // 4. Bob tries to harvest
        vm.startPrank(bob);
        
        // WITH BUG (totalAssets): 
        //   Calculates surplus = ~$1.3 Million. 
        //   Tries to withdraw $1.3M. 
        //   Reverts because Splitter lacks enough shares to burn.
        
        // WITH FIX (convertToAssets):
        //   Calculates surplus = Splitter's share of yield (~$54).
        //   $54 > $50 Threshold.
        //   Withdraws $54. Success.
        splitter.harvestYield();
        vm.stopPrank();

        // 5. Verification
        // Bob gets 1% of the SURPLUS (~$54), roughly 0.54 USDC.
        // We use a wider tolerance (1e6 = 1 USDC) because dilution math is inexact.
        assertApproxEqAbs(usdc.balanceOf(bob), INITIAL_BALANCE + 540_000, 1e5);
    }

    // ==========================================
    // 4. GOVERNANCE (Hostage Defense)
    // ==========================================

    function test_HostageDefense_CannotFinalizeImmediatelyAfterUnpause() public {
        // 1. Propose
        splitter.proposeFeeReceivers(treasury, staking);
        
        // 2. Pause
        splitter.pause();

        // 3. Wait 8 days (Time lock ok, but Paused)
        vm.warp(block.timestamp + 8 days);

        // 4. Try finalize while paused -> Revert with Locked Error
        // FIX: Expect the custom error, not the string
        vm.expectRevert(SyntheticSplitter.Splitter__GovernanceLocked.selector);
        splitter.finalizeFeeReceivers();

        // 5. Unpause
        splitter.unpause();

        // 6. Try finalize immediately -> Revert with Locked Error (Liveness check)
        vm.expectRevert(SyntheticSplitter.Splitter__GovernanceLocked.selector);
        splitter.finalizeFeeReceivers();
    }

    function test_HostageDefense_SuccessAfterWait() public {
        // ... Previous steps 1-5 ...
        splitter.proposeFeeReceivers(treasury, staking);
        splitter.pause();
        vm.warp(block.timestamp + 8 days);
        splitter.unpause();

        // 6. Wait another 7 days (Liveness Check)
        vm.warp(block.timestamp + 7 days);

        // 7. Now it works
        splitter.finalizeFeeReceivers();
        assertEq(splitter.treasury(), treasury);
    }

    // ==========================================
    // 5. EJECTION (Emergency)
    // ==========================================

    function test_EjectLiquidity_PausesAndSecuresFunds() public {
        // 1. Mint
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Eject
        splitter.ejectLiquidity();

        // Assert: Funds moved to splitter
        assertEq(usdc.balanceOf(address(splitter)), 200 * 1e6);
        assertEq(adapter.balanceOf(address(splitter)), 0);

        // Assert: Contract is Paused
        assertTrue(splitter.paused());

        // Assert: Minting disabled (via Pause)
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.startPrank(alice);
        splitter.mint(10 * 1e18);
        vm.stopPrank();
    }
}
