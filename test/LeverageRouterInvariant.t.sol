// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageRouterBase} from "../src/base/LeverageRouterBase.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {IMorpho, IMorphoFlashLoanCallback, MarketParams} from "../src/interfaces/IMorpho.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";

// ==========================================
// MOCK CONTRACTS FOR INVARIANT TESTS
// ==========================================

contract InvariantMockToken is ERC20 {

    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

}

/// @notice Mock plDXY-BEAR with ERC3156 flash mint support
contract InvariantMockFlashToken is ERC20, IERC3156FlashLender {

    uint8 private _decimals;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    // ERC3156 Flash Loan
    function maxFlashLoan(
        address token
    ) external view override returns (uint256) {
        return token == address(this) ? type(uint256).max - totalSupply() : 0;
    }

    function flashFee(
        address token,
        uint256
    ) external view override returns (uint256) {
        require(token == address(this), "Invalid token");
        return 0; // Fee-free flash mint
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == address(this), "Invalid token");
        _mint(address(receiver), amount);
        require(receiver.onFlashLoan(msg.sender, token, amount, 0, data) == CALLBACK_SUCCESS, "Callback failed");
        _burn(address(receiver), amount);
        return true;
    }

}

contract InvariantMockStakedToken is ERC20 {

    IERC20 public underlying;

    constructor(
        address _underlying
    ) ERC20("Staked Token", "sTKN") {
        underlying = IERC20(_underlying);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares; // 1:1 for simplicity
        underlying.transfer(receiver, assets);
    }

    function previewRedeem(
        uint256 shares
    ) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }

}

contract InvariantMockCurvePool is ICurvePool {

    address public token0; // USDC
    address public token1; // plDxyBear
    uint256 public bearPrice = 1e6; // 1:1 with USDC

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(
        uint256 _price
    ) external {
        bearPrice = _price;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;
        InvariantMockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        InvariantMockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12;
    }

}

