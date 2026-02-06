// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Test} from "forge-std/Test.sol";

contract SyntheticTokenTest is Test {

    SyntheticToken public token;

    address public splitter = address(0x123);
    address public alice = address(0x1);
    address public hacker = address(0x999);

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new SyntheticToken("Mock plDXY", "mplDXY", splitter);
    }

    // ==========================================
    // 1. Initialization Tests
    // ==========================================
    function test_InitialState() public {
        assertEq(token.name(), "Mock plDXY");
        assertEq(token.symbol(), "mplDXY");
        assertEq(token.SPLITTER(), splitter);
    }

    // ==========================================
    // 2. Minting Tests
    // ==========================================
    function test_RevertMint_Unauthorized() public {
        vm.prank(hacker);
        vm.expectRevert(SyntheticToken.SyntheticToken__Unauthorized.selector);
        token.mint(alice, 100 ether);
    }

    // ==========================================
    // 3. Burning Tests
    // ==========================================
    function test_RevertBurn_Unauthorized() public {
        vm.prank(splitter);
        token.mint(alice, 100 ether);

        vm.prank(hacker);
        vm.expectRevert(SyntheticToken.SyntheticToken__Unauthorized.selector);
        token.burn(alice, 100 ether);
    }

}
