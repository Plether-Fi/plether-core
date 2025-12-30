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

    function decimals() public pure override returns (uint8) {
        return 6;
    }
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
        // 3. Predict Splitter address (deployed at nonce + 2: adapter is next, splitter after)
        uint64 nonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), nonce + 1);
        // 4. Deploy Adapter with predicted Splitter address
        adapter =
            new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this), predictedSplitter);
        // 5. Deploy Splitter (will be at predictedSplitter address)
        splitter = new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(0));
        require(address(splitter) == predictedSplitter, "Address prediction failed");
        // 6. Setup Users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
    }

    // ==========================================
    // 0. CONSTRUCTOR AND SETUP
    // ==========================================
    function test_Constructor_RevertsOnInvalidArgs() public {
        vm.expectRevert("Invalid Oracle");
        new SyntheticSplitter(address(0), address(usdc), address(adapter), CAP, treasury, address(0));
        vm.expectRevert("Invalid USDC");
        new SyntheticSplitter(address(oracle), address(0), address(adapter), CAP, treasury, address(0));
        vm.expectRevert("Invalid Adapter");
        new SyntheticSplitter(address(oracle), address(usdc), address(0), CAP, treasury, address(0));
        vm.expectRevert("Invalid Cap");
        new SyntheticSplitter(address(oracle), address(usdc), address(adapter), 0, treasury, address(0));
        vm.expectRevert("Invalid Treasury");
        new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, address(0), address(0));
    }

    // ==========================================
    // 0.5 MINT ROUNDING SECURITY TESTS
    // ==========================================

    /**
     * @notice Verify that mint rounding favors the protocol (rounds UP)
     * @dev Fixed implementation uses Math.mulDiv with Rounding.Ceil
     *
     * Math:
     * - CAP = 2e8 ($2.00 in 8 decimals)
     * - USDC_MULTIPLIER = 1e20 (10^(18+8-6))
     * - usdcNeeded = ceil(amount * CAP / USDC_MULTIPLIER)
     */
    function test_Mint_RoundingFavorsProtocol() public {
        uint256 usdcMultiplier = splitter.USDC_MULTIPLIER();

        // Amount that would maximize rounding benefit if floor division was used
        uint256 minAmountFor1Usdc = usdcMultiplier / CAP;
        uint256 almostDoubleAmount = minAmountFor1Usdc * 2 - 1;

        // Calculate fair price (ceiling division)
        uint256 fairPrice = (almostDoubleAmount * CAP + usdcMultiplier - 1) / usdcMultiplier;

        // Actually call the contract to see what it charges
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1000 * 1e6);

        vm.startPrank(attacker);
        usdc.approve(address(splitter), type(uint256).max);
        uint256 balanceBefore = usdc.balanceOf(attacker);
        splitter.mint(almostDoubleAmount);
        uint256 actualCharged = balanceBefore - usdc.balanceOf(attacker);
        vm.stopPrank();

        // Contract should charge the fair (ceiling) price
        assertEq(actualCharged, fairPrice, "Mint should round UP to favor protocol");
    }

    /**
     * @notice Verify that users cannot profit from rounding by minting many small amounts
     * @dev With ceiling division, each mint charges at least the fair price
     */
    function test_Mint_NoRoundingExploit() public {
        uint256 usdcMultiplier = splitter.USDC_MULTIPLIER();

        // Amount that would maximize rounding benefit if floor division was used
        uint256 exploitAmount = (usdcMultiplier / CAP) * 2 - 1;

        address attacker = address(0xBAD);
        usdc.mint(attacker, 1000 * 1e6);

        vm.startPrank(attacker);
        usdc.approve(address(splitter), type(uint256).max);

        uint256 usdcBefore = usdc.balanceOf(attacker);
        uint256 totalTokensMinted = 0;
        uint256 iterations = 100;

        for (uint256 i = 0; i < iterations; i++) {
            splitter.mint(exploitAmount);
            totalTokensMinted += exploitAmount;
        }
        vm.stopPrank();

        uint256 usdcSpent = usdcBefore - usdc.balanceOf(attacker);

        // Calculate fair cost (ceiling division)
        uint256 fairCost = (totalTokensMinted * CAP + usdcMultiplier - 1) / usdcMultiplier;

        // User should have paid at least the fair cost (no profit from rounding)
        assertGe(usdcSpent, fairCost, "User should pay at least fair cost");

        emit log_named_uint("Tokens minted (wei)", totalTokensMinted);
        emit log_named_uint("USDC spent", usdcSpent);
        emit log_named_uint("Fair cost (rounded up)", fairCost);
    }

    /**
     * @notice Verify that previewMint returns the correct (ceiling) price
     */
    function test_PreviewMint_RoundsUp() public {
        uint256 usdcMultiplier = splitter.USDC_MULTIPLIER();
        uint256 exploitAmount = (usdcMultiplier / CAP) * 2 - 1;

        (uint256 previewRequired,,) = splitter.previewMint(exploitAmount);
        uint256 fairPrice = (exploitAmount * CAP + usdcMultiplier - 1) / usdcMultiplier;

        // previewMint should return the fair (rounded UP) price
        assertEq(previewRequired, fairPrice, "previewMint should round UP");
    }

    // ==========================================
    // 1. CORE LOGIC (Mint/Burn/Buffer)
    // ==========================================
    function test_Mint_CorrectlySplitsFunds() public {
        uint256 mintAmount = 100 * 1e18; // 100 Tokens
        uint256 cost = 200 * 1e6; // $200 USDC
        vm.startPrank(alice);
        usdc.approve(address(splitter), cost);
        splitter.mint(mintAmount);
        vm.stopPrank();
        // Check Buffer (10% of 200 = 20)
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6, "Buffer Incorrect");
        // Check Vault (90% of 200 = 180)
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Vault Incorrect");

        // Check Tokens
        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount);
        assertEq(splitter.TOKEN_B().balanceOf(alice), mintAmount);
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
        assertEq(usdc.balanceOf(address(splitter)), 0, "Buffer should be used first");
        assertEq(adapter.balanceOf(address(splitter)), 100 * 1e6, "Vault should only cover the shortage");
    }

    function test_ZeroAmount_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);

        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAmount.selector);
        splitter.mint(0);
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAmount.selector);
        splitter.burn(0);

        vm.stopPrank();
    }

    // ==========================================
    // 2. PAUSE AND SOLVENCY CHECKS
    // ==========================================
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

    function test_Pause_BlocksMintAndBurn() public {
        // 1. Setup: Mint initially so Alice has funds to burn later
        vm.startPrank(alice);
        usdc.approve(address(splitter), 1_000_000 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // 2. Admin Pauses
        splitter.pause();
        // Debug: Prove it is paused
        assertTrue(splitter.paused(), "Contract failed to pause");
        vm.startPrank(alice);

        // 3. Try Mint -> SHOULD REVERT (Entry is blocked)
        // We use generic check: "Just make sure it fails"
        vm.expectRevert();
        splitter.mint(10 * 1e18);
        // 4. Try Burn -> SHOULD SUCCEED (Exit is open)
        // No expectRevert here. If this fails, the test fails automatically.
        splitter.burn(10 * 1e18);
        vm.stopPrank();
        // 5. Verify the burn actually happened
        // Alice started with 100 Minted. Burned 10. Should have 90 left.
        assertEq(splitter.TOKEN_A().balanceOf(alice), 90 * 1e18, "Burn failed to execute during pause");
    }

    // ==========================================
    // 3. SAFETY CHECKS (Oracle/Sequencer/Caps)
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

    function test_Mint_RevertsSequencerDown() public {
        // Deploy with mock sequencer feed (since setUp uses address(0), redeploy)
        AggregatorV3Interface mockSequencer = AggregatorV3Interface(address(new MockOracle(0, "Sequencer")));
        SyntheticSplitter splitterWithFeed = new SyntheticSplitter(
            address(oracle), address(usdc), address(adapter), CAP, treasury, address(mockSequencer)
        );
        // Mock sequencer down (answer=1)
        vm.mockCall(
            address(mockSequencer),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, 1, block.timestamp - 2 hours, 0, 0) // answer=1 (down)
        );
        vm.expectRevert(SyntheticSplitter.Splitter__SequencerDown.selector);
        splitterWithFeed.mint(10 * 1e18); // Triggers _checkSequencer
    }

    function test_Mint_RevertsSequencerGracePeriod() public {
        // Deploy with mock sequencer feed
        AggregatorV3Interface mockSequencer = AggregatorV3Interface(address(new MockOracle(0, "Sequencer")));
        SyntheticSplitter splitterWithFeed = new SyntheticSplitter(
            address(oracle), address(usdc), address(adapter), CAP, treasury, address(mockSequencer)
        );
        // Mock up but within grace (startedAt recent)
        vm.mockCall(
            address(mockSequencer),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, 0, block.timestamp - 30 minutes, 0, 0) // answer=0, but startedAt <1hr
        );
        vm.expectRevert(SyntheticSplitter.Splitter__SequencerGracePeriod.selector);
        splitterWithFeed.mint(10 * 1e18);
    }

    // ==========================================
    // 4. LIQUIDATION & EMERGENCY
    // ==========================================
    function test_EmergencyRedeem_OnlyWorksIfLiquidated() public {
        // Normal price
        oracle.updatePrice(100_000_000);
        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__NotLiquidated.selector);
        splitter.emergencyRedeem(10 ether);
        vm.stopPrank();
    }

    function test_Liquidation_Success_BearGetsPaid() public {
        // 1. Mint 100 tokens ($200 Collateral)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // 2. Oracle Crashes to Cap ($2.00 / 200,000,000)
        oracle.updatePrice(200_000_000);
        // 3. Alice tries to Redeem
        // She has 100 Bear (tokenA) and 100 Bull (tokenB).
        // Only Bear should be redeemable for value.

        vm.startPrank(alice);
        splitter.emergencyRedeem(100 * 1e18);
        vm.stopPrank();
        // --- ASSERTIONS ---
        // Alice spent $200. She should get $200 back (100 Bear * $2.00).
        // Bull tokens are worthless/ignored.
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "Alice didn't get full payout");

        // Bear tokens burned
        assertEq(splitter.TOKEN_A().balanceOf(alice), 0);
        // Bull tokens still in wallet (but worthless)
        assertEq(splitter.TOKEN_B().balanceOf(alice), 100 * 1e18);

        // Contract is marked liquidated
        assertTrue(splitter.isLiquidated());
    }

    function test_Mint_RevertsIfLiquidated() public {
        // Mint at low price
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // Update to CAP
        oracle.updatePrice(int256(CAP));
        // Trigger set via successful redeem (must be large enough for non-zero USDC refund)
        vm.startPrank(alice);
        splitter.emergencyRedeem(1e12); // Sets isLiquidated, succeeds
        vm.stopPrank();
        assertTrue(splitter.isLiquidated());
        // Now mint reverts on isLiquidated check
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        vm.startPrank(alice);
        splitter.mint(10 * 1e18);
        vm.stopPrank();
    }

    function test_EmergencyRedeem_RevertsZeroAmount() public {
        oracle.updatePrice(int256(CAP)); // Liquidate
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAmount.selector);
        splitter.emergencyRedeem(0);
    }

    function test_Burn_RevertsZeroRefund() public {
        // Mint first
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);

        // Try to burn amount too small for any USDC refund
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroRefund.selector);
        splitter.burn(1); // 1 wei rounds to 0 USDC
        vm.stopPrank();
    }

    function test_EmergencyRedeem_RevertsZeroRefund() public {
        // Mint first
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Trigger liquidation
        oracle.updatePrice(int256(CAP));

        // Try to redeem amount too small for any USDC refund
        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroRefund.selector);
        splitter.emergencyRedeem(1); // 1 wei rounds to 0 USDC
        vm.stopPrank();
    }

    function test_PreviewBurn_RevertsZeroRefund() public {
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroRefund.selector);
        splitter.previewBurn(1); // 1 wei rounds to 0 USDC
    }

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

    // ==========================================
    // 5. YIELD HARVESTING (Keeper Pattern)
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

    function test_Adapter_RejectsNonSplitterDeposits() public {
        // This test verifies the inflation attack protection:
        // Only the Splitter can deposit into the YieldAdapter
        address whale = address(0x999);
        usdc.mint(whale, 1_000_000 * 1e6);

        vm.startPrank(whale);
        usdc.approve(address(adapter), 1_000_000 * 1e6);

        // Whale tries to deposit directly into adapter - should fail
        vm.expectRevert(YieldAdapter.YieldAdapter__OnlySplitter.selector);
        adapter.deposit(1_000_000 * 1e6, whale);
        vm.stopPrank();

        // Verify adapter is empty (only splitter can deposit)
        assertEq(adapter.totalSupply(), 0);
    }

    function test_Harvest_UsesRedeemToAvoidRounding() public {
        // 1. Setup: Mint 100 Tokens ($200 Liability)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // 2. FORCE SURPLUS: Donate massive amount to Splitter Buffer
        // Liability = $200. We add $1000 to buffer.
        // Buffer = $1020. Adapter = $180.
        // Total = $1200. Liability = $200. Surplus = $1000.
        // Since Surplus ($1000) > Adapter Assets ($180), the logic MUST try to empty the adapter.
        usdc.mint(address(splitter), 1000 * 1e6);
        // 3. Setup Expectation
        // We want to verify that 'redeem' is called, NOT 'withdraw'.

        vm.startPrank(bob);
        // A. Simulate 'withdraw' reverting (The Bug)
        // If the contract calls withdraw(180), we make it revert with the specific 4626 error
        // indicating it asked for too many shares due to rounding.
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSelector(IERC4626.withdraw.selector),
            abi.encodeWithSignature("ERC4626ExceededMaxWithdraw(address,uint256,uint256)", address(0), 0, 0)
        );
        // B. Expect 'redeem' to be called (The Fix)
        // The contract should skip withdraw and call redeem instead.
        vm.expectCall(address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector));
        // 4. Execution
        splitter.harvestYield();

        vm.stopPrank();
    }

    function test_Harvest_RoutesToTreasuryIfNoStaking() public {
        // 1. Setup: Mint 100 Tokens ($200)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // 2. Setup Treasury/Staking=0
        splitter.proposeFeeReceivers(treasury, address(0));
        vm.warp(block.timestamp + 8 days);
        splitter.finalizeFeeReceivers();
        // 3. Simulate Yield ($100 profit)
        aUsdc.mint(address(adapter), 100 * 1e6);
        // 4. Harvest
        splitter.harvestYield();
        // Assert: stakingShare goes to treasury (total treasury = 20% + 80% = 99% of remaining after callerCut)
        assertApproxEqAbs(usdc.balanceOf(treasury), 99 * 1e6, 10); // Rough check
    }

    // ==========================================
    // 6. GOVERNANCE (Hostage Defense)
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

    function test_Governance_AdapterMigration_MovesFunds() public {
        // 1. Setup: User Mints 100 tokens ($20 Buffer, $180 in Old Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();
        // 2. Deploy NEW Adapter (splitter already exists, so pass its address directly)
        YieldAdapter newAdapter =
            new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this), address(splitter));
        // 3. Propose & Wait
        splitter.proposeAdapter(address(newAdapter));
        vm.warp(block.timestamp + 8 days); // Pass TimeLock
        // 4. Finalize
        splitter.finalizeAdapter();
        // --- ASSERTIONS ---
        // Old Adapter should be empty
        assertEq(adapter.balanceOf(address(splitter)), 0, "Old adapter not empty");

        // New Adapter should have the $180
        assertEq(newAdapter.balanceOf(address(splitter)), 180 * 1e6, "New adapter didn't receive funds");

        // Splitter State updated
        assertEq(address(splitter.yieldAdapter()), address(newAdapter));
        // 5. Verify User can still Burn (Connecting to New Adapter)
        vm.startPrank(alice);
        splitter.burn(100 * 1e18); // Full Exit
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_ProposeFeeReceivers_RevertsInvalidTreasury() public {
        vm.expectRevert("Invalid Treasury");
        splitter.proposeFeeReceivers(address(0), staking);
    }

    function test_FinalizeFeeReceivers_RevertsNoProposal() public {
        vm.expectRevert(SyntheticSplitter.Splitter__InvalidProposal.selector);
        splitter.finalizeFeeReceivers();
    }

    function test_FinalizeFeeReceivers_RevertsTimelockActive() public {
        splitter.proposeFeeReceivers(treasury, staking);
        vm.expectRevert(SyntheticSplitter.Splitter__TimelockActive.selector);
        splitter.finalizeFeeReceivers(); // Before warp
    }

    function test_ProposeAdapter_RevertsInvalidAdapter() public {
        vm.expectRevert("Invalid Adapter");
        splitter.proposeAdapter(address(0));
    }

    function test_FinalizeAdapter_RevertsNoProposal() public {
        vm.expectRevert(SyntheticSplitter.Splitter__InvalidProposal.selector);
        splitter.finalizeAdapter();
    }

    function test_FinalizeAdapter_RevertsTimelockActive() public {
        splitter.proposeAdapter(address(adapter)); // Reuse for test
        vm.expectRevert(SyntheticSplitter.Splitter__TimelockActive.selector);
        splitter.finalizeAdapter();
    }
}
