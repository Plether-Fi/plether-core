// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/SyntheticToken.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

// Mock Borrower for Flash Mint Testing
contract MockFlashBorrower is IERC3156FlashBorrower {
    // Action to take: "APPROVE" means we play nice and approve payback
    // "STEAL" means we try to keep the money (and should fail)
    string action;

    function setAction(string memory _action) external {
        action = _action;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        // Verify we actually received the tokens
        require(SyntheticToken(token).balanceOf(address(this)) >= amount, "Did not receive tokens");

        if (keccak256(bytes(action)) == keccak256(bytes("APPROVE"))) {
            // Approve the token to take back the loan + fee
            SyntheticToken(token).approve(msg.sender, amount + fee);
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        } else {
            // Do nothing (STEAL), causing the flash loan to revert
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        }
    }
}

contract SyntheticTokenTest is Test {
    SyntheticToken public token;
    MockFlashBorrower public borrower;

    address public splitter = address(0x123);
    address public alice = address(0x1);
    address public hacker = address(0x999);

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new SyntheticToken("Mock DXY", "mDXY", splitter);
        borrower = new MockFlashBorrower();
    }

    // ==========================================
    // 1. Initialization Tests
    // ==========================================
    function test_InitialState() public {
        assertEq(token.name(), "Mock DXY");
        assertEq(token.symbol(), "mDXY");
        assertEq(token.splitter(), splitter);
    }

    // ==========================================
    // 2. Minting Tests
    // ==========================================
    function test_Mint_Success() public {
        vm.prank(splitter);
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_RevertMint_Unauthorized() public {
        vm.prank(hacker);
        vm.expectRevert(SyntheticToken.SyntheticToken__Unauthorized.selector);
        token.mint(alice, 100 ether);
    }

    // ==========================================
    // 3. Burning Tests
    // ==========================================
    function test_Burn_Success() public {
        vm.prank(splitter);
        token.mint(alice, 100 ether);

        vm.prank(splitter);
        token.burn(alice, 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
    }

    function test_RevertBurn_Unauthorized() public {
        vm.prank(splitter);
        token.mint(alice, 100 ether);

        vm.prank(hacker);
        vm.expectRevert(SyntheticToken.SyntheticToken__Unauthorized.selector);
        token.burn(alice, 100 ether);
    }

    // ==========================================
    // 4. Flash Mint Tests (NEW)
    // ==========================================

    function test_FlashMint_Success() public {
        // We want to flash mint 1,000,000 tokens (even though supply is 0)
        uint256 loanAmount = 1_000_000 ether;

        // Configure borrower to behave correctly
        borrower.setAction("APPROVE");

        // Execute Flash Loan
        // The token contract will Mint -> Call Borrower -> Burn
        bool success = token.flashLoan(IERC3156FlashBorrower(address(borrower)), address(token), loanAmount, "");

        assertTrue(success);
        // Supply should be back to 0 (Minted then Burned)
        assertEq(token.totalSupply(), 0);
    }

    function test_FlashMint_Revert_IfUserDoesNotApprove() public {
        uint256 loanAmount = 100 ether;

        // Borrower tries to steal the tokens (does not approve repayment)
        borrower.setAction("STEAL");

        // Should fail because ERC20FlashMint cannot burn the tokens back
        vm.expectRevert();
        token.flashLoan(IERC3156FlashBorrower(address(borrower)), address(token), loanAmount, "");
    }

    function test_FlashFee_IsZero() public {
        uint256 fee = token.flashFee(address(token), 1000 ether);
        assertEq(fee, 0);
    }
}
