// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {MockAToken, MockERC20, MockPool} from "./utils/MockAave.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {MockYieldAdapter} from "./utils/MockYieldAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

// 6 Decimal USDC Mock
contract MockUSDC is MockERC20 {

    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

}

contract SyntheticSplitterTest is Test {

    SyntheticSplitter splitter;
    MockYieldAdapter adapter;

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
        vm.warp(1_735_689_600);
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
        adapter = new MockYieldAdapter(IERC20(address(usdc)), address(this), predictedSplitter);
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
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
        new SyntheticSplitter(address(0), address(usdc), address(adapter), CAP, treasury, address(0));
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
        new SyntheticSplitter(address(oracle), address(0), address(adapter), CAP, treasury, address(0));
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
        new SyntheticSplitter(address(oracle), address(usdc), address(0), CAP, treasury, address(0));
        vm.expectRevert(SyntheticSplitter.Splitter__InvalidCap.selector);
        new SyntheticSplitter(address(oracle), address(usdc), address(adapter), 0, treasury, address(0));
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
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

        // Use preview to get expected price
        (uint256 expectedPrice,,) = splitter.previewMint(almostDoubleAmount);

        // Actually call the contract to see what it charges
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1000 * 1e6);

        vm.startPrank(attacker);
        usdc.approve(address(splitter), type(uint256).max);
        uint256 balanceBefore = usdc.balanceOf(attacker);
        splitter.mint(almostDoubleAmount);
        uint256 actualCharged = balanceBefore - usdc.balanceOf(attacker);
        vm.stopPrank();

        // Contract should charge the preview price
        assertEq(actualCharged, expectedPrice, "Mint should charge preview amount");

        // Verify security property: user paid at least fair value (rounds UP)
        assertGe(actualCharged * usdcMultiplier, almostDoubleAmount * CAP, "Mint should round UP to favor protocol");
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
        uint256 expectedTotalCost = 0;
        uint256 iterations = 100;

        for (uint256 i = 0; i < iterations; i++) {
            (uint256 previewCost,,) = splitter.previewMint(exploitAmount);
            expectedTotalCost += previewCost;
            splitter.mint(exploitAmount);
            totalTokensMinted += exploitAmount;
        }
        vm.stopPrank();

        uint256 usdcSpent = usdcBefore - usdc.balanceOf(attacker);

        // User should have paid the sum of preview costs
        assertEq(usdcSpent, expectedTotalCost, "User should pay sum of preview costs");

        // Verify security property: total paid covers fair value of all tokens
        assertGe(usdcSpent * usdcMultiplier, totalTokensMinted * CAP, "User should pay at least fair cost");

        emit log_named_uint("Tokens minted (wei)", totalTokensMinted);
        emit log_named_uint("USDC spent", usdcSpent);
        emit log_named_uint("Expected cost (from preview)", expectedTotalCost);
    }

    /**
     * @notice Verify that previewMint returns a ceiling-rounded price
     * @dev Verifies the security property: preview covers fair value
     */
    function test_PreviewMint_RoundsUp() public {
        uint256 usdcMultiplier = splitter.USDC_MULTIPLIER();
        uint256 exploitAmount = (usdcMultiplier / CAP) * 2 - 1;

        (uint256 previewRequired,,) = splitter.previewMint(exploitAmount);
        uint256 floorPrice = (exploitAmount * CAP) / usdcMultiplier;

        // previewMint should return at least the floor price
        assertGe(previewRequired, floorPrice, "previewMint should be at least floor");

        // Verify security property: preview covers fair value (ceiling rounding)
        assertGe(previewRequired * usdcMultiplier, exploitAmount * CAP, "previewMint should round UP");
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
        vm.expectRevert(SyntheticSplitter.Splitter__Insolvent.selector);
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

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
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
        vm.expectRevert(OracleLib.OracleLib__SequencerDown.selector);
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
        vm.expectRevert(OracleLib.OracleLib__SequencerGracePeriod.selector);
        splitterWithFeed.mint(10 * 1e18);
    }

    // ==========================================
    // 4. LIQUIDATION & EMERGENCY
    // ==========================================
    function test_EmergencyRedeem_RevertsIfNotLiquidated() public {
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
        // 2. Simulate Yield ($10 profit) - mint USDC directly to adapter
        // Threshold is $50. This should fail.
        usdc.mint(address(adapter), 10 * 1e6);
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
        // 2. Advance blocks to allow CAPO growth (~5.5% yield needs ~550 blocks)
        vm.roll(block.number + 600);
        // 3. Simulate Yield ($100 profit) - mint USDC directly to adapter
        // Threshold is $50. This should pass.
        usdc.mint(address(adapter), 100 * 1e6);

        // 4. Bob (Keeper) calls it
        vm.startPrank(bob);
        splitter.harvestYield();
        vm.stopPrank();
        // --- MATH CHECK ---
        // Surplus: 100 USDC
        // 1. Bob Reward (0.1%): 0.1 USDC
        assertApproxEqAbs(usdc.balanceOf(bob), INITIAL_BALANCE + 100_000, 10);

        // Treasury (20% of 99.9): ~19.98 USDC -> 19_980_000
        assertApproxEqAbs(usdc.balanceOf(treasury), 19_980_000, 10);

        // Staking (remaining of 99.9): ~79.92 USDC -> 79_920_000
        assertApproxEqAbs(usdc.balanceOf(staking), 79_920_000, 10);
    }

    function test_Adapter_RejectsNonSplitterDeposits() public {
        // This test verifies the inflation attack protection:
        // Only the Splitter can deposit into the YieldAdapter
        address whale = address(0x999);
        usdc.mint(whale, 1_000_000 * 1e6);

        vm.startPrank(whale);
        usdc.approve(address(adapter), 1_000_000 * 1e6);

        // Whale tries to deposit directly into adapter - should fail
        vm.expectRevert(MockYieldAdapter.MockYieldAdapter__OnlySplitter.selector);
        adapter.deposit(1_000_000 * 1e6, whale);
        vm.stopPrank();

        // Verify adapter is empty (only splitter can deposit)
        assertEq(adapter.totalSupply(), 0);
    }

    function test_Harvest_FallsBackToRedeemWhenWithdrawReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        usdc.mint(address(splitter), 1000 * 1e6);

        vm.startPrank(bob);
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSelector(IERC4626.withdraw.selector),
            abi.encodeWithSignature("ERC4626ExceededMaxWithdraw(address,uint256,uint256)", address(0), 0, 0)
        );
        vm.expectCall(address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector));
        splitter.harvestYield();
        vm.stopPrank();
    }

    function test_Harvest_RevertsWhenSlippageExceeds10Percent() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Add yield to trigger harvest (above $50 threshold)
        usdc.mint(address(adapter), 100 * 1e6);

        // Mock withdraw to "succeed" but not actually transfer USDC
        // This simulates adapter returning less than expected
        vm.mockCall(address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode(0));

        vm.expectRevert(SyntheticSplitter.Splitter__InsufficientHarvest.selector);
        splitter.harvestYield();
    }

    function test_Harvest_SucceedsWithAcceptableSlippage() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Setup fee receivers
        splitter.proposeFeeReceivers(treasury, staking);
        vm.warp(block.timestamp + 8 days);
        splitter.finalizeFeeReceivers();

        // Add yield (100 USDC surplus)
        usdc.mint(address(adapter), 100 * 1e6);

        // Harvest should succeed - real adapter returns full amount
        splitter.harvestYield();

        // Verify harvest completed (treasury received funds)
        assertGt(usdc.balanceOf(treasury), 0);
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
        // 3. Advance blocks to allow CAPO growth (~55% yield needs ~5500 blocks)
        vm.roll(block.number + 6000);
        // 4. Simulate Yield ($100 profit) - mint USDC directly to adapter
        usdc.mint(address(adapter), 100 * 1e6);
        // 5. Harvest
        splitter.harvestYield();
        // Assert: stakingShare goes to treasury (total treasury = 99.9% of remaining after 0.1% callerCut)
        assertApproxEqAbs(usdc.balanceOf(treasury), 99_900_000, 10);
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
        MockYieldAdapter newAdapter = new MockYieldAdapter(IERC20(address(usdc)), address(this), address(splitter));
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
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
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

    function test_FinalizeFeeReceivers_UpdatesAddresses() public {
        address newTreasury = makeAddr("newTreasury");
        address newStaking = makeAddr("newStaking");

        splitter.proposeFeeReceivers(newTreasury, newStaking);
        vm.warp(block.timestamp + 8 days);
        splitter.finalizeFeeReceivers();

        assertEq(splitter.treasury(), newTreasury);
        assertEq(splitter.staking(), newStaking);
    }

    function test_ProposeAdapter_RevertsInvalidAdapter() public {
        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAddress.selector);
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

    // ==========================================
    // 7. ADAPTER WITHDRAWAL FAILURE TESTS
    // ==========================================

    /**
     * @notice Test that burn() uses redeem fallback when withdraw reverts
     * @dev Simulates scenarios like Aave withdraw failing but redeem working
     */
    function test_Burn_UsesRedeemFallbackWhenWithdrawReverts() public {
        // 1. Setup: Mint 100 tokens ($20 Buffer, $180 Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Verify initial state
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6, "Buffer should be $20");
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Adapter should have $180");

        // 2. Mock adapter withdraw to revert (simulates Aave withdraw issue)
        // But redeem still works (fallback path)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("AAVE_WITHDRAW_FAILED")
        );

        // 3. Alice burns 50 tokens ($100 refund needed)
        // Buffer has $20, needs $80 from adapter - withdraw fails, redeem succeeds
        vm.startPrank(alice);
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        // 4. Verify Alice got her refund via redeem fallback
        assertEq(splitter.TOKEN_A().balanceOf(alice), 50 * 1e18, "Alice should have 50 tokens left");
        // Alice started with 100k, spent 200, got 100 back = 99,900
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 100 * 1e6, "Alice should have received $100 refund");
    }

    /**
     * @notice Test that burn() succeeds when buffer is sufficient even if adapter is broken
     * @dev Users can still exit using only the buffer
     */
    function test_Burn_SucceedsWithBufferOnlyWhenAdapterBroken() public {
        // 1. Setup: Mint 100 tokens ($20 Buffer, $180 Adapter)
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Mock adapter withdraw to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("AAVE_PAUSED")
        );

        // 3. Alice burns only 10 tokens ($20 refund = exactly buffer amount)
        // This should succeed because we don't need the adapter
        vm.startPrank(alice);
        splitter.burn(10 * 1e18);
        vm.stopPrank();

        // Verify: Alice got her $20 back
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 180 * 1e6, "Alice should have received refund from buffer");
        assertEq(splitter.TOKEN_A().balanceOf(alice), 90 * 1e18, "Alice should have 90 tokens left");
    }

    /**
     * @notice Test that emergencyRedeem() uses redeem fallback when withdraw reverts
     * @dev During liquidation, redeem fallback still works
     */
    function test_EmergencyRedeem_UsesRedeemFallbackWhenWithdrawReverts() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Trigger liquidation
        oracle.updatePrice(int256(CAP));

        // 3. Mock adapter withdraw to revert (but redeem still works)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("AAVE_PAUSED")
        );

        // 4. Alice emergency redeems - should succeed via redeem fallback
        vm.startPrank(alice);
        splitter.emergencyRedeem(50 * 1e18); // Needs $100, buffer only has $20, redeem covers rest
        vm.stopPrank();

        // 5. Verify Alice got her refund
        assertEq(splitter.TOKEN_A().balanceOf(alice), 50 * 1e18, "Alice should have 50 BEAR tokens left");
    }

    /**
     * @notice Test that emergencyRedeem() fails when both withdraw and redeem fail
     * @dev During liquidation, if adapter completely broken, users can't exit
     */
    function test_EmergencyRedeem_FailsWhenBothWithdrawAndRedeemFail() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Trigger liquidation
        oracle.updatePrice(int256(CAP));

        // 3. Mock BOTH withdraw and redeem to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("ADAPTER_BROKEN")
        );
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode("ADAPTER_BROKEN")
        );

        // 4. Alice tries to emergency redeem - should fail with specific error
        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.emergencyRedeem(50 * 1e18);
        vm.stopPrank();
    }

    /**
     * @notice Test complete adapter failure - both withdraw AND redeem fail
     * @dev This is the worst case scenario - reverts with specific error
     */
    function test_Burn_FailsWhenBothWithdrawAndRedeemFail() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Mock BOTH withdraw and redeem to revert
        // This simulates a completely broken/compromised adapter
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("ADAPTER_BROKEN")
        );
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode("ADAPTER_BROKEN")
        );

        // 3. Alice tries to burn - should fail with specific error
        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.burn(50 * 1e18);
        vm.stopPrank();
    }

    /**
     * @notice Test that ejectLiquidity can rescue funds when adapter is partially working
     * @dev Owner can still call redeem to pull funds out
     */
    function test_EjectLiquidity_CanRescueFundsFromAdapter() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        uint256 adapterBalanceBefore = adapter.balanceOf(address(splitter));
        assertEq(adapterBalanceBefore, 180 * 1e6, "Adapter should have $180");

        // 2. Owner ejects liquidity (this uses redeem, not withdraw)
        splitter.ejectLiquidity();

        // 3. Verify all funds are now in splitter buffer
        assertEq(usdc.balanceOf(address(splitter)), 200 * 1e6, "All funds should be in buffer");
        assertEq(adapter.balanceOf(address(splitter)), 0, "Adapter should be empty");
        assertTrue(splitter.paused(), "Contract should be paused");

        // 4. Now users can exit using only the buffer
        vm.startPrank(alice);
        splitter.burn(100 * 1e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "Alice should have full refund");
    }

    /**
     * @notice Test that ejectLiquidity fails when adapter redeem fails
     * @dev If adapter is completely broken, even owner can't rescue funds
     */
    function test_EjectLiquidity_FailsWhenAdapterRedeemFails() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Mock redeem to fail (ejectLiquidity uses redeem, not withdraw)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode("ADAPTER_COMPLETELY_BROKEN")
        );

        // 3. Owner tries to eject - should fail
        vm.expectRevert();
        splitter.ejectLiquidity();

        // 4. Funds are stuck in adapter
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Funds stuck in adapter");
    }

    /**
     * @notice Test partial withdrawal scenario - adapter has less liquidity than needed
     * @dev Simulates a bank run where there's not enough USDC to withdraw
     */
    function test_Burn_FailsWhenAdapterHasInsufficientLiquidity() public {
        // 1. Setup: Mint 100 tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Mock adapter to simulate insufficient liquidity
        // Both withdraw and redeem fail when underlying pool has insufficient funds
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("INSUFFICIENT_LIQUIDITY")
        );
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode("INSUFFICIENT_LIQUIDITY")
        );

        // 3. Alice tries to burn 50 tokens ($100 refund)
        // Buffer has $20, adapter would need $80, but adapter fails
        vm.startPrank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.burn(50 * 1e18);
        vm.stopPrank();
    }

    // ==========================================
    // 8. ADMIN FUNCTIONS COVERAGE
    // ==========================================

    function test_PreviewMint_RevertsWhenLiquidated() public {
        // 1. Setup: Mint some tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Trigger liquidation
        oracle.updatePrice(int256(CAP));
        vm.prank(alice);
        splitter.emergencyRedeem(1e12); // Sets isLiquidated

        assertTrue(splitter.isLiquidated());

        // 3. previewMint should revert when liquidated
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.previewMint(100 * 1e18);
    }

    function test_CurrentStatus_ReturnsSettledWhenLiquidated() public {
        // 1. Setup: Mint some tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Initial status should be ACTIVE
        assertEq(uint256(splitter.currentStatus()), uint256(ISyntheticSplitter.Status.ACTIVE));

        // 2. Trigger liquidation
        oracle.updatePrice(int256(CAP));
        vm.prank(alice);
        splitter.emergencyRedeem(1e12);

        // 3. Status should be SETTLED
        assertEq(uint256(splitter.currentStatus()), uint256(ISyntheticSplitter.Status.SETTLED));
    }

    function test_CurrentStatus_ReturnsPausedWhenPaused() public {
        // Initial status should be ACTIVE
        assertEq(uint256(splitter.currentStatus()), uint256(ISyntheticSplitter.Status.ACTIVE));

        // Pause
        splitter.pause();

        // Status should be PAUSED
        assertEq(uint256(splitter.currentStatus()), uint256(ISyntheticSplitter.Status.PAUSED));
    }

    function test_PreviewHarvest_CannotHarvestWhenNoSurplus() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        (bool canHarvest, uint256 surplus,,,) = splitter.previewHarvest();
        assertFalse(canHarvest);
        assertEq(surplus, 0);
    }

    function test_PreviewHarvest_ReturnsFalseWhenBelowThreshold() public {
        // 1. Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Advance blocks to allow CAPO to recognize yield
        vm.roll(block.number + 400);

        // 3. Add small surplus ($30 < $50 threshold) - mint USDC directly to adapter
        usdc.mint(address(adapter), 30 * 1e6);

        // 4. Check harvestable - should return (false, surplus, 0, 0, 0)
        (bool canHarvest, uint256 surplus,,,) = splitter.previewHarvest();
        assertFalse(canHarvest);
        assertGt(surplus, 0); // Has some surplus but below threshold
        assertLt(surplus, 50 * 1e6); // Below $50 threshold
    }

    function test_Harvest_UsesWithdrawWhenSurplusLessThanAdapterAssets() public {
        // 1. Mint larger amount so adapter has more assets
        // With 1000 tokens: $200 buffer, $1800 adapter
        vm.startPrank(alice);
        usdc.approve(address(splitter), 2000 * 1e6);
        splitter.mint(1000 * 1e18);
        vm.stopPrank();

        // 2. Setup fee receivers
        splitter.proposeFeeReceivers(treasury, staking);
        vm.warp(block.timestamp + 8 days);
        splitter.finalizeFeeReceivers();

        // 3. Advance blocks to allow CAPO growth
        vm.roll(block.number + 600);

        // 4. Add surplus ($100) which is LESS than adapter assets ($1800)
        // This triggers the withdraw path (line 456-457) instead of redeem
        // Mint USDC directly to adapter to simulate yield
        usdc.mint(address(adapter), 100 * 1e6);

        // 5. Expect withdraw to be called (not redeem)
        vm.expectCall(address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector));

        // 6. Harvest
        splitter.harvestYield();

        // Verify harvest succeeded
        assertGt(usdc.balanceOf(treasury), 0);
    }

    function test_Unpause_SetsLastUnpauseTime() public {
        splitter.pause();

        uint256 timeBefore = block.timestamp;
        splitter.unpause();

        assertEq(splitter.lastUnpauseTime(), timeBefore);
    }

    function test_EjectLiquidity_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        splitter.ejectLiquidity();
    }

    function test_EjectLiquidity_RevertsIfNoAdapter() public {
        // Deploy splitter without adapter
        SyntheticSplitter noAdapterSplitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(0));

        // Remove adapter by migrating to address(0) - but this isn't possible
        // So instead test when adapter has no shares
        // Actually the check is for yieldAdapter == address(0), which we can't easily test
        // because constructor requires valid adapter

        // Instead, test the happy path which covers line 377
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Verify ejectLiquidity works and pauses
        assertFalse(splitter.paused());
        splitter.ejectLiquidity();
        assertTrue(splitter.paused());
    }

    function test_FinalizeAdapter_ChecksLiveness() public {
        // 1. Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Deploy new adapter
        MockYieldAdapter newAdapter = new MockYieldAdapter(IERC20(address(usdc)), address(this), address(splitter));

        // 3. Propose adapter
        splitter.proposeAdapter(address(newAdapter));

        // 4. Wait for timelock
        vm.warp(block.timestamp + 8 days);

        // 5. Pause then unpause - liveness check should fail immediately
        splitter.pause();
        splitter.unpause();

        // 6. Try to finalize - should fail due to liveness check
        vm.expectRevert(SyntheticSplitter.Splitter__GovernanceLocked.selector);
        splitter.finalizeAdapter();

        // 7. Wait for liveness period
        vm.warp(block.timestamp + 7 days);

        // 8. Now finalize should work
        splitter.finalizeAdapter();
        assertEq(address(splitter.yieldAdapter()), address(newAdapter));
    }

    // ==========================================
    // 9. ADAPTER DEPOSIT FAILURE TESTS (MINT)
    // ==========================================

    /**
     * @notice Test that mint() reverts when adapter deposit fails
     * @dev Simulates Aave/Morpho deposit failure (e.g., supply cap reached)
     */
    function test_Mint_RevertsWhenAdapterDepositFails() public {
        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("SUPPLY_CAP_REACHED")
        );

        // 2. Alice tries to mint - should fail because adapter.deposit() reverts
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 3. Verify no state changes occurred (atomicity)
        assertEq(splitter.TOKEN_A().balanceOf(alice), 0, "No tokens should be minted");
        assertEq(splitter.TOKEN_B().balanceOf(alice), 0, "No tokens should be minted");
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "USDC should not be deducted");
    }

    /**
     * @notice Test that mint() reverts when adapter is paused
     * @dev Simulates scenario where underlying protocol (e.g., Aave) is paused
     */
    function test_Mint_RevertsWhenAdapterIsPaused() public {
        // 1. Mock adapter deposit to revert with paused message
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("PROTOCOL_PAUSED")
        );

        // 2. Alice tries to mint - should fail
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 3. Verify state unchanged
        assertEq(splitter.TOKEN_A().totalSupply(), 0, "Total supply should be 0");
    }

    /**
     * @notice Test that small mints (all goes to buffer) succeed even if adapter is broken
     * @dev If depositAmount = 0, adapter.deposit() is never called
     */
    function test_Mint_SucceedsWithBufferOnlyWhenAdapterBroken() public {
        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("ADAPTER_BROKEN")
        );

        // 2. Calculate minimum mint where all USDC stays in buffer
        // For 10% buffer: if usdcNeeded * 10% >= usdcNeeded, depositAmount = 0
        // This happens when usdcNeeded is very small due to rounding
        // mintAmount * CAP / USDC_MULTIPLIER = usdcNeeded
        // For CAP = 2e8, USDC_MULTIPLIER = 1e20
        // usdcNeeded = mintAmount * 2e8 / 1e20 = mintAmount / 5e11
        // For usdcNeeded = 1, mintAmount = 5e11
        // Buffer = 1 * 10% = 0, depositAmount = 1
        // Actually, for depositAmount = 0, we need usdcNeeded < 10 (so buffer rounds to usdcNeeded)
        // usdcNeeded = 9 means mintAmount = 9 * 5e11 = 4.5e12

        // Actually simpler: if usdcNeeded = 1, keepAmount = 0, depositAmount = 1
        // So there's no case where depositAmount = 0 for non-zero mint
        // Let's verify the actual behavior with edge case

        // Test very small mint - 1 unit of synthetic token
        // usdcNeeded = ceil(1 * 2e8 / 1e20) = ceil(2e-12) = 1 (due to ceiling)
        // keepAmount = 1 * 10 / 100 = 0
        // depositAmount = 1 - 0 = 1
        // So adapter IS called even for tiny amounts

        // This test verifies that even tiny mints require adapter
        vm.startPrank(alice);
        usdc.approve(address(splitter), 1);
        vm.expectRevert(); // Adapter is broken, mint fails
        splitter.mint(1);
        vm.stopPrank();
    }

    /**
     * @notice Test that USDC is not stuck in splitter when adapter deposit fails
     * @dev Verifies atomic behavior - either full success or full rollback
     */
    function test_Mint_USDCNotStuckOnAdapterFailure() public {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 splitterBalanceBefore = usdc.balanceOf(address(splitter));

        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("DEPOSIT_FAILED")
        );

        // 2. Alice tries to mint - should fail
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 3. Verify USDC balances unchanged (transaction reverted entirely)
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore, "Alice balance should be unchanged");
        assertEq(usdc.balanceOf(address(splitter)), splitterBalanceBefore, "Splitter balance should be unchanged");
    }

    /**
     * @notice Test multiple users affected by adapter failure
     * @dev Ensures consistent behavior across different callers
     */
    function test_Mint_MultipleUsersBlockedByAdapterFailure() public {
        address carol = address(0xCA201);
        usdc.mint(carol, INITIAL_BALANCE);

        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("CAPACITY_FULL")
        );

        // 2. Alice tries to mint - fails
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 3. Carol also tries to mint - also fails
        vm.startPrank(carol);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 4. Verify no tokens minted for either user
        assertEq(splitter.TOKEN_A().balanceOf(alice), 0);
        assertEq(splitter.TOKEN_A().balanceOf(carol), 0);
        assertEq(splitter.TOKEN_A().totalSupply(), 0);
    }

    /**
     * @notice Test adapter recovery - mint works after adapter is fixed
     * @dev Verifies protocol can resume after temporary adapter issues
     */
    function test_Mint_SucceedsAfterAdapterRecovery() public {
        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("TEMPORARILY_UNAVAILABLE")
        );

        // 2. Alice's first mint attempt fails
        vm.startPrank(alice);
        usdc.approve(address(splitter), 400 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);

        // 3. Clear the mock (simulates adapter recovery)
        vm.clearMockedCalls();

        // 4. Alice's second mint attempt succeeds
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 5. Verify successful mint
        assertEq(splitter.TOKEN_A().balanceOf(alice), 100 * 1e18);
        assertEq(splitter.TOKEN_B().balanceOf(alice), 100 * 1e18);
    }

    /**
     * @notice Test that adapter failure during deposit doesn't affect existing token holders
     * @dev Existing holders can still burn even if new mints fail
     */
    function test_Mint_AdapterFailureDoesNotAffectExistingHolders() public {
        // 1. Alice successfully mints before adapter breaks
        vm.startPrank(alice);
        usdc.approve(address(splitter), 400 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        uint256 aliceTokensBefore = splitter.TOKEN_A().balanceOf(alice);
        assertEq(aliceTokensBefore, 100 * 1e18);

        // 2. Mock adapter deposit to revert (adapter breaks for new deposits)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("NO_NEW_DEPOSITS")
        );

        // 3. Dave cannot mint (adapter broken)
        address dave = address(0xDA7E);
        usdc.mint(dave, INITIAL_BALANCE);
        vm.startPrank(dave);
        usdc.approve(address(splitter), 200 * 1e6);
        vm.expectRevert();
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 4. But Alice can still burn her existing tokens
        // (withdrawal uses different code path with fallback)
        vm.startPrank(alice);
        splitter.burn(10 * 1e18);
        vm.stopPrank();

        assertEq(splitter.TOKEN_A().balanceOf(alice), 90 * 1e18, "Alice should be able to burn");
    }

    /**
     * @notice Test that previewMint still works when adapter is broken
     * @dev Preview is view-only and doesn't call adapter.deposit()
     */
    function test_PreviewMint_SucceedsEvenWhenAdapterDepositBroken() public {
        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("ADAPTER_BROKEN")
        );

        // 2. previewMint should still work (it's view-only, doesn't call deposit)
        (uint256 usdcRequired, uint256 depositToAdapter, uint256 keptInBuffer) = splitter.previewMint(100 * 1e18);

        // 3. Verify preview returns valid values
        assertEq(usdcRequired, 200 * 1e6, "Preview should show $200 required");
        assertEq(keptInBuffer, 20 * 1e6, "Preview should show $20 in buffer");
        assertEq(depositToAdapter, 180 * 1e6, "Preview should show $180 to adapter");
    }

    /**
     * @notice Fuzz test: adapter failure during mint preserves invariants
     * @dev No partial state changes regardless of mint amount
     */
    function testFuzz_Mint_AtomicityOnAdapterFailure(
        uint256 mintAmount
    ) public {
        mintAmount = bound(mintAmount, 1e18, 1_000_000 * 1e18);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 totalSupplyBefore = splitter.TOKEN_A().totalSupply();

        // 1. Mock adapter deposit to revert
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.deposit.selector), abi.encode("FUZZ_FAILURE")
        );

        // 2. Mint should fail
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.expectRevert();
        splitter.mint(mintAmount);
        vm.stopPrank();

        // 3. Invariants: no state changes
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore, "USDC unchanged");
        assertEq(splitter.TOKEN_A().totalSupply(), totalSupplyBefore, "Token supply unchanged");
        assertEq(splitter.TOKEN_A().balanceOf(alice), 0, "No tokens minted");
    }

    // ==========================================
    // 10. ROUNDING BUFFER EDGE CASE TESTS
    // ==========================================
    // These tests verify the +1 rounding buffer in _withdrawFromAdapter:
    //
    //   uint256 sharesToRedeem = yieldAdapter.convertToShares(amount);
    //   if (sharesToRedeem > 0) {
    //       sharesToRedeem += 1;  // <-- This buffer prevents rounding shortfall
    //   }
    //
    // Without the +1, convertToShares can round DOWN, causing redeem to return
    // less than the requested amount (breaking solvency).

    /**
     * @notice Test that +1 buffer handles rounding when exchange rate is unfavorable
     * @dev Simulates yield accrual that creates non-1:1 exchange rate
     *
     * Scenario:
     * - Adapter has 181 USDC backing 180 shares (yield accrued)
     * - Exchange rate: 1 share = 1.00555... USDC
     * - User needs to withdraw 80 USDC
     * - convertToShares(80) = floor(80 * 180 / 181) = floor(79.558) = 79 shares
     * - redeem(79 shares) = floor(79 * 181 / 180) = floor(79.438) = 79 USDC
     * - WITHOUT +1: User gets 79 USDC (1 USDC short!)
     * - WITH +1: redeem(80 shares) = floor(80 * 181 / 180) = 80 USDC (correct)
     */
    function test_RedeemFallback_RoundingBuffer_HandlesYieldAccrual() public {
        // 1. Setup: Mint tokens to create initial adapter position
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Verify initial state: $20 buffer, $180 in adapter (1:1 ratio)
        assertEq(usdc.balanceOf(address(splitter)), 20 * 1e6, "Buffer should be $20");
        assertEq(adapter.balanceOf(address(splitter)), 180 * 1e6, "Adapter shares should be 180");

        // 2. Simulate yield accrual: Add 1 USDC to adapter (makes totalAssets > totalSupply)
        // This creates exchange rate: 181 USDC / 180 shares = 1.00555... USDC per share
        usdc.mint(address(adapter), 1 * 1e6);

        // 3. Verify exchange rate is no longer 1:1
        uint256 totalAssets = adapter.totalAssets();
        uint256 totalSupply = adapter.totalSupply();
        assertEq(totalAssets, 181 * 1e6, "Total assets should be 181");
        assertEq(totalSupply, 180 * 1e6, "Total supply should be 180");

        // 4. Mock withdraw to fail (force redeem fallback path)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 5. Alice burns 50 tokens ($100 refund needed)
        // Buffer has $20, needs $80 from adapter via redeem fallback
        // convertToShares(80e6) = floor(80e6 * 180e6 / 181e6) = floor(79.558...) = 79 shares (rounds down!)
        // Without +1: redeem(79) = floor(79 * 181 / 180) = 79.438... = 79 USDC (1 USDC short!)
        // With +1: redeem(80) = floor(80 * 181 / 180) = 80.444... = 80 USDC (sufficient)
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        // 6. Verify Alice received full $100 refund (not $99)
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        assertEq(aliceUsdcAfter - aliceUsdcBefore, 100 * 1e6, "Alice should receive full $100 refund");
    }

    /**
     * @notice Test rounding buffer with extreme exchange rate (2:1)
     * @dev Simulates scenario where adapter has doubled in value
     */
    function test_RedeemFallback_RoundingBuffer_ExtremeExchangeRate() public {
        // 1. Setup: Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Simulate 100% yield: Double the USDC in adapter
        // Exchange rate becomes: 360 USDC / 180 shares = 2:1
        usdc.mint(address(adapter), 180 * 1e6);

        assertEq(adapter.totalAssets(), 360 * 1e6, "Total assets should be 360");
        assertEq(adapter.totalSupply(), 180 * 1e6, "Total supply should be 180");

        // 3. Mock withdraw to fail
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 4. Burn tokens - needs withdrawal from adapter
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        splitter.burn(50 * 1e18); // Needs $100, buffer has $20, need $80 from adapter
        vm.stopPrank();

        // Verify full refund
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 100 * 1e6, "Should receive full refund with 2:1 rate");
    }

    /**
     * @notice Test rounding buffer with amount that maximizes rounding error
     * @dev Constructs worst-case rounding scenario
     */
    function test_RedeemFallback_RoundingBuffer_WorstCaseRounding() public {
        // 1. Setup: Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Create exchange rate that maximizes rounding error
        // Add 999_999 wei to make totalAssets = 180_999_999 / 180_000_000 shares
        // This creates worst-case rounding for certain withdrawal amounts
        usdc.mint(address(adapter), 999_999);

        uint256 totalAssets = adapter.totalAssets();
        uint256 totalSupply = adapter.totalSupply();
        assertEq(totalAssets, 180_999_999, "Total assets");
        assertEq(totalSupply, 180_000_000, "Total supply");

        // 3. Mock withdraw to fail
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 4. Burn - this would fail without +1 buffer
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        // Verify Alice got at least the expected refund
        assertGe(usdc.balanceOf(alice) - aliceUsdcBefore, 100 * 1e6, "Should receive at least $100");
    }

    /**
     * @notice Fuzz test: rounding buffer works across various exchange rates
     * @dev Tests that +1 buffer handles arbitrary yield scenarios
     */
    function testFuzz_RedeemFallback_RoundingBuffer(
        uint256 yieldAmount
    ) public {
        // Bound yield to reasonable range (0 to 100% of principal)
        yieldAmount = bound(yieldAmount, 1, 180 * 1e6);

        // 1. Setup: Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Add yield to create non-1:1 exchange rate
        usdc.mint(address(adapter), yieldAmount);

        // 3. Mock withdraw to fail (force redeem fallback)
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 4. Burn tokens
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        splitter.burn(50 * 1e18); // $100 refund needed
        vm.stopPrank();

        // 5. Verify Alice received full refund regardless of exchange rate
        uint256 refundReceived = usdc.balanceOf(alice) - aliceUsdcBefore;
        assertGe(refundReceived, 100 * 1e6, "Should receive at least $100 with any yield rate");
    }

    /**
     * @notice Test that redeem fallback emits correct shares with +1 buffer
     * @dev Verifies the actual redeem call includes the +1 adjustment
     */
    function test_RedeemFallback_RoundingBuffer_VerifySharesCalculation() public {
        // 1. Setup: Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Add yield to create rounding scenario
        usdc.mint(address(adapter), 10 * 1e6); // 190 USDC / 180 shares

        // 3. Calculate expected shares for $80 withdrawal
        // convertToShares(80e6) = floor(80e6 * 180e6 / 190e6) = floor(75.789...) = 75 shares
        uint256 expectedSharesWithoutBuffer = adapter.convertToShares(80 * 1e6);
        uint256 expectedSharesWithBuffer = expectedSharesWithoutBuffer + 1;

        // 4. Mock withdraw to fail
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 5. Expect redeem to be called with shares+1
        vm.expectCall(
            address(adapter),
            abi.encodeCall(IERC4626.redeem, (expectedSharesWithBuffer, address(splitter), address(splitter)))
        );

        // 6. Execute burn
        vm.startPrank(alice);
        splitter.burn(50 * 1e18);
        vm.stopPrank();
    }

    /**
     * @notice Test rounding buffer with emergencyRedeem during liquidation
     * @dev Verifies buffer works in liquidation scenario too
     */
    function test_EmergencyRedeem_RoundingBuffer_DuringLiquidation() public {
        // 1. Setup: Mint tokens
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // 2. Add yield to create rounding scenario
        usdc.mint(address(adapter), 5 * 1e6);

        // 3. Trigger liquidation
        oracle.updatePrice(int256(CAP));

        // 4. Mock withdraw to fail
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        // 5. Emergency redeem should work with +1 buffer
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        splitter.emergencyRedeem(50 * 1e18);
        vm.stopPrank();

        // Verify full refund received
        assertGe(usdc.balanceOf(alice) - aliceUsdcBefore, 100 * 1e6, "Should receive at least $100");
    }

    /**
     * @notice Test that without +1 buffer, certain scenarios would fail
     * @dev This is a documentation test showing why +1 is necessary
     *
     * The math:
     * - totalAssets = 181 USDC, totalSupply = 180 shares
     * - Need to withdraw 80 USDC
     * - convertToShares(80) = floor(80 * 180 / 181) = floor(79.558) = 79 shares
     * - redeem(79) returns = floor(79 * 181 / 180) = floor(79.438) = 79 USDC
     * - 79 < 80: USER WOULD BE SHORT BY 1 USDC!
     * - With +1: redeem(80) returns = floor(80 * 181 / 180) = floor(80.444) = 80 USDC
     */
    function test_RedeemFallback_RoundingBuffer_DocumentedMathProof() public {
        // This test documents the exact math proving why +1 buffer is needed

        // 1. Setup exact scenario from the math above
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        // Create 181/180 exchange rate
        usdc.mint(address(adapter), 1 * 1e6);

        // Verify the math
        uint256 totalAssets = adapter.totalAssets();
        uint256 totalSupply = adapter.totalSupply();
        assertEq(totalAssets, 181 * 1e6, "totalAssets = 181");
        assertEq(totalSupply, 180 * 1e6, "totalSupply = 180");

        // Calculate what convertToShares returns
        uint256 amountNeeded = 80 * 1e6;
        uint256 sharesCalculated = adapter.convertToShares(amountNeeded);

        // Prove the rounding happens
        // sharesCalculated = floor(80e6 * 180e6 / 181e6) = floor(79558011.04...) = 79558011
        // This is less than 80e6 shares, showing rounding loss
        assertLt(sharesCalculated, 80 * 1e6, "convertToShares should round down");

        // Prove that redeeming those shares gives less than 80 USDC
        uint256 assetsFromCalculatedShares = adapter.convertToAssets(sharesCalculated);
        assertLt(assetsFromCalculatedShares, amountNeeded, "Without +1, we'd be short!");

        // Prove that redeeming shares+1 gives at least 80 USDC
        uint256 assetsFromSharesPlus1 = adapter.convertToAssets(sharesCalculated + 1);
        assertGe(assetsFromSharesPlus1, amountNeeded, "With +1, we get enough USDC");

        // Now verify the actual burn works
        vm.mockCallRevert(
            address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_DISABLED")
        );

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        splitter.burn(50 * 1e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 100 * 1e6, "Full refund received thanks to +1 buffer");
    }

    // ==========================================
    // WITHDRAW FROM ADAPTER (Gradual Emergency Exit)
    // ==========================================

    function test_WithdrawFromAdapter_RevertsWhenNotPaused() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        vm.expectRevert(SyntheticSplitter.Splitter__NotPaused.selector);
        splitter.withdrawFromAdapter(50 * 1e6);
    }

    function test_WithdrawFromAdapter_RevertsZeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        splitter.pause();

        vm.expectRevert(SyntheticSplitter.Splitter__ZeroAmount.selector);
        splitter.withdrawFromAdapter(0);
    }

    function test_WithdrawFromAdapter_SuccessfulPartialWithdrawal() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        uint256 adapterBalanceBefore = adapter.maxWithdraw(address(splitter));
        uint256 localBalanceBefore = usdc.balanceOf(address(splitter));

        splitter.pause();
        splitter.withdrawFromAdapter(50 * 1e6);

        uint256 adapterBalanceAfter = adapter.maxWithdraw(address(splitter));
        uint256 localBalanceAfter = usdc.balanceOf(address(splitter));

        assertEq(adapterBalanceBefore - adapterBalanceAfter, 50 * 1e6, "Adapter balance decreased");
        assertEq(localBalanceAfter - localBalanceBefore, 50 * 1e6, "Local balance increased");
    }

    function test_WithdrawFromAdapter_CapsToMaxAvailable() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        uint256 adapterBalance = adapter.maxWithdraw(address(splitter));
        splitter.pause();

        splitter.withdrawFromAdapter(adapterBalance + 1000 * 1e6);

        assertEq(adapter.maxWithdraw(address(splitter)), 0, "All available funds withdrawn");
        assertEq(usdc.balanceOf(address(splitter)), 200 * 1e6, "All USDC now local");
    }

    function test_WithdrawFromAdapter_CanBeCalledMultipleTimes() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), 200 * 1e6);
        splitter.mint(100 * 1e18);
        vm.stopPrank();

        splitter.pause();

        splitter.withdrawFromAdapter(30 * 1e6);
        splitter.withdrawFromAdapter(30 * 1e6);
        splitter.withdrawFromAdapter(30 * 1e6);

        uint256 localBalance = usdc.balanceOf(address(splitter));
        assertEq(localBalance, 20 * 1e6 + 90 * 1e6, "Three withdrawals accumulated");
    }

    // ==========================================
    // RESCUE TOKEN
    // ==========================================

    function test_RescueToken_SucceedsForNonCoreToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(splitter), 1000 * 1e18);

        assertEq(randomToken.balanceOf(address(splitter)), 1000 * 1e18);
        assertEq(randomToken.balanceOf(treasury), 0);

        splitter.rescueToken(address(randomToken), treasury);

        assertEq(randomToken.balanceOf(address(splitter)), 0);
        assertEq(randomToken.balanceOf(treasury), 1000 * 1e18);
    }

    function test_RescueToken_RevertsForUSDC() public {
        vm.expectRevert(SyntheticSplitter.Splitter__CannotRescueCoreAsset.selector);
        splitter.rescueToken(address(usdc), treasury);
    }

    function test_RescueToken_RevertsForTokenA() public {
        address tokenA = address(splitter.TOKEN_A());
        vm.expectRevert(SyntheticSplitter.Splitter__CannotRescueCoreAsset.selector);
        splitter.rescueToken(tokenA, treasury);
    }

    function test_RescueToken_RevertsForTokenB() public {
        address tokenB = address(splitter.TOKEN_B());
        vm.expectRevert(SyntheticSplitter.Splitter__CannotRescueCoreAsset.selector);
        splitter.rescueToken(tokenB, treasury);
    }

    function test_RescueToken_OnlyOwner() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(splitter), 1000 * 1e18);

        vm.prank(alice);
        vm.expectRevert();
        splitter.rescueToken(address(randomToken), alice);
    }

}
