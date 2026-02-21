// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {OptionToken} from "../../src/options/OptionToken.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "forge-std/Test.sol";

contract OptionTokenTest is Test {

    OptionToken public implementation;
    OptionToken public token;

    address engine = address(this);
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        implementation = new OptionToken();
        token = OptionToken(Clones.clone(address(implementation)));
        token.initialize("BEAR-100C-20260301", "oBEAR", engine);
    }

    function test_Initialize_SetsNameSymbolEngine() public view {
        assertEq(token.name(), "BEAR-100C-20260301");
        assertEq(token.symbol(), "oBEAR");
        assertEq(token.marginEngine(), engine);
        assertEq(token.decimals(), 18);
    }

    function test_Initialize_RevertsOnSecondCall() public {
        vm.expectRevert(OptionToken.OptionToken__AlreadyInitialized.selector);
        token.initialize("X", "Y", address(0xdead));
    }

    function test_Mint_IncreasesBalanceAndSupply() public {
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Mint_RevertsFromNonEngine() public {
        vm.prank(alice);
        vm.expectRevert(OptionToken.OptionToken__Unauthorized.selector);
        token.mint(alice, 100e18);
    }

    function test_Burn_DecreasesBalanceAndSupply() public {
        token.mint(alice, 100e18);
        token.burn(alice, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function test_Burn_RevertsOnInsufficientBalance() public {
        token.mint(alice, 10e18);
        vm.expectRevert(OptionToken.OptionToken__InsufficientBalance.selector);
        token.burn(alice, 11e18);
    }

    function test_Burn_RevertsFromNonEngine() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(OptionToken.OptionToken__Unauthorized.selector);
        token.burn(alice, 50e18);
    }

    function test_Transfer_MovesTokens() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(bob, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(bob), 30e18);
    }

    function test_Transfer_RevertsOnInsufficientBalance() public {
        token.mint(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(OptionToken.OptionToken__InsufficientBalance.selector);
        token.transfer(bob, 11e18);
    }

    function test_Transfer_RevertsToAddressZero() public {
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(OptionToken.OptionToken__ZeroAddress.selector);
        token.transfer(address(0), 50e18);
    }

    function test_TransferFrom_RevertsToAddressZero() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert(OptionToken.OptionToken__ZeroAddress.selector);
        token.transferFrom(alice, address(0), 50e18);
    }

    function test_TransferFrom_WithApproval() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 50e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(bob), 30e18);
    }

    function test_TransferFrom_DecreasesAllowance() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 50e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 20e18);
        assertEq(token.allowance(alice, bob), 30e18);
    }

    function test_TransferFrom_RevertsWithoutApproval() public {
        token.mint(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(OptionToken.OptionToken__InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_TransferFrom_InfiniteApprovalNotDecremented() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 50e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_Approve_SetsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 42e18);
        assertEq(token.allowance(alice, bob), 42e18);
    }

    // ==========================================
    // L-1: IMPLEMENTATION CANNOT BE INITIALIZED
    // ==========================================

    function test_Implementation_CannotBeInitialized() public {
        vm.expectRevert(OptionToken.OptionToken__AlreadyInitialized.selector);
        implementation.initialize("X", "Y", address(0xdead));
    }

    // ==========================================
    // L-3: MINT ZERO ADDRESS CHECK
    // ==========================================

    function test_Mint_RevertsToAddressZero() public {
        vm.expectRevert(OptionToken.OptionToken__ZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    // ==========================================
    // L-04: INITIALIZE REJECTS ZERO-ADDRESS ENGINE
    // ==========================================

    function test_Initialize_RevertsOnZeroAddressEngine() public {
        OptionToken proxy = OptionToken(Clones.clone(address(implementation)));
        vm.expectRevert(OptionToken.OptionToken__ZeroAddress.selector);
        proxy.initialize("X", "Y", address(0));
    }

}