contract InvariantMockMorpho is IMorpho {

    address public usdc;
    address public stakedToken;
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public _isAuthorized;

    constructor(
        address _usdc,
        address _stakedToken
    ) {
        usdc = _usdc;
        stakedToken = _stakedToken;
    }

    function setAuthorization(
        address authorized,
        bool newIsAuthorized
    ) external override {
        _isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(
        MarketParams memory
    ) external override {}

    function idToMarketParams(
        bytes32
    ) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external override {
        InvariantMockToken(token).mint(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        InvariantMockToken(token).burn(address(this), assets);
    }

    function supply(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        bytes calldata
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function withdraw(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        address
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function supplyCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        bytes calldata
    ) external override {
        IERC20(stakedToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
    }

    function withdrawCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external override {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        collateralBalance[onBehalfOf] -= assets;
        IERC20(stakedToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        address receiver
    ) external override returns (uint256, uint256) {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        InvariantMockToken(usdc).mint(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        bytes calldata
    ) external override returns (uint256, uint256) {
        InvariantMockToken(usdc).transferFrom(msg.sender, address(this), assets);
        borrowBalance[onBehalfOf] -= assets;
        return (assets, 0);
    }

    function position(
        bytes32,
        address
    ) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(
        bytes32
    ) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    function accrueInterest(
        MarketParams memory
    ) external override {}

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    // Helper for returning both values at once
    function positions(
        address user
    ) external view returns (uint256 collateral, uint256 debt) {
        return (collateralBalance[user], borrowBalance[user]);
    }

}

// ==========================================
// LEVERAGE ROUTER HANDLER
// ==========================================

contract LeverageRouterHandler is Test {

    LeverageRouter public router;
    InvariantMockMorpho public morpho;
    InvariantMockToken public usdc;
    InvariantMockToken public plDxyBear;
    InvariantMockStakedToken public stakedPlDxyBear;
    InvariantMockCurvePool public curvePool;
    MarketParams public marketParams;

    // Actors
    address[] public actors;
    address internal currentActor;

    // Ghost variables for tracking
    uint256 public ghost_totalOpened;
    uint256 public ghost_totalFullyClosed;
    uint256 public ghost_totalCloseOperations;
    uint256 public ghost_totalPrincipalDeposited;
    uint256 public ghost_totalUsdcReturned;

    // Position tracking
    mapping(address => bool) public hasPosition;

    modifier useActor(
        uint256 actorSeed
    ) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        LeverageRouter _router,
        InvariantMockMorpho _morpho,
        InvariantMockToken _usdc,
        InvariantMockToken _plDxyBear,
        InvariantMockStakedToken _stakedPlDxyBear,
        InvariantMockCurvePool _curvePool,
        MarketParams memory _marketParams
    ) {
        router = _router;
        morpho = _morpho;
        usdc = _usdc;
        plDxyBear = _plDxyBear;
        stakedPlDxyBear = _stakedPlDxyBear;
        curvePool = _curvePool;
        marketParams = _marketParams;

        // Create actors
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 1000));
            actors.push(actor);
            // Fund each actor
            usdc.mint(actor, 1_000_000 * 1e6); // $1M each
            vm.prank(actor);
            usdc.approve(address(router), type(uint256).max);
            vm.prank(actor);
            morpho.setAuthorization(address(router), true);
        }
    }

    function openLeverage(
        uint256 actorSeed,
        uint256 principal,
        uint256 leverage
    ) external useActor(actorSeed) {
        // Bound inputs
        principal = bound(principal, 100e6, 100_000e6); // $100 to $100k
        leverage = bound(leverage, 2e18, 5e18); // 2x to 5x

        // Skip if actor doesn't have enough
        if (usdc.balanceOf(currentActor) < principal) return;

        try router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours) {
            ghost_totalOpened++;
            ghost_totalPrincipalDeposited += principal;
            hasPosition[currentActor] = true;
        } catch {
            // Expected failures are OK
        }
    }

    function closeLeverage(
        uint256 actorSeed
    ) external useActor(actorSeed) {
        uint256 collateral = morpho.collateralBalance(currentActor);

        // Skip if no position
        if (collateral == 0) return;

        uint256 usdcBefore = usdc.balanceOf(currentActor);

        // Router queries actual debt from Morpho
        try router.closeLeverage(collateral, 100, block.timestamp + 1 hours) {
            ghost_totalCloseOperations++;
            ghost_totalUsdcReturned += usdc.balanceOf(currentActor) - usdcBefore;
            if (morpho.collateralBalance(currentActor) == 0) {
                hasPosition[currentActor] = false;
                ghost_totalFullyClosed++;
            }
        } catch {
            // Expected failures are OK
        }
    }

    function partialClose(
        uint256 actorSeed,
        uint256 collateralRatio
    ) external useActor(actorSeed) {
        uint256 collateral = morpho.collateralBalance(currentActor);

        // Skip if no position
        if (collateral == 0) return;

        // Bound ratio
        collateralRatio = bound(collateralRatio, 10, 100);

        uint256 collateralToWithdraw = (collateral * collateralRatio) / 100;

        if (collateralToWithdraw == 0) return;

        // Router queries actual debt from Morpho
        try router.closeLeverage(collateralToWithdraw, 100, block.timestamp + 1 hours) {
            ghost_totalCloseOperations++;
            if (morpho.collateralBalance(currentActor) == 0) {
                hasPosition[currentActor] = false;
                ghost_totalFullyClosed++;
            }
        } catch {
            // Expected failures are OK
        }
    }

    // View helpers
    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(
        uint256 index
    ) external view returns (address) {
        return actors[index % actors.length];
    }

}

// ==========================================
// LEVERAGE ROUTER INVARIANT TESTS
// ==========================================

contract LeverageRouterInvariantTest is StdInvariant, Test {

    LeverageRouter public router;
    InvariantMockMorpho public morpho;
    InvariantMockToken public usdc;
    InvariantMockToken public plDxyBear;
    InvariantMockStakedToken public stakedPlDxyBear;
    InvariantMockCurvePool public curvePool;
    LeverageRouterHandler public handler;
    MarketParams public marketParams;

    function setUp() public {
        // Deploy mocks
        usdc = new InvariantMockToken("USDC", "USDC", 6);
        plDxyBear = new InvariantMockToken("plDXY-BEAR", "BEAR", 18);
        stakedPlDxyBear = new InvariantMockStakedToken(address(plDxyBear));
        curvePool = new InvariantMockCurvePool(address(usdc), address(plDxyBear));
        morpho = new InvariantMockMorpho(address(usdc), address(stakedPlDxyBear));

        // Fund Morpho for flash loans
        usdc.mint(address(morpho), 100_000_000e6);

        marketParams = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedPlDxyBear),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        router = new LeverageRouter(
            address(morpho),
            address(curvePool),
            address(usdc),
            address(plDxyBear),
            address(stakedPlDxyBear),
            marketParams
        );

        handler = new LeverageRouterHandler(router, morpho, usdc, plDxyBear, stakedPlDxyBear, curvePool, marketParams);

        targetContract(address(handler));

        // Labels for traces
        vm.label(address(router), "LeverageRouter");
        vm.label(address(morpho), "Morpho");
        vm.label(address(handler), "Handler");
    }

    /// @notice Router should never hold any tokens after operations complete
    function invariant_routerStateless() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds USDC");
        assertEq(plDxyBear.balanceOf(address(router)), 0, "Router holds plDXY-BEAR");
        assertEq(stakedPlDxyBear.balanceOf(address(router)), 0, "Router holds splDXY-BEAR");
    }

    /// @notice Total fully closed positions should be <= total opened positions
    function invariant_openCloseConsistency() public view {
        assertGe(handler.ghost_totalOpened(), handler.ghost_totalFullyClosed(), "More full closes than opens");
    }

    /// @notice Summary for debugging
    function invariant_callSummary() public view {
        console.log("=== LeverageRouter Invariant Summary ===");
        console.log("Total opened:", handler.ghost_totalOpened());
        console.log("Total fully closed:", handler.ghost_totalFullyClosed());
        console.log("Total close operations:", handler.ghost_totalCloseOperations());
        console.log("Total principal deposited:", handler.ghost_totalPrincipalDeposited());
        console.log("Total USDC returned:", handler.ghost_totalUsdcReturned());
    }

}

