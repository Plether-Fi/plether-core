// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/ZapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "../src/interfaces/ISyntheticSplitter.sol";

contract ZapRouterTest is Test {
    ZapRouter public zapRouter;
    
    // Mocks
    MockToken public usdc;
    MockFlashToken public mDXY;
    MockFlashToken public mInvDXY;
    MockSplitter public splitter;
    MockSwapRouter public swapRouter;

    address alice = address(0xA11ce);

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockToken("USDC", "USDC");
        mDXY = new MockFlashToken("mDXY", "mDXY");
        mInvDXY = new MockFlashToken("mInvDXY", "mInvDXY");
        splitter = new MockSplitter(address(mDXY), address(mInvDXY));
        swapRouter = new MockSwapRouter();

        // 2. Deploy ZapRouter
        zapRouter = new ZapRouter(
            address(splitter),
            address(mDXY),
            address(mInvDXY),
            address(usdc),
            address(swapRouter)
        );

        // 3. Setup Initial State
        usdc.mint(alice, 1000 * 1e6);
    }

    // ==========================================
    // 1. HAPPY PATHS
    // ==========================================

    function test_ZapMint_mDXY_Success() public {
        uint256 usdcInput = 100 * 1e6; // $100
        
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);
        
        // Expect ~200 units (100 from input + 100 from flash loan swap)
        zapRouter.zapMint(address(mDXY), usdcInput, 190 * 1e18);
        vm.stopPrank();

        assertGe(mDXY.balanceOf(alice), 190 * 1e18, "Alice didn't get enough mDXY");
        assertEq(usdc.balanceOf(alice), 900 * 1e6, "Alice spent wrong amount of USDC");
    }

    function test_ZapMint_mInvDXY_Success() public {
        uint256 usdcInput = 100 * 1e6;
        
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // Expect ~200 units of Bear token (mInvDXY)
        zapRouter.zapMint(address(mInvDXY), usdcInput, 190 * 1e18);
        vm.stopPrank();

        assertGe(mInvDXY.balanceOf(alice), 190 * 1e18, "Did not receive mInvDXY");
        assertEq(mDXY.balanceOf(alice), 0, "Should not hold mDXY");
    }

    // ==========================================
    // 2. LOGIC & MATH CHECKS
    // ==========================================

    function test_ZapMint_Slippage_Reverts() public {
        uint256 usdcInput = 100 * 1e6;
        
        // Configure Swap Router to give bad rates (50% slippage)
        swapRouter.setRate(5000); 

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);

        // The user receives less than `minAmountOut`
        vm.expectRevert("Slippage too high");
        zapRouter.zapMint(address(mDXY), usdcInput, 190 * 1e18);
        vm.stopPrank();
    }

    function test_ZapMint_Insolvency_Reverts() public {
        uint256 usdcInput = 100 * 1e6;

        // CRASH the swap rate to near zero (0.01%)
        // The router borrows 100 tokens but gets $0 back when selling them.
        // It cannot afford to pay back the flash loan.
        swapRouter.setRate(1);

        // Temporarily set a flash fee to simulate insolvency
        mInvDXY.setFeeBps(10002);

        vm.startPrank(alice);
        usdc.approve(address(zapRouter), usdcInput);
        vm.expectRevert("Insolvent Zap: Swap didn't cover mint cost");
        zapRouter.zapMint(address(mDXY), usdcInput, 0);
        vm.stopPrank();
    }

    // ==========================================
    // 3. SECURITY & INPUT VALIDATION
    // ==========================================

    function test_ZapMint_InvalidToken_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(zapRouter), 100 * 1e6);

        // Try to zap into a random token (USDC is not a valid target)
        vm.expectRevert("Invalid token");
        zapRouter.zapMint(address(usdc), 100 * 1e6, 0);
        
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);
        
        // Alice pretends to be a Flash Lender calling the callback
        vm.expectRevert("Untrusted lender");
        zapRouter.onFlashLoan(
            address(zapRouter),
            address(mDXY),
            100, 
            0, 
            ""
        );
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        // We pretend to be the legitimate token calling the callback...
        vm.startPrank(address(mInvDXY)); 
        
        // ...BUT the 'initiator' arg is Alice, not the ZapRouter itself.
        vm.expectRevert("Untrusted initiator");
        zapRouter.onFlashLoan(
            alice, // <--- Malicious initiator
            address(mInvDXY),
            100, 
            0, 
            ""
        );
        vm.stopPrank();
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockFlashToken is ERC20, IERC3156FlashLender {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    uint256 public feeBps = 0; // Configurable fee in basis points (default 0)

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function maxFlashLoan(address) external pure override returns (uint256) { return type(uint256).max; }

    function flashFee(address, uint256 amount) public view override returns (uint256) {
        return (amount * feeBps) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data) external override returns (bool) {
        uint256 fee = flashFee(token, amount);
        _mint(address(receiver), amount); // optimistic mint
        require(receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"), "Callback failed");
        _burn(address(receiver), amount + fee); // repay
        return true;
    }
}

contract MockSwapRouter is ISwapRouter {
    uint256 public rate = 10000; // 100.00%
    function setRate(uint256 _r) external { rate = _r; }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable override returns (uint256 amountOut) {
        amountOut = (params.amountIn / 1e12) * rate / 10000;
        MockToken(params.tokenOut).mint(params.recipient, amountOut);
        return amountOut;
    }
}

contract MockSplitter is ISyntheticSplitter {
    address public tA;
    address public tB;
    
    constructor(address _tA, address _tB) { tA = _tA; tB = _tB; }

    function mint(uint256 amount) external override {
        uint256 mintAmount = amount * 1e12; 
        MockFlashToken(tA).mint(msg.sender, mintAmount);
        MockFlashToken(tB).mint(msg.sender, mintAmount);
    }

    // Stubs for Missing Implementation Errors
    function currentStatus() external view override returns (Status) { return Status.ACTIVE; }
    function getSystemSolvency() external view override returns (uint256, uint256) { return (0,0); }
    function redeemPair(uint256) external override {}
    function redeemSettled(address, uint256) external override {}
    function setTreasury(address) external override {}
    function setVault(address) external override {}
    function settledPrice() external view override returns (uint256) { return 0; }
    function skimYield() external override {}
}
