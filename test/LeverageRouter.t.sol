// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30; // Added Pragma

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public leverageRouter;

    // Mocks
    MockToken public usdc;
    MockToken public mDXY;
    MockMorpho public morpho;
    MockSwapRouter public swapRouter;
    MockFlashLender public lender;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        mDXY = new MockToken("mDXY", "mDXY", 18);
        morpho = new MockMorpho();
        swapRouter = new MockSwapRouter();
        lender = new MockFlashLender(address(usdc));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(mDXY),
            oracle: address(0),
            irm: address(0),
            lltv: 900000000000000000 // 90%
        });

        leverageRouter = new LeverageRouter(
            address(morpho), address(swapRouter), address(usdc), address(mDXY), address(lender), params
        );

        // Setup Alice
        usdc.mint(alice, 10_000 * 1e6); // $10k
    }

    function test_OpenLeverage_3x_Success() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 100; // 1% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);

        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 3000 * 1e18, "Incorrect supplied amount");
        assertEq(borrowed, 2000 * 1e6, "Incorrect borrowed amount");
    }

    function test_OpenLeverage_EmitsLeverageOpenedEvent() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 50; // 0.5% slippage
        uint256 expectedLoanAmount = 2000 * 1e6; // principal * (leverage - 1) / 1e18
        uint256 expectedMDXYReceived = 3000 * 1e18; // (principal + loan) * 1e12
        uint256 expectedDebtIncurred = 2000 * 1e6; // loan + fee (fee is 0 in mock)

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectEmit(true, false, false, true);
        emit LeverageRouter.LeverageOpened(
            alice, principal, leverage, expectedLoanAmount, expectedMDXYReceived, expectedDebtIncurred, maxSlippageBps
        );

        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_NoAuth() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        // Skip auth - router checks upfront before flash loan

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_AuthRevoked() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);

        // Authorize then revoke
        morpho.setAuthorization(address(leverageRouter), true);
        morpho.setAuthorization(address(leverageRouter), false);

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_Expired() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with expired deadline
        vm.expectRevert("Transaction expired");
        leverageRouter.openLeverage(principal, leverage, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_Revert_SlippageTooHigh() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with slippage exceeding MAX_SLIPPAGE_BPS (100)
        vm.expectRevert("Slippage exceeds maximum");
        leverageRouter.openLeverage(principal, leverage, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==========================================
    // CLOSE LEVERAGE TESTS
    // ==========================================

    function test_CloseLeverage_Success() public {
        // First open a leveraged position
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x
        uint256 maxSlippageBps = 100; // 1% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);

        // Verify position was opened
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 3000 * 1e18, "Incorrect supplied amount after open");
        assertEq(borrowed, 2000 * 1e6, "Incorrect borrowed amount after open");

        // Now close the position
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position was closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Supplied should be 0 after close");
        assertEq(borrowedAfter, 0, "Borrowed should be 0 after close");
    }

    function test_CloseLeverage_EmitsLeverageClosedEvent() public {
        // First open a leveraged position
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 3 * 1e18;
        uint256 maxSlippageBps = 50; // 0.5% slippage

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);
        leverageRouter.openLeverage(principal, leverage, maxSlippageBps, block.timestamp + 1 hours);

        // Now close the position and check event
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;
        uint256 expectedUsdcReturned = 1000 * 1e6; // 3000 mDXY -> 3000 USDC - 2000 debt = 1000

        vm.expectEmit(true, false, false, true);
        emit LeverageRouter.LeverageClosed(
            alice, debtToRepay, collateralToWithdraw, expectedUsdcReturned, maxSlippageBps
        );

        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, maxSlippageBps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_NoAuth() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        // Skip authorization

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_Expired() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);

        vm.expectRevert("Transaction expired");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 50, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_CloseLeverage_Revert_SlippageTooHigh() public {
        uint256 debtToRepay = 2000 * 1e6;
        uint256 collateralToWithdraw = 3000 * 1e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with slippage exceeding MAX_SLIPPAGE_BPS (100)
        vm.expectRevert("Slippage exceeds maximum");
        leverageRouter.closeLeverage(debtToRepay, collateralToWithdraw, 101, block.timestamp + 1 hours);
        vm.stopPrank();
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFlashLender is IERC3156FlashLender {
    address token;

    constructor(address _token) {
        token = _token;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address t, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        MockToken(token).mint(address(receiver), amount); // Send money
        require(
            receiver.onFlashLoan(msg.sender, t, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        return true;
    }
}

contract MockSwapRouter is ISwapRouter {
    function exchange(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        // Detect swap direction by checking decimals difference
        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> mDXY (18) : * 1e12
            amountOut = amountIn * 1e12;
        } else {
            // mDXY (18) -> USDC (6) : / 1e12
            amountOut = amountIn / 1e12;
        }

        require(amountOut >= minAmountOut, "Too little received");
        MockToken(tokenOut).mint(msg.sender, amountOut);
        return amountOut;
    }
}

contract MockMorpho is IMorpho {
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => ActionData) public positions;

    struct ActionData {
        uint256 supplied;
        uint256 borrowed;
    }

    function setAuthorization(address operator, bool approved) external {
        isAuthorized[msg.sender][operator] = approved;
    }

    function supply(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied += assets;
        return (assets, 0);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed += assets;
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed -= assets;
        return (assets, 0);
    }

    function withdraw(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied -= assets;
        return (assets, 0);
    }
}