// ==========================================
// BULL LEVERAGE ROUTER HANDLER
// ==========================================

/// @notice Mock Splitter for BullLeverageRouter tests
contract InvariantMockSplitter is ISyntheticSplitter {

    InvariantMockToken public usdc;
    InvariantMockFlashToken public plDxyBear;
    InvariantMockToken public plDxyBull;
    uint256 public constant CAP_VALUE = 200_000_000; // $2.00 in 8 decimals

    constructor(
        address _usdc,
        address _plDxyBear,
        address _plDxyBull
    ) {
        usdc = InvariantMockToken(_usdc);
        plDxyBear = InvariantMockFlashToken(_plDxyBear);
        plDxyBull = InvariantMockToken(_plDxyBull);
    }

    function CAP() external pure override returns (uint256) {
        return CAP_VALUE;
    }

    function currentStatus() external pure override returns (Status) {
        return Status.ACTIVE;
    }

    function mint(
        uint256 tokenAmount
    ) external override {
        // Calculate USDC cost: usdc = tokenAmount * CAP / 1e12
        uint256 usdcCost = (tokenAmount * CAP_VALUE) / 1e12;
        usdc.transferFrom(msg.sender, address(this), usdcCost);
        plDxyBear.mint(msg.sender, tokenAmount);
        plDxyBull.mint(msg.sender, tokenAmount);
    }

    function burn(
        uint256 tokenAmount
    ) external override {
        plDxyBear.transferFrom(msg.sender, address(this), tokenAmount);
        plDxyBull.transferFrom(msg.sender, address(this), tokenAmount);
        // Return USDC: usdc = tokenAmount * CAP / 1e12
        uint256 usdcReturn = (tokenAmount * CAP_VALUE) / 1e12;
        usdc.transfer(msg.sender, usdcReturn);
    }

    function emergencyRedeem(
        uint256 amount
    ) external override {
        // Not used in invariant tests, but required by interface
        plDxyBear.transferFrom(msg.sender, address(this), amount);
        uint256 usdcReturn = (amount * CAP_VALUE) / 1e12;
        usdc.transfer(msg.sender, usdcReturn);
    }

}

