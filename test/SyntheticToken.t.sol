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
        assertEq(token.SPLITTER(), splitter);
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

    // ==========================================
    // 5. Permit Tests (EIP-2612)
    // ==========================================

    function test_Permit_Success() public {
        // Create a user with a known private key
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        address spender = address(0x789);
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Mint tokens to owner
        vm.prank(splitter);
        token.mint(owner, value);

        // Build permit signature
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        token.nonces(owner),
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        // Execute permit
        token.permit(owner, spender, value, deadline, v, r, s);

        // Verify allowance was set
        assertEq(token.allowance(owner, spender), value);
        // Verify nonce was incremented
        assertEq(token.nonces(owner), 1);
    }

    function test_Permit_RevertsExpiredDeadline() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        address spender = address(0x789);
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp - 1; // Expired

        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        token.nonces(owner),
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_Permit_RevertsInvalidSignature() public {
        uint256 ownerPrivateKey = 0xA11CE;
        uint256 wrongPrivateKey = 0xBAD;
        address owner = vm.addr(ownerPrivateKey);
        address spender = address(0x789);
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        token.nonces(owner),
                        deadline
                    )
                )
            )
        );

        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, permitHash);

        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_Permit_TransferFromAfterPermit() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        address spender = address(0x789);
        address recipient = address(0xABC);
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Mint tokens to owner
        vm.prank(splitter);
        token.mint(owner, value);

        // Build and sign permit
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        token.nonces(owner),
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        // Execute permit
        token.permit(owner, spender, value, deadline, v, r, s);

        // Spender transfers tokens using the permit allowance
        vm.prank(spender);
        token.transferFrom(owner, recipient, value);

        // Verify transfer
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(recipient), value);
    }

    function test_DOMAIN_SEPARATOR() public view {
        // Verify DOMAIN_SEPARATOR is set (non-zero)
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        assertTrue(domainSeparator != bytes32(0));
    }

    function test_Nonces_StartsAtZero() public view {
        assertEq(token.nonces(alice), 0);
        assertEq(token.nonces(hacker), 0);
    }
}
