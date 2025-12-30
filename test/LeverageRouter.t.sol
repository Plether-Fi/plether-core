// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import "../src/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public leverageRouter;

    // Mocks
    MockToken public usdc;
    MockToken public mDXY;
    MockMorpho public morpho;
    MockCurvePool public curvePool;
    MockFlashLender public lender;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        mDXY = new MockToken("mDXY", "mDXY", 18);
        morpho = new MockMorpho();
        curvePool = new MockCurvePool(address(usdc), address(mDXY));
        lender = new MockFlashLender(address(usdc));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(mDXY),
            oracle: address(0),
            irm: address(0),
            lltv: 900000000000000000 // 90%
        });

        leverageRouter = new LeverageRouter(
            address(morpho), address(curvePool), address(usdc), address(mDXY), address(lender), params
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

    function test_OpenLeverage_Revert_LeverageTooLow() public {
        uint256 principal = 1000 * 1e6;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Try with leverage = 1x (must be > 1x)
        vm.expectRevert("Leverage must be > 1x");
        leverageRouter.openLeverage(principal, 1e18, 50, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedLender_Reverts() public {
        vm.startPrank(alice);

        // Alice pretends to be a Flash Lender calling the callback
        vm.expectRevert("Untrusted lender");
        leverageRouter.onFlashLoan(address(leverageRouter), address(usdc), 1000 * 1e6, 0, "");
        vm.stopPrank();
    }

    function test_OnFlashLoan_UntrustedInitiator_Reverts() public {
        // Pretend to be the legitimate lender calling the callback...
        vm.startPrank(address(lender));

        // ...BUT the 'initiator' arg is Alice, not the LeverageRouter itself.
        vm.expectRevert("Untrusted initiator");
        leverageRouter.onFlashLoan(
            alice, // <--- Malicious initiator
            address(usdc),
            1000 * 1e6,
            0,
            ""
        );
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

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_OpenLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs to reasonable ranges
        // Principal: $1 to $1M USDC
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        // Leverage: 1.1x to 10x (in 1e18 units)
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        // Mint enough USDC for alice
        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify invariants
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Expected values (at 1:1 mock rate):
        // totalUSDC = principal + loanAmount = principal + principal * (leverage - 1) / 1e18
        //           = principal * leverage / 1e18
        // mDXY received = totalUSDC * 1e12 (decimal conversion)
        uint256 expectedSupplied = (principal * leverageMultiplier / 1e18) * 1e12;
        uint256 expectedBorrowed = principal * (leverageMultiplier - 1e18) / 1e18;

        assertEq(supplied, expectedSupplied, "Supplied mDXY mismatch");
        assertEq(borrowed, expectedBorrowed, "Borrowed USDC mismatch");
    }

    function testFuzz_OpenAndCloseLeverage(uint256 principal, uint256 leverageMultiplier) public {
        // Bound inputs
        principal = bound(principal, 1e6, 1_000_000 * 1e6);
        leverageMultiplier = bound(leverageMultiplier, 1.1e18, 10e18);

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        // Open position
        leverageRouter.openLeverage(principal, leverageMultiplier, 100, block.timestamp + 1 hours);

        // Get position state
        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);

        // Close entire position
        leverageRouter.closeLeverage(borrowed, supplied, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify position is fully closed
        (uint256 suppliedAfter, uint256 borrowedAfter) = morpho.positions(alice);
        assertEq(suppliedAfter, 0, "Position not fully closed - supplied");
        assertEq(borrowedAfter, 0, "Position not fully closed - borrowed");
    }

    function testFuzz_OpenLeverage_SlippageBound(uint256 slippageBps) public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2e18;

        usdc.mint(alice, principal);

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        morpho.setAuthorization(address(leverageRouter), true);

        if (slippageBps > 100) {
            vm.expectRevert("Slippage exceeds maximum");
            leverageRouter.openLeverage(principal, leverage, slippageBps, block.timestamp + 1 hours);
        } else {
            leverageRouter.openLeverage(principal, leverage, slippageBps, block.timestamp + 1 hours);
            (uint256 supplied,) = morpho.positions(alice);
            assertGt(supplied, 0, "Position should be opened");
        }
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

contract MockCurvePool is ICurvePool {
    address public token0; // USDC (index 0)
    address public token1; // mDXY (index 1)

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external override returns (uint256 dy) {
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // Detect swap direction by checking decimals difference
        uint8 tokenInDecimals = MockToken(tokenIn).decimals();
        uint8 tokenOutDecimals = MockToken(tokenOut).decimals();

        if (tokenInDecimals < tokenOutDecimals) {
            // USDC (6) -> mDXY (18) : * 1e12
            dy = dx * 1e12;
        } else {
            // mDXY (18) -> USDC (6) : / 1e12
            dy = dx / 1e12;
        }

        require(dy >= min_dy, "Too little received");
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
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
