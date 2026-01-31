// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakedToken} from "../src/StakedToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

contract MockUnderlying is ERC20, ERC20Permit {

    constructor() ERC20("plDXY-BEAR", "BEAR") ERC20Permit("plDXY-BEAR") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract StakedTokenTest is Test {

    StakedToken public stakedToken;
    MockUnderlying public underlying;

    address alice = address(0xA11ce);
    address bob = address(0xB0b);
    address attacker = address(0xBAD);

    function setUp() public {
        underlying = new MockUnderlying();
        stakedToken = new StakedToken(IERC20(address(underlying)), "Staked plDXY-BEAR", "splDXY-BEAR");

        underlying.mint(alice, 1000 ether);
        underlying.mint(bob, 1000 ether);
        underlying.mint(attacker, 1000 ether);
    }

    // ==========================================
    // STREAMING REWARDS TESTS
    // ==========================================

    function test_DonateYield_IncreasesTotalAssets() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        assertEq(stakedToken.totalAssets(), 100 ether);

        underlying.mint(address(this), 10 ether);
        underlying.approve(address(stakedToken), 10 ether);
        stakedToken.donateYield(10 ether);

        // Immediately after donation, rewards are unvested
        assertApproxEqAbs(stakedToken.totalAssets(), 100 ether, 1);

        // After stream duration, all rewards are vested
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());
        assertEq(stakedToken.totalAssets(), 110 ether);
    }

    function test_DonateYield_IncreasesShareValue() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 shares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        underlying.mint(address(this), 10 ether);
        underlying.approve(address(stakedToken), 10 ether);
        stakedToken.donateYield(10 ether);

        // Warp to fully vest rewards
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());

        assertApproxEqAbs(stakedToken.convertToAssets(shares), 110 ether, 1);
    }

    function test_DonateYield_FairDistribution() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 aliceShares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 bobShares = stakedToken.deposit(100 ether, bob);
        vm.stopPrank();

        underlying.mint(address(this), 20 ether);
        underlying.approve(address(stakedToken), 20 ether);
        stakedToken.donateYield(20 ether);

        // Warp to fully vest rewards
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());

        assertApproxEqAbs(stakedToken.convertToAssets(aliceShares), 110 ether, 1);
        assertApproxEqAbs(stakedToken.convertToAssets(bobShares), 110 ether, 1);
    }

    function test_DonateYield_StreamsLinearly() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        underlying.mint(address(this), 100 ether);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.donateYield(100 ether);

        // At t=0, ~0% vested
        assertApproxEqAbs(stakedToken.totalAssets(), 100 ether, 1);

        // At t=25%, ~25% vested (tolerance: truncation dust ~1000 wei)
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 4);
        assertApproxEqAbs(stakedToken.totalAssets(), 125 ether, 1000);

        // At t=50%, ~50% vested
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 4);
        assertApproxEqAbs(stakedToken.totalAssets(), 150 ether, 1000);

        // At t=100%, 100% vested
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 2);
        assertEq(stakedToken.totalAssets(), 200 ether);
    }

    function test_DonateYield_MultipleStreamsAccumulate() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        // First donation
        underlying.mint(address(this), 200 ether);
        underlying.approve(address(stakedToken), 200 ether);
        stakedToken.donateYield(100 ether);

        // Warp to 50% of first stream
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 2);
        assertApproxEqAbs(stakedToken.totalAssets(), 150 ether, 1000);

        // Second donation - remaining 50 from first + 100 new = 150 over new period
        stakedToken.donateYield(100 ether);

        // Immediately after second donation
        assertApproxEqAbs(stakedToken.totalAssets(), 150 ether, 1000);

        // After full new stream duration
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());
        assertEq(stakedToken.totalAssets(), 300 ether);
    }

    function test_DonateYield_LateDepositorGetsProportionalRewards() public {
        // Alice deposits first
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        // Donate rewards
        underlying.mint(address(this), 100 ether);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.donateYield(100 ether);

        // Bob deposits halfway through stream
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 2);

        vm.startPrank(bob);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 bobShares = stakedToken.deposit(100 ether, bob);
        vm.stopPrank();

        // At this point: 150 ether vested, Bob deposits 100 more = 250 total
        // Bob gets shares based on current price (150 assets, 100k shares for Alice)
        // Bob gets ~66.67k shares for his 100 ether

        // Complete the stream
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION() / 2);

        // Alice had all shares during first half (50 ether vested to her alone)
        // Second half (50 ether) split proportionally: Alice ~60%, Bob ~40%
        // Alice: 100 + 50 + 30 = ~180, Bob: 100 + 20 = ~120
        uint256 aliceValue = stakedToken.convertToAssets(stakedToken.balanceOf(alice));
        uint256 bobValue = stakedToken.convertToAssets(bobShares);

        // Bob deposited halfway so gets less than half of rewards
        assertGt(aliceValue, bobValue);
        assertApproxEqAbs(aliceValue + bobValue, 300 ether, 10);
    }

    // ==========================================
    // STREAMING PROTECTS AGAINST FLASH SNIPING
    // ==========================================

    function test_FlashSnipingMitigated() public {
        // Alice is a long-term staker
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        // Attacker deposits right before donation
        vm.startPrank(attacker);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, attacker);
        vm.stopPrank();

        // Rewards donated
        underlying.mint(address(this), 100 ether);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.donateYield(100 ether);

        // Attacker withdraws immediately - gets almost no rewards (not vested yet)
        vm.startPrank(attacker);
        uint256 attackerShares = stakedToken.balanceOf(attacker);
        uint256 attackerValue = stakedToken.convertToAssets(attackerShares);
        stakedToken.redeem(attackerShares, attacker, attacker);
        vm.stopPrank();

        // Attacker only gets back ~100 ether (their deposit) + dust from the few seconds of vesting
        assertApproxEqAbs(attackerValue, 100 ether, 0.01 ether);

        // After stream completes, Alice gets almost all rewards
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());
        uint256 aliceValue = stakedToken.convertToAssets(stakedToken.balanceOf(alice));

        // Alice gets her 100 + almost all of the 100 reward (attacker left early)
        assertGt(aliceValue, 199 ether);
    }

    function test_ImmediateWithdraw_Works() public {
        // Deposit and withdraw immediately - should work (no delay)
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 shares = stakedToken.deposit(100 ether, alice);

        stakedToken.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(underlying.balanceOf(alice), 1000 ether);
        assertEq(stakedToken.balanceOf(alice), 0);
    }

    // ==========================================
    // INFLATION ATTACK PROTECTION
    // ==========================================

    function test_InflationAttack_Mitigated() public {
        vm.startPrank(attacker);
        underlying.approve(address(stakedToken), 1);
        stakedToken.deposit(1, attacker);

        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.donateYield(100 ether);
        vm.stopPrank();

        // Warp to vest rewards
        vm.warp(block.timestamp + stakedToken.STREAM_DURATION());

        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 aliceShares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        assertGt(aliceShares, 0);
        assertGt(stakedToken.convertToAssets(aliceShares), 99.9 ether);
    }

    // ==========================================
    // DEPOSIT WITH PERMIT
    // ==========================================

    function test_DepositWithPermit_Success() public {
        uint256 privateKey = 0x1234;
        address signer = vm.addr(privateKey);
        uint256 depositAmount = 100 ether;

        underlying.mint(signer, depositAmount);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = underlying.nonces(signer);

        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                underlying.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(stakedToken),
                        depositAmount,
                        nonce,
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, permitHash);

        vm.prank(signer);
        uint256 shares = stakedToken.depositWithPermit(depositAmount, signer, deadline, v, r, s);

        assertGt(shares, 0);
        assertEq(stakedToken.balanceOf(signer), shares);
        assertEq(underlying.balanceOf(signer), 0);
    }

    function test_DepositWithPermit_DifferentReceiver() public {
        uint256 privateKey = 0x5678;
        address signer = vm.addr(privateKey);
        address receiver = address(0xBEEF);
        uint256 depositAmount = 50 ether;

        underlying.mint(signer, depositAmount);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = underlying.nonces(signer);

        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                underlying.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(stakedToken),
                        depositAmount,
                        nonce,
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, permitHash);

        vm.prank(signer);
        uint256 shares = stakedToken.depositWithPermit(depositAmount, receiver, deadline, v, r, s);

        assertGt(shares, 0);
        assertEq(stakedToken.balanceOf(receiver), shares);
        assertEq(stakedToken.balanceOf(signer), 0);
    }

}
