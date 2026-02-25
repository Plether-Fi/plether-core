// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {FlashLoanBase} from "../../src/base/FlashLoanBase.sol";
import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {DOVZapRouter} from "../../src/options/DOVZapRouter.sol";
import {PletherDOV} from "../../src/options/PletherDOV.sol";
import {MockUSDCPermit} from "../utils/MockUSDCPermit.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/Test.sol";

// ─── Mock: plDXY Token (BULL) ───────────────────────────────────────────

contract MockPlDxyToken is ERC20 {

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

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

// ─── Mock: Flash-mintable BEAR Token ────────────────────────────────────

contract MockFlashBearToken is ERC20, IERC3156FlashLender {

    constructor() ERC20("plDXY-BEAR", "plBEAR") {}

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

    function maxFlashLoan(
        address token
    ) external view override returns (uint256) {
        if (token == address(this)) {
            return type(uint256).max;
        }
        return 0;
    }

    function flashFee(
        address,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == address(this), "wrong token");
        _mint(address(receiver), amount);
        bytes32 result = receiver.onFlashLoan(msg.sender, token, amount, 0, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "callback failed");
        _burn(address(receiver), amount);
        return true;
    }

}

// ─── Mock: StakedToken (ERC4626-like) ───────────────────────────────────

contract MockStakedTokenForZap is ERC20 {

    using SafeERC20 for IERC20;

    address private _asset;

    constructor(
        string memory name_,
        string memory symbol_,
        address asset_
    ) ERC20(name_, symbol_) {
        _asset = asset_;
    }

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function previewRedeem(
        uint256 shares
    ) external pure returns (uint256) {
        return shares / 1e3;
    }

    function previewWithdraw(
        uint256 assets
    ) external pure returns (uint256) {
        return assets * 1e3;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        shares = assets * 1e3;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

// ─── Mock: Splitter ─────────────────────────────────────────────────────

contract MockSplitterForZap {

    using SafeERC20 for IERC20;

    uint256 public constant CAP = 2e8;
    uint256 public liquidationTimestamp;
    ISyntheticSplitter.Status private _status = ISyntheticSplitter.Status.ACTIVE;

    IERC20 public usdc;
    MockFlashBearToken public bearToken;
    MockPlDxyToken public bullToken;

    constructor() {}

    function init(
        address _usdc,
        address _bearToken,
        address _bullToken
    ) external {
        usdc = IERC20(_usdc);
        bearToken = MockFlashBearToken(_bearToken);
        bullToken = MockPlDxyToken(_bullToken);
    }

    function currentStatus() external view returns (ISyntheticSplitter.Status) {
        return _status;
    }

    function setStatus(
        ISyntheticSplitter.Status s
    ) external {
        _status = s;
        if (s == ISyntheticSplitter.Status.SETTLED) {
            liquidationTimestamp = block.timestamp;
        }
    }

    function mint(
        uint256 amount
    ) external {
        uint256 usdcNeeded = (amount * CAP) / 1e20;
        usdc.safeTransferFrom(msg.sender, address(this), usdcNeeded);
        bearToken.mint(msg.sender, amount);
        bullToken.mint(msg.sender, amount);
    }

}

// ─── Mock: Curve Pool ───────────────────────────────────────────────────

contract MockCurvePoolForZap {

    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IERC20 public bear;
    uint256 public bearPriceUsdc; // 6 decimals per 1e18 BEAR
    uint256 public exchangeSlippageBps;

    constructor(
        address _usdc,
        address _bear,
        uint256 _bearPriceUsdc
    ) {
        usdc = IERC20(_usdc);
        bear = IERC20(_bear);
        bearPriceUsdc = _bearPriceUsdc;
    }

    function setBearPrice(
        uint256 newPrice
    ) external {
        bearPriceUsdc = newPrice;
    }

    function setExchangeSlippage(
        uint256 bps
    ) external {
        exchangeSlippageBps = bps;
    }

    function get_dy(
        uint256 i,
        uint256,
        uint256 dx
    ) external view returns (uint256) {
        if (i == 0) {
            return (dx * 1e18) / bearPriceUsdc;
        } else {
            return (dx * bearPriceUsdc) / 1e18;
        }
    }

    function exchange(
        uint256 i,
        uint256,
        uint256 dx,
        uint256 min_dy
    ) external payable returns (uint256 dy) {
        if (i == 0) {
            dy = (dx * 1e18) / bearPriceUsdc;
            dy = dy * (10_000 - exchangeSlippageBps) / 10_000;
            usdc.safeTransferFrom(msg.sender, address(this), dx);
            bear.safeTransfer(msg.sender, dy);
        } else {
            dy = (dx * bearPriceUsdc) / 1e18;
            dy = dy * (10_000 - exchangeSlippageBps) / 10_000;
            bear.safeTransferFrom(msg.sender, address(this), dx);
            usdc.safeTransfer(msg.sender, dy);
        }
        require(dy >= min_dy, "slippage");
    }

}

// ─── Mock: MarginEngine for DOV ─────────────────────────────────────────

contract MockMarginEngineForZap {

    using SafeERC20 for IERC20;

    error MarginEngine__ZeroAmount();

    struct MockSeries {
        bool isBull;
        uint256 strike;
        uint256 expiry;
        address optionToken;
        uint256 settlementPrice;
        uint256 settlementShareRate;
        bool isSettled;
    }

    IERC20 public stakedToken;
    address public SPLITTER;
    uint256 public nextId = 1;
    mapping(uint256 => MockSeries) internal _series;
    mapping(uint256 => uint256) public sharesLocked;

    constructor(
        address _stakedToken,
        address _splitter
    ) {
        stakedToken = IERC20(_stakedToken);
        SPLITTER = _splitter;
    }

    function createSeries(
        bool isBull,
        uint256 strike,
        uint256 expiry,
        string memory,
        string memory
    ) external returns (uint256 id) {
        id = nextId++;
        _series[id] = MockSeries(isBull, strike, expiry, address(0), 0, 0, false);
    }

    function mintOptions(
        uint256 seriesId,
        uint256 optionsAmount
    ) external {
        uint256 shares = optionsAmount * 1e3;
        stakedToken.safeTransferFrom(msg.sender, address(this), shares);
        sharesLocked[seriesId] += shares;
    }

    function settle(
        uint256 seriesId,
        uint80[] calldata
    ) external {
        _series[seriesId].isSettled = true;
    }

    function unlockCollateral(
        uint256 seriesId
    ) external {
        uint256 shares = sharesLocked[seriesId];
        if (shares == 0) {
            revert MarginEngine__ZeroAmount();
        }
        sharesLocked[seriesId] = 0;
        stakedToken.safeTransfer(msg.sender, shares);
    }

    function series(
        uint256 seriesId
    ) external view returns (bool, uint256, uint256, address, uint256, uint256, bool) {
        MockSeries storage s = _series[seriesId];
        return (s.isBull, s.strike, s.expiry, s.optionToken, s.settlementPrice, s.settlementShareRate, s.isSettled);
    }

}

// ─── Tests ──────────────────────────────────────────────────────────────

contract DOVZapRouterTest is Test {

    MockFlashBearToken public bearToken;
    MockPlDxyToken public bullToken;
    MockUSDCPermit public usdc;
    MockSplitterForZap public splitter;
    MockCurvePoolForZap public curvePool;

    MockStakedTokenForZap public stakedBear;
    MockStakedTokenForZap public stakedBull;

    MockMarginEngineForZap public bearEngine;
    MockMarginEngineForZap public bullEngine;

    PletherDOV public bearDov;
    PletherDOV public bullDov;
    DOVZapRouter public router;

    uint256 constant INITIAL_STAKED = 1000e21;

    function setUp() public {
        vm.warp(1_735_689_600);

        bearToken = new MockFlashBearToken();
        bullToken = new MockPlDxyToken("plDXY-BULL", "plBULL");
        usdc = new MockUSDCPermit();

        stakedBear = new MockStakedTokenForZap("splDXY-BEAR", "splBEAR", address(bearToken));
        stakedBull = new MockStakedTokenForZap("splDXY-BULL", "splBULL", address(bullToken));

        splitter = new MockSplitterForZap();
        splitter.init(address(usdc), address(bearToken), address(bullToken));

        curvePool = new MockCurvePoolForZap(address(usdc), address(bearToken), 800_000);
        bearToken.mint(address(curvePool), 1_000_000e18);
        usdc.mint(address(curvePool), 1_000_000e6);

        bearEngine = new MockMarginEngineForZap(address(stakedBear), address(splitter));
        bullEngine = new MockMarginEngineForZap(address(stakedBull), address(splitter));

        bearDov = new PletherDOV("BEAR DOV", "bDOV", address(bearEngine), address(stakedBear), address(usdc), false);

        bullDov = new PletherDOV("BULL DOV", "buDOV", address(bullEngine), address(stakedBull), address(usdc), true);

        router = new DOVZapRouter(
            address(splitter),
            address(curvePool),
            address(usdc),
            address(bearToken),
            address(bullToken),
            address(stakedBear),
            address(stakedBull),
            address(bearDov),
            address(bullDov)
        );

        bearDov.setZapKeeper(address(router));
        bullDov.setZapKeeper(address(router));

        stakedBear.mint(address(bearDov), INITIAL_STAKED);
        stakedBull.mint(address(bullDov), INITIAL_STAKED);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _defaultBearParams() internal view returns (DOVZapRouter.EpochParams memory) {
        return DOVZapRouter.EpochParams({
            strike: 90e6, expiry: block.timestamp + 7 days, maxPremium: 1e6, minPremium: 100_000, duration: 1 hours
        });
    }

    function _defaultBullParams() internal view returns (DOVZapRouter.EpochParams memory) {
        return DOVZapRouter.EpochParams({
            strike: 90e6, expiry: block.timestamp + 7 days, maxPremium: 1e6, minPremium: 100_000, duration: 1 hours
        });
    }

    // ==========================================
    // COORDINATED ZAP TESTS
    // ==========================================

    function test_CoordinatedZap_MatchedMinting() public {
        usdc.mint(address(bearDov), 10_000e6);
        usdc.mint(address(bullDov), 10_000e6);

        uint256 baselineOptions = 1000e18; // from INITIAL_STAKED alone

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        (, uint256 bearOpts,,,,,) = bearDov.epochs(1);
        (, uint256 bullOpts,,,,,) = bullDov.epochs(1);
        assertGt(bearOpts, baselineOptions, "bear DOV should mint more options than baseline");
        assertGt(bullOpts, baselineOptions, "bull DOV should mint more options than baseline");
        assertEq(usdc.balanceOf(address(bearDov)), 0, "bear DOV USDC consumed");
        assertEq(usdc.balanceOf(address(bullDov)), 0, "bull DOV USDC consumed");
        assertEq(usdc.balanceOf(address(router)), 0, "no USDC left in router");
    }

    function test_CoordinatedZap_BearExcess() public {
        usdc.mint(address(bearDov), 10_000e6);
        usdc.mint(address(bullDov), 8000e6);

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        assertEq(usdc.balanceOf(address(router)), 0, "no USDC left in router");
        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_CoordinatedZap_BullExcess() public {
        usdc.mint(address(bearDov), 5000e6);
        usdc.mint(address(bullDov), 10_000e6);

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        assertEq(usdc.balanceOf(address(router)), 0, "no USDC left in router");
        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_CoordinatedZap_OnlyBearDOV() public {
        DOVZapRouter bearOnlyRouter = new DOVZapRouter(
            address(splitter),
            address(curvePool),
            address(usdc),
            address(bearToken),
            address(bullToken),
            address(stakedBear),
            address(stakedBull),
            address(bearDov),
            address(0)
        );
        bearDov.setZapKeeper(address(bearOnlyRouter));

        usdc.mint(address(bearDov), 5000e6);
        uint256 baselineOptions = 1000e18;

        bearOnlyRouter.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        (, uint256 bearOpts,,,,,) = bearDov.epochs(1);
        assertGt(bearOpts, baselineOptions, "bear DOV should mint more options than baseline");
        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_CoordinatedZap_OnlyBullDOV() public {
        DOVZapRouter bullOnlyRouter = new DOVZapRouter(
            address(splitter),
            address(curvePool),
            address(usdc),
            address(bearToken),
            address(bullToken),
            address(stakedBear),
            address(stakedBull),
            address(0),
            address(bullDov)
        );
        bullDov.setZapKeeper(address(bullOnlyRouter));

        usdc.mint(address(bullDov), 5000e6);
        uint256 baselineOptions = 1000e18;

        bullOnlyRouter.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        (, uint256 bullOpts,,,,,) = bullDov.epochs(1);
        assertGt(bullOpts, baselineOptions, "bull DOV should mint more options than baseline");
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_CoordinatedZap_ZeroUsdc() public {
        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_CoordinatedZap_SlippageProtection() public {
        usdc.mint(address(bearDov), 10_000e6);

        vm.expectRevert("slippage");
        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), type(uint256).max);
    }

    function test_CoordinatedZap_SolvencyBreach() public {
        MockCurvePoolForZap badPool = new MockCurvePoolForZap(address(usdc), address(bearToken), 800_000);
        bearToken.mint(address(badPool), 1_000_000e18);
        usdc.mint(address(badPool), 1_000_000e6);
        badPool.setExchangeSlippage(9900); // 99% slippage

        DOVZapRouter badRouter = new DOVZapRouter(
            address(splitter),
            address(badPool),
            address(usdc),
            address(bearToken),
            address(bullToken),
            address(stakedBear),
            address(stakedBull),
            address(0),
            address(bullDov)
        );
        bullDov.setZapKeeper(address(badRouter));

        usdc.mint(address(bullDov), 10_000e6);

        vm.expectRevert(DOVZapRouter.DOVZapRouter__SolvencyBreach.selector);
        badRouter.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);
    }

    function test_CoordinatedZap_StartsEpochAuctions() public {
        usdc.mint(address(bearDov), 5000e6);
        usdc.mint(address(bullDov), 5000e6);

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0);

        assertEq(bearDov.currentEpochId(), 1);
        assertEq(bullDov.currentEpochId(), 1);
        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    function test_OnFlashLoan_ValidationChecks() public {
        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidLender.selector);
        router.onFlashLoan(address(router), address(bearToken), 1e18, 0, "");

        vm.prank(address(bearToken));
        vm.expectRevert(FlashLoanBase.FlashLoan__InvalidInitiator.selector);
        router.onFlashLoan(address(0xdead), address(bearToken), 1e18, 0, "");
    }

}
