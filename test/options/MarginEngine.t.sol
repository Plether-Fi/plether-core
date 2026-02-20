// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

// ─── Inline Mocks ───────────────────────────────────────────────────────

contract MockOptionsSplitter {

    uint256 public CAP = 2e8;
    ISyntheticSplitter.Status private _status = ISyntheticSplitter.Status.ACTIVE;

    function currentStatus() external view returns (ISyntheticSplitter.Status) {
        return _status;
    }

    function setStatus(
        ISyntheticSplitter.Status s
    ) external {
        _status = s;
    }

}

/// @dev 21-decimal ERC20 simulating StakedToken (ERC4626 with _decimalsOffset=3).
contract MockStakedTokenOptions is ERC20 {

    uint256 private _rateNum = 1;
    uint256 private _rateDen = 1;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function setExchangeRate(
        uint256 num,
        uint256 den
    ) external {
        _rateNum = num;
        _rateDen = den;
    }

    /// @dev Rounds DOWN: shares → assets.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256) {
        return (shares * _rateNum) / (_rateDen * 1e3);
    }

    /// @dev Rounds UP: assets → shares (ERC4626 previewWithdraw spec).
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256) {
        uint256 numerator = assets * _rateDen * 1e3;
        return (numerator + _rateNum - 1) / _rateNum;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

// ─── Tests ──────────────────────────────────────────────────────────────

contract MarginEngineTest is Test {

    uint256 constant CAP = 2e8;
    // Oracle basket: bearPrice = 106e6, bullPrice = 94e6
    uint256 constant BEAR_PRICE = 106_000_000;
    uint256 constant BULL_PRICE = 94_000_000;
    uint256 constant ONE_SHARE = 1e21;

    MockOptionsSplitter public splitter;
    SettlementOracle public oracle;
    MockStakedTokenOptions public stakedBear;
    MockStakedTokenOptions public stakedBull;
    OptionToken public optionImpl;
    MarginEngine public engine;

    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;

    address alice = address(0x1);
    address bob = address(0x2);
    address keeper = address(0x3);

    function setUp() public {
        vm.warp(1_735_689_600);

        splitter = new MockOptionsSplitter();

        // Sequencer UP, then warp past grace period
        sequencerFeed = new MockOracle(0, "Sequencer");
        vm.warp(block.timestamp + 2 hours);

        eurFeed = new MockOracle(118_800_000, "EUR/USD");
        jpyFeed = new MockOracle(670_000, "JPY/USD");

        address[] memory feeds = new address[](2);
        feeds[0] = address(eurFeed);
        feeds[1] = address(jpyFeed);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 600_000_000_000_000_000;
        quantities[1] = 400_000_000_000_000_000;
        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = 108_000_000;
        basePrices[1] = 670_000;

        oracle = new SettlementOracle(feeds, quantities, basePrices, CAP, address(sequencerFeed));

        stakedBear = new MockStakedTokenOptions("splDXY-BEAR", "splBEAR");
        stakedBull = new MockStakedTokenOptions("splDXY-BULL", "splBULL");
        optionImpl = new OptionToken();

        engine = new MarginEngine(
            address(splitter), address(oracle), address(stakedBear), address(stakedBull), address(optionImpl)
        );

        // Fund actors with staked tokens (21 decimals) and approve engine
        stakedBear.mint(alice, 1_000_000e21);
        stakedBear.mint(bob, 1_000_000e21);
        stakedBull.mint(alice, 1_000_000e21);
        stakedBull.mint(bob, 1_000_000e21);

        vm.prank(alice);
        stakedBear.approve(address(engine), type(uint256).max);
        vm.prank(alice);
        stakedBull.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        stakedBear.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        stakedBull.approve(address(engine), type(uint256).max);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _createBearSeries(
        uint256 strike
    ) internal returns (uint256) {
        return engine.createSeries(false, strike, block.timestamp + 7 days, "BEAR Option", "oBEAR");
    }

    function _createBullSeries(
        uint256 strike
    ) internal returns (uint256) {
        return engine.createSeries(true, strike, block.timestamp + 7 days, "BULL Option", "oBULL");
    }

    function _getOptionToken(
        uint256 seriesId
    ) internal view returns (OptionToken) {
        (,,, address optAddr,,,) = engine.series(seriesId);
        return OptionToken(optAddr);
    }

    function _refreshFeeds() internal {
        eurFeed.updatePrice(118_800_000);
        jpyFeed.updatePrice(670_000);
    }

    // ==========================================
    // createSeries
    // ==========================================

    function test_CreateSeries_DeploysProxyAndStoresParams() public {
        uint256 expiry = block.timestamp + 7 days;
        uint256 id = engine.createSeries(false, 90e6, expiry, "BEAR-90C", "oBEAR");

        (bool isBull, uint256 strike, uint256 exp, address optAddr, uint256 sp, uint256 ssr, bool settled) =
            engine.series(id);

        assertEq(id, 1);
        assertFalse(isBull);
        assertEq(strike, 90e6);
        assertEq(exp, expiry);
        assertTrue(optAddr != address(0));
        assertEq(sp, 0);
        assertEq(ssr, 0);
        assertFalse(settled);

        OptionToken opt = OptionToken(optAddr);
        assertEq(opt.name(), "BEAR-90C");
        assertEq(opt.symbol(), "oBEAR");
        assertEq(opt.marginEngine(), address(engine));
    }

    function test_CreateSeries_IncrementsSeriesId() public {
        uint256 id1 = _createBearSeries(90e6);
        uint256 id2 = _createBearSeries(80e6);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_CreateSeries_RevertsFromNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        engine.createSeries(false, 90e6, block.timestamp + 7 days, "X", "Y");
    }

    function test_CreateSeries_RevertsOnStrikeAtCAP() public {
        vm.expectRevert(MarginEngine.MarginEngine__InvalidParams.selector);
        engine.createSeries(false, CAP, block.timestamp + 7 days, "X", "Y");
    }

    function test_CreateSeries_RevertsOnPastExpiry() public {
        vm.expectRevert(MarginEngine.MarginEngine__InvalidParams.selector);
        engine.createSeries(false, 90e6, block.timestamp, "X", "Y");
    }

    // ==========================================
    // mintOptions
    // ==========================================

    function test_MintOptions_LocksSharesAndMintsTokens() public {
        uint256 seriesId = _createBearSeries(90e6);
        uint256 optionsAmount = 100e18;
        uint256 expectedShares = stakedBear.previewWithdraw(optionsAmount); // 100e21 at 1:1

        uint256 aliceBefore = stakedBear.balanceOf(alice);

        vm.prank(alice);
        engine.mintOptions(seriesId, optionsAmount);

        assertEq(engine.writerLockedShares(seriesId, alice), expectedShares);
        assertEq(engine.writerOptions(seriesId, alice), optionsAmount);
        assertEq(stakedBear.balanceOf(alice), aliceBefore - expectedShares);
        assertEq(_getOptionToken(seriesId).balanceOf(alice), optionsAmount);
    }

    function test_MintOptions_RevertsOnZeroAmount() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.mintOptions(seriesId, 0);
    }

    function test_MintOptions_RevertsAfterExpiry() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__Expired.selector);
        engine.mintOptions(seriesId, 1e18);
    }

    function test_MintOptions_RevertsWhenSplitterSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__Expired.selector);
        engine.mintOptions(seriesId, 1e18);
    }

    function test_MintOptions_UsesCorrectVaultForBullSeries() public {
        uint256 seriesId = _createBullSeries(90e6);
        uint256 optionsAmount = 50e18;
        uint256 expectedShares = stakedBull.previewWithdraw(optionsAmount);

        uint256 aliceBullBefore = stakedBull.balanceOf(alice);

        vm.prank(alice);
        engine.mintOptions(seriesId, optionsAmount);

        assertEq(stakedBull.balanceOf(alice), aliceBullBefore - expectedShares);
        assertEq(engine.writerLockedShares(seriesId, alice), expectedShares);
    }

    function test_MintOptions_SharesRoundUp() public {
        stakedBear.setExchangeRate(3, 2); // 1e21 shares = 1.5e18 assets

        uint256 seriesId = _createBearSeries(90e6);
        uint256 optionsAmount = 1e18;

        uint256 sharesToLock = stakedBear.previewWithdraw(optionsAmount); // ceil(1e18 * 2 * 1e3 / 3) = 666666666666666666667
        uint256 assetsFromShares = stakedBear.convertToAssets(sharesToLock);
        assertGe(assetsFromShares, optionsAmount, "rounded-up shares must cover options");

        // Floor division would under-cover
        uint256 flooredShares = (optionsAmount * 2 * 1e3) / 3;
        uint256 assetsFromFloor = stakedBear.convertToAssets(flooredShares);
        assertLt(assetsFromFloor, optionsAmount, "floored shares would under-collateralize");

        vm.prank(alice);
        engine.mintOptions(seriesId, optionsAmount);
        assertEq(engine.writerLockedShares(seriesId, alice), sharesToLock);
    }

    // ==========================================
    // settle
    // ==========================================

    function test_Settle_LocksPriceForBearSeries() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        (,,,, uint256 settlementPrice, uint256 settlementShareRate, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, BEAR_PRICE);
        assertEq(settlementShareRate, stakedBear.convertToAssets(ONE_SHARE));
    }

    function test_Settle_LocksPriceForBullSeries() public {
        uint256 seriesId = _createBullSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, BULL_PRICE);
    }

    function test_Settle_RevertsBeforeExpiry() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.expectRevert(MarginEngine.MarginEngine__NotExpired.selector);
        engine.settle(seriesId);
    }

    function test_Settle_RevertsWhenAlreadySettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.expectRevert(MarginEngine.MarginEngine__AlreadySettled.selector);
        engine.settle(seriesId);
    }

    function test_Settle_EarlyAccelerationBearGetsCAP() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId);

        (,,,, uint256 settlementPrice,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, CAP);
    }

    function test_Settle_EarlyAccelerationBullGetsZero() public {
        uint256 seriesId = _createBullSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId);

        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, 0);
    }

    function test_Settle_PermissionlessCallableByAnyone() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        vm.prank(keeper);
        engine.settle(seriesId);

        (,,,,,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
    }

    // ==========================================
    // exercise
    // ==========================================

    function test_Exercise_BurnsOptionsAndPaysShares() public {
        uint256 seriesId = _createBearSeries(90e6);
        uint256 optionsAmount = 100e18;

        // Alice writes, transfers options to Bob
        vm.prank(alice);
        engine.mintOptions(seriesId, optionsAmount);
        OptionToken opt = _getOptionToken(seriesId);
        vm.prank(alice);
        opt.transfer(bob, optionsAmount);

        // Settle
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        // Hand-calculated payout:
        //   assetPayout = 100e18 * (106e6 - 90e6) / 106e6 = 15_094_339_622_641_509_433
        //   sharePayout = assetPayout * 1e21 / 1e18 = 15_094_339_622_641_509_433_000
        uint256 expectedAssetPayout = (optionsAmount * (BEAR_PRICE - 90e6)) / BEAR_PRICE;
        uint256 expectedSharePayout = (expectedAssetPayout * ONE_SHARE) / stakedBear.convertToAssets(ONE_SHARE);

        uint256 bobBefore = stakedBear.balanceOf(bob);

        vm.prank(bob);
        engine.exercise(seriesId, optionsAmount);

        assertEq(opt.balanceOf(bob), 0, "options burned");
        assertEq(stakedBear.balanceOf(bob) - bobBefore, expectedSharePayout, "correct share payout");
    }

    function test_Exercise_RevertsOnZeroAmount() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.prank(bob);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.exercise(seriesId, 0);
    }

    function test_Exercise_RevertsIfNotSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__NotSettled.selector);
        engine.exercise(seriesId, 50e18);
    }

    function test_Exercise_RevertsIfOTM() public {
        // Strike 110e6 > bearPrice 106e6 → OTM
        uint256 seriesId = _createBearSeries(110e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__OptionIsOTM.selector);
        engine.exercise(seriesId, 50e18);
    }

    function test_Exercise_PartialExercise() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.prank(alice);
        engine.exercise(seriesId, 30e18);
        assertEq(_getOptionToken(seriesId).balanceOf(alice), 70e18);

        vm.prank(alice);
        engine.exercise(seriesId, 70e18);
        assertEq(_getOptionToken(seriesId).balanceOf(alice), 0);
    }

    /// @dev Known bug: writer's unlockCollateral reserves shares for ALL options minted,
    /// regardless of how many were actually exercised. If fewer options are exercised than minted,
    /// the difference in shares is stranded in the engine with no recovery mechanism.
    function test_Exercise_StrandedCollateralBug() public {
        uint256 seriesId = _createBearSeries(90e6);

        // Alice writes 100e18 options, transfers all to Bob
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);
        OptionToken opt = _getOptionToken(seriesId);
        vm.prank(alice);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        // Bob exercises only half
        vm.prank(bob);
        engine.exercise(seriesId, 50e18);

        // Alice unlocks — reserves shares for ALL 100e18 options, not just the 50e18 exercised
        vm.prank(alice);
        engine.unlockCollateral(seriesId);

        // Engine still holds shares that were reserved for the unexercised 50e18
        uint256 engineBalance = stakedBear.balanceOf(address(engine));
        assertGt(engineBalance, 0, "shares stranded in engine");

        // Bob could still exercise remaining 50e18, but if he doesn't, shares are stuck forever
        assertEq(opt.balanceOf(bob), 50e18, "Bob has unexercised options");
    }

    // ==========================================
    // unlockCollateral
    // ==========================================

    function test_UnlockCollateral_FullRecoveryWhenOTM() public {
        // Strike 110e6 > bearPrice 106e6 → OTM
        uint256 seriesId = _createBearSeries(110e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        uint256 lockedShares = engine.writerLockedShares(seriesId, alice);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        uint256 aliceBefore = stakedBear.balanceOf(alice);

        vm.prank(alice);
        engine.unlockCollateral(seriesId);

        assertEq(stakedBear.balanceOf(alice) - aliceBefore, lockedShares, "full shares returned when OTM");
    }

    function test_UnlockCollateral_PartialRecoveryWhenITM() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        uint256 lockedShares = engine.writerLockedShares(seriesId, alice);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        (,,,, uint256 settlementPrice, uint256 settlementShareRate,) = engine.series(seriesId);
        uint256 assetPayout = (100e18 * (settlementPrice - 90e6)) / settlementPrice;
        uint256 sharesOwed = (assetPayout * ONE_SHARE) / settlementShareRate;
        uint256 expectedReturn = lockedShares - sharesOwed;

        uint256 aliceBefore = stakedBear.balanceOf(alice);

        vm.prank(alice);
        engine.unlockCollateral(seriesId);

        assertEq(stakedBear.balanceOf(alice) - aliceBefore, expectedReturn, "partial shares returned when ITM");
    }

    function test_UnlockCollateral_RevertsIfNotSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__NotSettled.selector);
        engine.unlockCollateral(seriesId);
    }

    function test_UnlockCollateral_RevertsIfNoPosition() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.prank(bob);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.unlockCollateral(seriesId);
    }

    function test_UnlockCollateral_ClearsWriterState() public {
        uint256 seriesId = _createBearSeries(110e6); // OTM
        vm.prank(alice);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId);

        vm.prank(alice);
        engine.unlockCollateral(seriesId);

        assertEq(engine.writerLockedShares(seriesId, alice), 0);
        assertEq(engine.writerOptions(seriesId, alice), 0);
    }

    // ==========================================
    // FUZZ
    // ==========================================

    function testFuzz_MintOptions_SharesAlwaysGeAssets(
        uint256 amount
    ) public {
        amount = bound(amount, 1e15, 1e24);

        uint256 shares = stakedBear.previewWithdraw(amount);
        uint256 assets = stakedBear.convertToAssets(shares);
        assertGe(assets, amount, "shares must cover at least the option amount");
    }

    function testFuzz_Exercise_PayoutNeverExceedsCollateral(
        uint256 strike,
        uint256 price,
        uint256 amount
    ) public pure {
        uint256 cap = 2e8;
        strike = bound(strike, 1, cap - 1);
        price = bound(price, strike + 1, cap);
        amount = bound(amount, 1e18, 100_000e18);

        uint256 assetPayout = (amount * (price - strike)) / price;
        assertLe(assetPayout, amount, "payout must not exceed collateral");
    }

}
