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
    // DONATE YIELD TESTS
    // ==========================================

    function test_DonateYield_IncreasesTotalAssets() public {
        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        assertEq(stakedToken.totalAssets(), 100 ether);

        // Donate yield
        underlying.mint(address(this), 10 ether);
        underlying.approve(address(stakedToken), 10 ether);
        stakedToken.donateYield(10 ether);

        assertEq(stakedToken.totalAssets(), 110 ether);
    }

    function test_DonateYield_IncreasesShareValue() public {
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 shares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        // Donate 10% yield
        underlying.mint(address(this), 10 ether);
        underlying.approve(address(stakedToken), 10 ether);
        stakedToken.donateYield(10 ether);

        // Alice's shares now worth ~110 ether
        assertApproxEqAbs(stakedToken.convertToAssets(shares), 110 ether, 1);
    }

    function test_DonateYield_FairDistribution() public {
        // Alice and Bob deposit equal amounts
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 aliceShares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 bobShares = stakedToken.deposit(100 ether, bob);
        vm.stopPrank();

        // Donate yield
        underlying.mint(address(this), 20 ether);
        underlying.approve(address(stakedToken), 20 ether);
        stakedToken.donateYield(20 ether);

        // Both get equal share of yield
        assertApproxEqAbs(stakedToken.convertToAssets(aliceShares), 110 ether, 1);
        assertApproxEqAbs(stakedToken.convertToAssets(bobShares), 110 ether, 1);
    }

    // ==========================================
    // INFLATION ATTACK PROTECTION
    // ==========================================

    function test_InflationAttack_Mitigated() public {
        // Step 1: Attacker deposits 1 wei
        vm.startPrank(attacker);
        underlying.approve(address(stakedToken), 1);
        stakedToken.deposit(1, attacker);

        // Step 2: Attacker donates to inflate share price
        underlying.approve(address(stakedToken), 100 ether);
        stakedToken.donateYield(100 ether);
        vm.stopPrank();

        // Step 3: Victim deposits
        vm.startPrank(alice);
        underlying.approve(address(stakedToken), 100 ether);
        uint256 aliceShares = stakedToken.deposit(100 ether, alice);
        vm.stopPrank();

        // With offset=3, Alice gets meaningful shares and loses < 0.1%
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