/// @notice Mock Morpho that supports both splDXY-BEAR and splDXY-BULL as collateral
contract InvariantMockMorphoBull is IMorpho {

    address public usdc;
    address public stakedBear;
    address public stakedBull;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public _isAuthorized;

    constructor(
        address _usdc,
        address _stakedBear,
        address _stakedBull
    ) {
        usdc = _usdc;
        stakedBear = _stakedBear;
        stakedBull = _stakedBull;
    }

    function setAuthorization(
        address authorized,
        bool newIsAuthorized
    ) external override {
        _isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(
        MarketParams memory
    ) external override {}

    function idToMarketParams(
        bytes32
    ) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external override {
        InvariantMockToken(token).mint(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        InvariantMockToken(token).burn(address(this), assets);
    }

    function supply(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        bytes calldata
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function withdraw(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        address
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function supplyCollateral(
        MarketParams memory params,
        uint256 assets,
        address onBehalfOf,
        bytes calldata
    ) external override {
        IERC20(params.collateralToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
    }

    function withdrawCollateral(
        MarketParams memory params,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external override {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        collateralBalance[onBehalfOf] -= assets;
        IERC20(params.collateralToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        address receiver
    ) external override returns (uint256, uint256) {
        if (msg.sender != onBehalfOf) {
            require(_isAuthorized[onBehalfOf][msg.sender], "Not authorized");
        }
        InvariantMockToken(usdc).mint(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        bytes calldata
    ) external override returns (uint256, uint256) {
        InvariantMockToken(usdc).transferFrom(msg.sender, address(this), assets);
        borrowBalance[onBehalfOf] -= assets;
        return (assets, 0);
    }

    function position(
        bytes32,
        address
    ) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(
        bytes32
    ) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    function accrueInterest(
        MarketParams memory
    ) external override {}

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function positions(
        address user
    ) external view returns (uint256 collateral, uint256 debt) {
        return (collateralBalance[user], borrowBalance[user]);
    }

}

contract BullLeverageRouterHandler is Test {

    BullLeverageRouter public router;
    InvariantMockMorphoBull public morpho;
    InvariantMockToken public usdc;
    InvariantMockFlashToken public plDxyBear;
    InvariantMockToken public plDxyBull;
    InvariantMockStakedToken public stakedPlDxyBull;
    InvariantMockCurvePool public curvePool;
    InvariantMockSplitter public splitter;
    MarketParams public marketParams;

    // Actors
    address[] public actors;
    address internal currentActor;

    // Ghost variables
    uint256 public ghost_totalOpened;
    uint256 public ghost_totalFullyClosed;
    uint256 public ghost_totalCloseOperations;
    uint256 public ghost_totalPrincipalDeposited;
    uint256 public ghost_totalUsdcReturned;

    modifier useActor(
        uint256 actorSeed
    ) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        BullLeverageRouter _router,
        InvariantMockMorphoBull _morpho,
        InvariantMockToken _usdc,
        InvariantMockFlashToken _plDxyBear,
        InvariantMockToken _plDxyBull,
        InvariantMockStakedToken _stakedPlDxyBull,
        InvariantMockCurvePool _curvePool,
        InvariantMockSplitter _splitter,
        MarketParams memory _marketParams
    ) {
        router = _router;
        morpho = _morpho;
        usdc = _usdc;
        plDxyBear = _plDxyBear;
        plDxyBull = _plDxyBull;
        stakedPlDxyBull = _stakedPlDxyBull;
        curvePool = _curvePool;
        splitter = _splitter;
        marketParams = _marketParams;

        // Create actors
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 1000));
            actors.push(actor);
            // Fund each actor
            usdc.mint(actor, 1_000_000 * 1e6);
            vm.prank(actor);
            usdc.approve(address(router), type(uint256).max);
            vm.prank(actor);
            morpho.setAuthorization(address(router), true);
        }
    }

    function openLeverage(
        uint256 actorSeed,
        uint256 principal,
        uint256 leverage
    ) external useActor(actorSeed) {
        // Bound inputs
        principal = bound(principal, 1000e6, 100_000e6); // $1k to $100k
        leverage = bound(leverage, 2e18, 4e18); // 2x to 4x (tighter for Bull)

        if (usdc.balanceOf(currentActor) < principal) return;

        try router.openLeverage(principal, leverage, 100, block.timestamp + 1 hours) {
            ghost_totalOpened++;
            ghost_totalPrincipalDeposited += principal;
        } catch {
            // Expected failures are OK
        }
    }

    function closeLeverage(
        uint256 actorSeed
    ) external useActor(actorSeed) {
        uint256 collateral = morpho.collateralBalance(currentActor);

        if (collateral == 0) return;

        uint256 usdcBefore = usdc.balanceOf(currentActor);

        // Router queries actual debt from Morpho
        try router.closeLeverage(collateral, 100, block.timestamp + 1 hours) {
            ghost_totalCloseOperations++;
            ghost_totalUsdcReturned += usdc.balanceOf(currentActor) - usdcBefore;
            if (morpho.collateralBalance(currentActor) == 0) {
                ghost_totalFullyClosed++;
            }
        } catch {
            // Expected failures are OK
        }
    }

    function partialClose(
        uint256 actorSeed,
        uint256 collateralRatio
    ) external useActor(actorSeed) {
        uint256 collateral = morpho.collateralBalance(currentActor);

        if (collateral == 0) return;

        // Bound ratio
        collateralRatio = bound(collateralRatio, 10, 100);

        uint256 collateralToWithdraw = (collateral * collateralRatio) / 100;

        if (collateralToWithdraw == 0) return;

        // Router queries actual debt from Morpho
        try router.closeLeverage(collateralToWithdraw, 100, block.timestamp + 1 hours) {
            ghost_totalCloseOperations++;
            if (morpho.collateralBalance(currentActor) == 0) {
                ghost_totalFullyClosed++;
            }
        } catch {
            // Expected failures are OK
        }
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(
        uint256 index
    ) external view returns (address) {
        return actors[index % actors.length];
    }

}

// ==========================================
// BULL LEVERAGE ROUTER INVARIANT TESTS
// ==========================================

contract BullLeverageRouterInvariantTest is StdInvariant, Test {

    BullLeverageRouter public router;
    InvariantMockMorphoBull public morpho;
    InvariantMockToken public usdc;
    InvariantMockFlashToken public plDxyBear;
    InvariantMockToken public plDxyBull;
    InvariantMockStakedToken public stakedPlDxyBull;
    InvariantMockCurvePool public curvePool;
    InvariantMockSplitter public splitter;
    BullLeverageRouterHandler public handler;
    MarketParams public marketParams;

    function setUp() public {
        // Deploy mocks
        usdc = new InvariantMockToken("USDC", "USDC", 6);
        plDxyBear = new InvariantMockFlashToken("plDXY-BEAR", "BEAR", 18);
        plDxyBull = new InvariantMockToken("plDXY-BULL", "BULL", 18);
        stakedPlDxyBull = new InvariantMockStakedToken(address(plDxyBull));
        curvePool = new InvariantMockCurvePool(address(usdc), address(plDxyBear));
        splitter = new InvariantMockSplitter(address(usdc), address(plDxyBear), address(plDxyBull));
        morpho = new InvariantMockMorphoBull(address(usdc), address(0), address(stakedPlDxyBull));

        // Fund Morpho for flash loans
        usdc.mint(address(morpho), 100_000_000e6);
        // Fund Splitter for burns
        usdc.mint(address(splitter), 100_000_000e6);
        // Fund Curve pool for swaps
        usdc.mint(address(curvePool), 100_000_000e6);

        marketParams = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(stakedPlDxyBull),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        router = new BullLeverageRouter(
            address(morpho),
            address(splitter),
            address(curvePool),
            address(usdc),
            address(plDxyBear),
            address(plDxyBull),
            address(stakedPlDxyBull),
            marketParams
        );

        handler = new BullLeverageRouterHandler(
            router, morpho, usdc, plDxyBear, plDxyBull, stakedPlDxyBull, curvePool, splitter, marketParams
        );

        targetContract(address(handler));

        // Labels
        vm.label(address(router), "BullLeverageRouter");
        vm.label(address(morpho), "Morpho");
        vm.label(address(splitter), "Splitter");
        vm.label(address(handler), "Handler");
    }

    /// @notice Router should never hold any tokens after operations complete
    function invariant_routerStateless() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds USDC");
        assertEq(plDxyBear.balanceOf(address(router)), 0, "Router holds plDXY-BEAR");
        assertEq(plDxyBull.balanceOf(address(router)), 0, "Router holds plDXY-BULL");
        assertEq(stakedPlDxyBull.balanceOf(address(router)), 0, "Router holds splDXY-BULL");
    }

    /// @notice Total fully closed positions should be <= total opened positions
    function invariant_openCloseConsistency() public view {
        assertGe(handler.ghost_totalOpened(), handler.ghost_totalFullyClosed(), "More full closes than opens");
    }

    /// @notice Summary for debugging
    function invariant_callSummary() public view {
        console.log("=== BullLeverageRouter Invariant Summary ===");
        console.log("Total opened:", handler.ghost_totalOpened());
        console.log("Total fully closed:", handler.ghost_totalFullyClosed());
        console.log("Total close operations:", handler.ghost_totalCloseOperations());
        console.log("Total principal deposited:", handler.ghost_totalPrincipalDeposited());
        console.log("Total USDC returned:", handler.ghost_totalUsdcReturned());
    }

}
