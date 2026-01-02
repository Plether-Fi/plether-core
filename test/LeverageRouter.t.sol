// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import "../src/interfaces/ICurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public router;

    // Mocks
    MockToken public usdc;
    MockToken public dxyBear;
    MockStakedToken public stakedDxyBear;
    MockCurvePool public curvePool;
    MockMorpho public morpho;
    MockFlashLender public lender;

    // FIX: Make params a state variable so we can reuse it correctly
    MarketParams public params;

    address alice = address(0xA11ce);

    function setUp() public {
        usdc = new MockToken("USDC", "USDC");
        dxyBear = new MockToken("DXY-BEAR", "BEAR");
        stakedDxyBear = new MockStakedToken(address(dxyBear));
        curvePool = new MockCurvePool(address(usdc), address(dxyBear));
        morpho = new MockMorpho(address(usdc), address(stakedDxyBear));
        lender = new MockFlashLender();

        // FIX: Assign to state variable
        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedDxyBear),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        router = new LeverageRouter(
            address(morpho),
            address(curvePool),
            address(usdc),
            address(dxyBear),
            address(stakedDxyBear),
            address(lender),
            params
        );

        usdc.mint(alice, 1000 * 1e6);
        // Fund Lender
        usdc.mint(address(lender), 10_000 * 1e6);
    }

    // ==========================================
    // TESTS
    // ==========================================

    function test_OpenLeverage_Success() public {
        // Alice has 1000 USDC. Wants 3x (3e18).
        // Loan = 2000 USDC. Total = 3000 USDC.
        // Bear Price $1.00. 3000 USDC -> 3000 BEAR.

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true); // CRITICAL STEP

        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Check Morpho State
        // Alice should have Collateral = 3000 BEAR
        // Alice should have Debt = 2000 USDC
        assertEq(morpho.collateralBalance(alice), 3000 * 1e18, "Collateral mismatch");
        assertEq(morpho.borrowBalance(alice), 2000 * 1e6, "Debt mismatch");
    }

    function test_OpenLeverage_BearExpensive() public {
        // Bear Price $1.50.
        curvePool.setPrice(1_500_000);

        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        morpho.setAuthorization(address(router), true);

        // 3x Leverage on $1000 = Borrow $2000. Total $3000 USDC.
        // $3000 USDC / $1.50 = 2000 BEAR.
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(morpho.collateralBalance(alice), 2000 * 1e18, "Expensive: Collateral mismatch");
    }

    function test_CloseLeverage_Success() public {
        // Setup existing position: 3000 sDXY-BEAR Collateral, 2000 USDC Debt
        usdc.mint(address(morpho), 2000 * 1e6); // Fund morpho for borrowing

        vm.startPrank(alice);
        // Manually create position in mock: mint BEAR -> stake to sBEAR -> supply to Morpho
        dxyBear.mint(alice, 3000 * 1e18);
        dxyBear.approve(address(stakedDxyBear), 3000 * 1e18);
        stakedDxyBear.deposit(3000 * 1e18, alice); // Alice gets 3000 sDXY-BEAR

        stakedDxyBear.approve(address(morpho), 3000 * 1e18);
        morpho.supply(params, 3000 * 1e18, 0, alice, "");
        morpho.borrow(params, 2000 * 1e6, 0, alice, alice); // Alice holds the debt

        // Now Close
        morpho.setAuthorization(address(router), true);
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(morpho.collateralBalance(alice), 0, "Collateral not cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt not cleared");
        assertGt(usdc.balanceOf(alice), 0, "Alice got no money back");
    }

    function test_Unauthorized_Reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * 1e6);
        // Forgot setAuthorization!

        vm.expectRevert("LeverageRouter not authorized in Morpho");
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_PreviewOpenLeverage_Success() public view {
        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBear, uint256 expectedDebt) =
            router.previewOpenLeverage(1000 * 1e6, 3e18);

        assertEq(loanAmount, 2000 * 1e6, "Loan amount mismatch");
        assertEq(totalUSDC, 3000 * 1e6, "Total USDC mismatch");
        assertGt(expectedDxyBear, 0, "Expected DXY-BEAR should be > 0");
        assertEq(expectedDebt, 2000 * 1e6, "Expected debt mismatch (no fee)");
    }

    function test_PreviewOpenLeverage_RevertOnLowLeverage() public {
        vm.expectRevert("Leverage must be > 1x");
        router.previewOpenLeverage(1000 * 1e6, 1e18);
    }

    function test_PreviewCloseLeverage_Success() public view {
        (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) =
            router.previewCloseLeverage(2000 * 1e6, 3000 * 1e18);

        assertGt(expectedUSDC, 0, "Expected USDC should be > 0");
        assertEq(flashFee, 0, "Flash fee should be 0 (mock)");
        assertGt(expectedReturn, 0, "Expected return should be > 0");
    }

    function test_PreviewCloseLeverage_ZeroReturn() public view {
        // When debt is huge relative to collateral, return should be 0
        (,, uint256 expectedReturn) = router.previewCloseLeverage(10000 * 1e6, 100 * 1e18);
        assertEq(expectedReturn, 0, "Expected return should be 0 when insolvent");
    }

    function test_OpenLeverage_ZeroPrincipal_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Principal must be > 0");
        router.openLeverage(0, 3e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_LeverageAtMinimum_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        // Leverage = 1x exactly should revert
        vm.expectRevert("Leverage must be > 1x");
        router.openLeverage(1000 * 1e6, 1e18, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_LeverageTooLow_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1e6); // 1 USDC

        // Leverage = 1.0001x with 1 USDC = 0.0001 USDC loan which rounds to 0
        vm.expectRevert("Leverage too low for principal");
        router.openLeverage(1e6, 1e18 + 100, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_OpenLeverage_Deadline_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        vm.expectRevert("Transaction expired");
        router.openLeverage(1000 * 1e6, 3e18, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_CloseLeverage_Deadline_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);

        vm.expectRevert("Transaction expired");
        router.closeLeverage(2000 * 1e6, 3000 * 1e18, 100, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_OpenLeverage_SlippageExceedsMax_Reverts() public {
        vm.startPrank(alice);
        morpho.setAuthorization(address(router), true);
        usdc.approve(address(router), 1000 * 1e6);

        vm.expectRevert("Slippage exceeds maximum");
        router.openLeverage(1000 * 1e6, 3e18, 200, block.timestamp + 1 hours); // 200 bps > 100 max
        vm.stopPrank();
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStakedToken is ERC20 {
    MockToken public underlying;

    constructor(address _underlying) ERC20("Staked Token", "sTKN") {
        underlying = MockToken(_underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares; // 1:1 for simplicity
        underlying.transfer(receiver, assets);
    }
}

contract MockFlashLender is IERC3156FlashLender {
    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256) public pure override returns (uint256) {
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        MockToken(token).mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        MockToken(token).transferFrom(address(receiver), address(this), amount); // Repay
        return true;
    }
}

contract MockCurvePool is ICurvePool {
    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(uint256 _price) external {
        bearPrice = _price;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view override returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable override returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        // Correct Transfer Logic
        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12; // Scale 6 decimals to 18 decimals
    }
}

contract MockMorpho is IMorpho {
    address public usdc;
    address public stakedToken; // sDXY-BEAR
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public _isAuthorized;

    constructor(address _usdc, address _stakedToken) {
        usdc = _usdc;
        stakedToken = _stakedToken;
    }

    function setAuthorization(address authorized, bool status) external {
        _isAuthorized[msg.sender][authorized] = status;
    }

    function isAuthorized(address authorizer, address authorized) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function supply(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        IERC20(stakedToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        MockToken(usdc).mint(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        MockToken(usdc).transferFrom(msg.sender, address(this), assets);
        borrowBalance[onBehalfOf] -= assets;
        return (assets, 0);
    }

    function withdraw(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        collateralBalance[onBehalfOf] -= assets;
        // Transfer staked tokens back to receiver
        IERC20(stakedToken).transfer(receiver, assets);
        return (assets, 0);
    }

    function position(bytes32, address) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(bytes32) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }
}
