// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {PletherDOV} from "../../src/options/PletherDOV.sol";
import {MockUSDCPermit} from "../utils/MockUSDCPermit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/Test.sol";

// ─── Inline Mock: Option ERC20 ─────────────────────────────────────────

contract MockOptionERC20 is ERC20 {

    address public minter;

    constructor(
        string memory name_,
        string memory symbol_,
        address _minter
    ) ERC20(name_, symbol_) {
        minter = _minter;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        require(msg.sender == minter, "not minter");
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        require(msg.sender == minter, "not minter");
        _burn(from, amount);
    }

}

// ─── Inline Mock: StakedToken for DOV ───────────────────────────────────

contract MockStakedTokenForDOV is ERC20 {

    uint256 private _withdrawalFeeBps;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function setWithdrawalFee(
        uint256 bps
    ) external {
        _withdrawalFeeBps = bps;
    }

    function convertToAssets(
        uint256 shares
    ) external pure returns (uint256) {
        return shares / 1e3;
    }

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256) {
        uint256 assets = shares / 1e3;
        return assets - (assets * _withdrawalFeeBps) / 10_000;
    }

    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256) {
        uint256 netAssets = assets + (assets * _withdrawalFeeBps) / (10_000 - _withdrawalFeeBps);
        return netAssets * 1e3;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

// ─── Inline Mock: Splitter for DOV ────────────────────────────────────

contract MockSplitterForDOV {

    uint256 public constant CAP = 2e8;
    uint256 public liquidationTimestamp;
    ISyntheticSplitter.Status private _status = ISyntheticSplitter.Status.ACTIVE;

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

}

// ─── Inline Mock: MarginEngine ──────────────────────────────────────────

contract MockMarginEngine {

    using SafeERC20 for IERC20;

    error MarginEngine__ZeroAmount();
    error MarginEngine__NotSettled();

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
    bool public forceUnlockRevert;

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
        string memory name,
        string memory sym
    ) external returns (uint256 id) {
        id = nextId++;
        MockOptionERC20 token = new MockOptionERC20(name, sym, address(this));
        _series[id] = MockSeries(isBull, strike, expiry, address(token), 0, 0, false);
    }

    function mintOptions(
        uint256 seriesId,
        uint256 optionsAmount
    ) external {
        uint256 shares = optionsAmount * 1e3; // 1:1 rate, 21 vs 18 dec
        stakedToken.safeTransferFrom(msg.sender, address(this), shares);
        MockOptionERC20(_series[seriesId].optionToken).mint(msg.sender, optionsAmount);
        sharesLocked[seriesId] += shares;
    }

    function settle(
        uint256 seriesId,
        uint80[] calldata
    ) external {
        _series[seriesId].isSettled = true;
        _series[seriesId].settlementPrice = 106_000_000;
    }

    function setSettlementPrice(
        uint256 seriesId,
        uint256 price
    ) external {
        _series[seriesId].settlementPrice = price;
    }

    function setForceUnlockRevert(
        bool flag
    ) external {
        forceUnlockRevert = flag;
    }

    function unlockCollateral(
        uint256 seriesId
    ) external {
        if (forceUnlockRevert) {
            revert MarginEngine__NotSettled();
        }
        uint256 shares = sharesLocked[seriesId];
        if (shares == 0) {
            revert MarginEngine__ZeroAmount();
        }
        sharesLocked[seriesId] = 0;
        stakedToken.safeTransfer(msg.sender, shares);
    }

    function exercise(
        uint256 seriesId,
        uint256 optionsAmount
    ) external {
        MockOptionERC20(_series[seriesId].optionToken).burn(msg.sender, optionsAmount);
    }

    function series(
        uint256 seriesId
    ) external view returns (bool, uint256, uint256, address, uint256, uint256, bool) {
        MockSeries storage s = _series[seriesId];
        return (s.isBull, s.strike, s.expiry, s.optionToken, s.settlementPrice, s.settlementShareRate, s.isSettled);
    }

}

// ─── Tests ──────────────────────────────────────────────────────────────

contract PletherDOVTest is Test {

    MockStakedTokenForDOV public stakedToken;
    MockUSDCPermit public usdc;
    MockSplitterForDOV public splitter;
    MockMarginEngine public marginEngine;
    PletherDOV public dov;

    address alice = address(0x1); // depositor
    address maker = address(0x2); // market maker
    address keeper = address(0x3);

    uint256 constant INITIAL_STAKED = 1000e21; // 1000 assets worth of staked tokens (21 dec)
    uint256 constant USDC_BALANCE = 100_000e6;

    function setUp() public {
        vm.warp(1_735_689_600);

        usdc = new MockUSDCPermit();
        stakedToken = new MockStakedTokenForDOV("splDXY-BEAR", "splBEAR");
        splitter = new MockSplitterForDOV();
        marginEngine = new MockMarginEngine(address(stakedToken), address(splitter));

        dov = new PletherDOV("BEAR DOV", "bDOV", address(marginEngine), address(stakedToken), address(usdc), false);

        stakedToken.mint(address(dov), INITIAL_STAKED);

        usdc.mint(alice, USDC_BALANCE);
        usdc.mint(maker, USDC_BALANCE);

        vm.prank(alice);
        usdc.approve(address(dov), type(uint256).max);
        vm.prank(maker);
        usdc.approve(address(dov), type(uint256).max);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _startAuction() internal returns (uint256 epochId) {
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
        epochId = dov.currentEpochId();
    }

    /// @dev Simulates the zap flow: release USDC, convert to splDXY, deposit back.
    ///      Mock conversion: 1 USDC (6 dec) = 1e15 splDXY shares (21 dec) = 1e12 assets (18 dec).
    function _mockZap() internal {
        dov.setZapKeeper(address(this));
        uint256 released = dov.releaseUsdcForZap();
        if (released > 0) {
            stakedToken.mint(address(dov), released * 1e15);
        }
        dov.setZapKeeper(keeper);
    }

    // ==========================================
    // deposit
    // ==========================================

    function test_Deposit_QueuesUsdc() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        assertEq(dov.userUsdcDeposits(alice), 1000e6);
        assertEq(dov.pendingUsdcDeposits(), 1000e6);
        assertEq(usdc.balanceOf(address(dov)), 1000e6);
    }

    function test_Deposit_MultipleAccumulate() public {
        vm.prank(alice);
        dov.deposit(500e6);
        vm.prank(alice);
        dov.deposit(300e6);

        assertEq(dov.userUsdcDeposits(alice), 800e6);
        assertEq(dov.pendingUsdcDeposits(), 800e6);
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__ZeroAmount.selector);
        dov.deposit(0);
    }

    // ==========================================
    // withdrawDeposit
    // ==========================================

    function test_WithdrawDeposit_ReturnsUsdc() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        dov.withdrawDeposit(400e6);

        assertEq(dov.userUsdcDeposits(alice), 600e6);
        assertEq(dov.pendingUsdcDeposits(), 600e6);
        assertEq(usdc.balanceOf(alice), balanceBefore + 400e6);
    }

    function test_WithdrawDeposit_FullAmount() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        vm.prank(alice);
        dov.withdrawDeposit(1000e6);

        assertEq(dov.userUsdcDeposits(alice), 0);
        assertEq(dov.pendingUsdcDeposits(), 0);
    }

    function test_WithdrawDeposit_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__ZeroAmount.selector);
        dov.withdrawDeposit(0);
    }

    function test_WithdrawDeposit_RevertsOnInsufficientDeposit() public {
        vm.prank(alice);
        dov.deposit(500e6);

        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__InsufficientDeposit.selector);
        dov.withdrawDeposit(501e6);
    }

    // ==========================================
    // startEpochAuction
    // ==========================================

    function test_StartEpochAuction_CreatesSeriesAndStartsAuction() public {
        _startAuction();

        assertEq(dov.currentEpochId(), 1);
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.AUCTIONING));

        (
            uint256 seriesId,
            uint256 optionsMinted,
            uint256 auctionStartTime,
            uint256 maxPremium,
            uint256 minPremium,
            uint256 auctionDuration,
            address winner
        ) = dov.epochs(1);

        assertEq(seriesId, 1);
        assertGt(optionsMinted, 0);
        assertEq(auctionStartTime, block.timestamp);
        assertEq(maxPremium, 1e6);
        assertEq(minPremium, 100_000);
        assertEq(auctionDuration, 1 hours);
        assertEq(winner, address(0));
    }

    function test_StartEpochAuction_RevertsFromNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__Unauthorized.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    function test_StartEpochAuction_RevertsOnZeroDuration() public {
        vm.expectRevert(PletherDOV.PletherDOV__InvalidParams.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 0);
    }

    function test_StartEpochAuction_RevertsOnMinGreaterThanMax() public {
        vm.expectRevert(PletherDOV.PletherDOV__InvalidParams.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 100_000, 1e6, 1 hours);
    }

    function test_StartEpochAuction_RevertsOnZeroMinPremium() public {
        vm.expectRevert(PletherDOV.PletherDOV__InvalidParams.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 0, 1 hours);
    }

    function test_StartEpochAuction_RevertsIfNotUnlocked() public {
        _startAuction();
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    // ==========================================
    // getCurrentOptionPrice
    // ==========================================

    function test_GetCurrentOptionPrice_MaxAtStart() public {
        _startAuction();
        assertEq(dov.getCurrentOptionPrice(), 1e6);
    }

    function test_GetCurrentOptionPrice_MinAtEnd() public {
        _startAuction();
        vm.warp(block.timestamp + 1 hours);
        assertEq(dov.getCurrentOptionPrice(), 100_000);
    }

    function test_GetCurrentOptionPrice_DecaysLinearly() public {
        _startAuction();
        vm.warp(block.timestamp + 30 minutes); // halfway
        uint256 price = dov.getCurrentOptionPrice();
        uint256 midpoint = (1e6 + 100_000) / 2;
        assertEq(price, midpoint);
    }

    // ==========================================
    // fillAuction
    // ==========================================

    function test_FillAuction_TransfersPremiumAndOptions() public {
        _startAuction();

        (, uint256 optionsMinted,,,,,) = dov.epochs(1);
        uint256 currentPremium = dov.getCurrentOptionPrice();
        uint256 expectedPremium = (optionsMinted * currentPremium) / 1e18;

        uint256 makerUsdcBefore = usdc.balanceOf(maker);

        vm.prank(maker);
        dov.fillAuction();

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.LOCKED));

        assertEq(makerUsdcBefore - usdc.balanceOf(maker), expectedPremium);

        (,,, address optAddr,,,) = marginEngine.series(1);
        assertEq(IERC20(optAddr).balanceOf(maker), optionsMinted);
    }

    function test_FillAuction_RevertsIfNotAuctioning() public {
        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.fillAuction();
    }

    function test_FillAuction_RevertsAfterDuration() public {
        _startAuction();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__AuctionEnded.selector);
        dov.fillAuction();
    }

    function test_CancelAuction_UnlocksExpiredAuction() public {
        _startAuction();
        vm.warp(block.timestamp + 2 hours);

        dov.cancelAuction();
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));

        marginEngine.settle(1, new uint80[](0));
        dov.exerciseUnsoldOptions(1);
        dov.reclaimCollateral(1);

        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
        assertEq(dov.currentEpochId(), 2);
    }

    function test_CancelAuction_RevertsBeforeExpiry() public {
        _startAuction();
        vm.warp(block.timestamp + 30 minutes);

        vm.expectRevert(PletherDOV.PletherDOV__AuctionNotExpired.selector);
        dov.cancelAuction();
    }

    function test_CancelAuction_RevertsIfNotAuctioning() public {
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.cancelAuction();
    }

    // ==========================================
    // settleEpoch
    // ==========================================

    function test_SettleEpoch_UnlocksAndResetsState() public {
        _startAuction();

        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(1, new uint80[](0));

        uint256 stakedBefore = stakedToken.balanceOf(address(dov));
        dov.settleEpoch(new uint80[](0));

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertGt(stakedToken.balanceOf(address(dov)), stakedBefore, "DOV should receive collateral back");
    }

    function test_SettleEpoch_RevertsIfNotLocked() public {
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.settleEpoch(new uint80[](0));
    }

    // ==========================================
    // FULL LIFECYCLE
    // ==========================================

    function test_FullLifecycle_TwoEpochs() public {
        // ── Epoch 1 ──
        _startAuction();

        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        uint256 stakedAfterEpoch1 = stakedToken.balanceOf(address(dov));
        assertGt(stakedAfterEpoch1, 0, "DOV should hold staked tokens after epoch 1");

        // ── Epoch 2 ──
        dov.startEpochAuction(95e6, block.timestamp + 7 days, 800_000, 50_000, 2 hours);
        assertEq(dov.currentEpochId(), 2);

        vm.warp(block.timestamp + 1 hours); // let price decay

        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(2, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertGt(stakedToken.balanceOf(address(dov)), 0, "DOV should hold staked tokens after epoch 2");
    }

    // ==========================================
    // AUDIT: FAILING TESTS
    // ==========================================

    /// @dev C-1: reclaimCollateral has no access control — anyone can call it
    /// for a filled epoch, draining collateral before settleEpoch runs.
    /// With the real MarginEngine this permanently bricks the DOV in LOCKED state.
    function test_AUDIT_C1_ReclaimCollateral_RevertsForFilledEpoch() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(1, new uint80[](0));

        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.reclaimCollateral(1);
    }

    function test_ExerciseUnsoldOptions_BurnsAfterCancel() public {
        _startAuction();

        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        marginEngine.settle(1, new uint80[](0));

        (,,, address optAddr,,,) = marginEngine.series(1);
        uint256 optionBalance = IERC20(optAddr).balanceOf(address(dov));
        assertGt(optionBalance, 0, "DOV holds unsold options");

        dov.exerciseUnsoldOptions(1);

        assertEq(IERC20(optAddr).balanceOf(address(dov)), 0, "all options burned after exercise");
    }

    function test_ExerciseUnsoldOptions_RevertsForFilledEpoch() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.exerciseUnsoldOptions(1);
    }

    // ==========================================
    // AUCTION SNIPING GUARD (Finding 3)
    // ==========================================

    function test_FillAuction_RevertsWhenSeriesSettled() public {
        _startAuction();
        marginEngine.settle(1, new uint80[](0));

        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.fillAuction();
    }

    function test_FillAuction_RevertsWhenSplitterLiquidated() public {
        _startAuction();
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.fillAuction();
    }

    // ==========================================
    // INFORMATIONAL: OTM exercise guard
    // ==========================================

    function test_ExerciseUnsoldOptions_NoRevertWhenOTM() public {
        _startAuction();

        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        marginEngine.settle(1, new uint80[](0));
        marginEngine.setSettlementPrice(1, 80_000_000);

        (,,, address optAddr,,,) = marginEngine.series(1);
        uint256 optionsBefore = IERC20(optAddr).balanceOf(address(dov));
        assertGt(optionsBefore, 0, "DOV holds unsold options");

        dov.exerciseUnsoldOptions(1);

        assertEq(IERC20(optAddr).balanceOf(address(dov)), optionsBefore, "OTM options not exercised");
    }

    // ==========================================
    // H-1: EMERGENCY WITHDRAWAL
    // ==========================================

    function test_EmergencyWithdraw_RecoversFundsAfterLiquidation() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        uint256 stakedBalance = stakedToken.balanceOf(address(dov));
        assertGt(stakedBalance, 0, "DOV should hold staked tokens");

        uint256 ownerBefore = stakedToken.balanceOf(address(this));
        dov.emergencyWithdraw(IERC20(address(stakedToken)));
        assertEq(stakedToken.balanceOf(address(dov)), 0, "all staked tokens withdrawn");
        assertEq(stakedToken.balanceOf(address(this)) - ownerBefore, stakedBalance, "owner received staked tokens");
    }

    function test_EmergencyWithdraw_RecoversPremiumUsdc() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        uint256 usdcBalance = usdc.balanceOf(address(dov));
        assertGt(usdcBalance, 0, "DOV should hold USDC premium");

        uint256 ownerBefore = usdc.balanceOf(address(this));
        dov.emergencyWithdraw(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(address(dov)), 0, "all USDC withdrawn");
        assertEq(usdc.balanceOf(address(this)) - ownerBefore, usdcBalance, "owner received USDC");
    }

    function test_EmergencyWithdraw_RevertsWhenNotSettled() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        vm.expectRevert(PletherDOV.PletherDOV__SplitterNotSettled.selector);
        dov.emergencyWithdraw(IERC20(address(stakedToken)));
    }

    function test_EmergencyWithdraw_RevertsFromNonOwner() public {
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        stakedToken.mint(address(dov), 1e21);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        dov.emergencyWithdraw(IERC20(address(stakedToken)));
    }

    // ==========================================
    // M-2: ATOMIC SETTLE IN settleEpoch
    // ==========================================

    function test_SettleEpoch_AtomicSettleAndUnlock() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        dov.settleEpoch(new uint80[](0));

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertGt(stakedToken.balanceOf(address(dov)), 0, "DOV should receive collateral back");
    }

    // ==========================================
    // M-3: EARLY CANCEL ON LIQUIDATION
    // ==========================================

    function test_CancelAuction_AllowsEarlyCancelOnLiquidation() public {
        _startAuction();

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        dov.cancelAuction();
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
    }

    // ==========================================
    // M-01: FEE-AWARE previewRedeem
    // ==========================================

    function test_StartEpochAuction_UsesPreviewRedeemForFeeAwareness() public {
        uint256 sharesBalance = stakedToken.balanceOf(address(dov));
        uint256 convertToAssetsAmount = stakedToken.convertToAssets(sharesBalance);

        stakedToken.setWithdrawalFee(100); // 1% fee
        uint256 previewRedeemAmount = stakedToken.previewRedeem(sharesBalance);
        assertLt(previewRedeemAmount, convertToAssetsAmount, "previewRedeem should be less with fee");

        _startAuction();

        (, uint256 optionsMinted,,,,,) = dov.epochs(1);
        assertEq(optionsMinted, previewRedeemAmount, "should use previewRedeem, not convertToAssets");
    }

    // ==========================================
    // EPOCH ORDERING ENFORCEMENT
    // ==========================================

    function test_StartEpochAuction_SucceedsAfterCancelledAuction() public {
        _startAuction();
        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        marginEngine.settle(1, new uint80[](0));
        dov.exerciseUnsoldOptions(1);
        dov.reclaimCollateral(1);

        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
        assertEq(dov.currentEpochId(), 2);
    }

    // ==========================================
    // H-02: DEPOSIT EPOCH TRACKING
    // ==========================================

    function test_WithdrawDeposit_RevertsAfterEpochProcessed() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        dov.initializeShares();
        _mockZap();
        _startAuction();

        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__DepositProcessed.selector);
        dov.withdrawDeposit(1000e6);
    }

    function test_Deposit_ResetsStaleBalanceOnNewEpoch() public {
        dov.initializeShares();

        vm.prank(alice);
        dov.deposit(500e6);
        assertEq(dov.userUsdcDeposits(alice), 500e6);

        _mockZap();
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        vm.prank(alice);
        dov.deposit(200e6);

        assertEq(dov.userUsdcDeposits(alice), 200e6, "stale balance must be reset");
        assertEq(dov.userDepositEpoch(alice), dov.currentEpochId(), "epoch must be updated");
    }

    function test_WithdrawDeposit_SucceedsForCurrentEpochDeposit() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        vm.prank(alice);
        dov.deposit(1000e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        dov.withdrawDeposit(1000e6);

        assertEq(usdc.balanceOf(alice), balanceBefore + 1000e6, "withdrawal should succeed");
        assertEq(dov.userUsdcDeposits(alice), 0);
    }

    // ==========================================
    // M-03: settleEpoch succeeds even if unlockCollateral reverts
    // ==========================================

    function test_SettleEpoch_TransitionsEvenIfUnlockReverts() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(1, new uint80[](0));

        marginEngine.unlockCollateral(1);

        dov.settleEpoch(new uint80[](0));
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
    }

    // ==========================================
    // M-04: cancelled auction blocks next epoch if unsettled
    // ==========================================

    function test_StartEpochAuction_RevertsIfCancelledSeriesUnsettled() public {
        _startAuction();
        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    // ==========================================
    // COLD START GUARD
    // ==========================================

    function test_StartEpochAuction_RevertsOnZeroBalance() public {
        PletherDOV emptyDov =
            new PletherDOV("EMPTY DOV", "eDOV", address(marginEngine), address(stakedToken), address(usdc), false);
        vm.expectRevert(PletherDOV.PletherDOV__ZeroAmount.selector);
        emptyDov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    // ==========================================
    // SETTLE EPOCH RE-RAISE
    // ==========================================

    function test_SettleEpoch_ReRaisesNonZeroAmountErrors() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        marginEngine.settle(1, new uint80[](0));
        marginEngine.setForceUnlockRevert(true);

        vm.expectRevert(MockMarginEngine.MarginEngine__NotSettled.selector);
        dov.settleEpoch(new uint80[](0));
    }

    // ==========================================
    // ZAP KEEPER
    // ==========================================

    function test_SetZapKeeper_SetsAddress() public {
        dov.setZapKeeper(keeper);
        assertEq(dov.zapKeeper(), keeper);
    }

    function test_SetZapKeeper_RevertsFromNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        dov.setZapKeeper(keeper);
    }

    function test_ReleaseUsdcForZap_TransfersUsdc() public {
        dov.setZapKeeper(keeper);
        usdc.mint(address(dov), 5000e6);

        vm.prank(keeper);
        uint256 released = dov.releaseUsdcForZap();

        assertEq(released, 5000e6);
        assertEq(usdc.balanceOf(keeper), 5000e6);
        assertEq(usdc.balanceOf(address(dov)), 0);
    }

    function test_ReleaseUsdcForZap_RevertsFromNonKeeper() public {
        dov.setZapKeeper(keeper);
        usdc.mint(address(dov), 5000e6);

        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__Unauthorized.selector);
        dov.releaseUsdcForZap();
    }

    function test_ReleaseUsdcForZap_RevertsIfNotUnlocked() public {
        dov.setZapKeeper(keeper);
        _startAuction();

        vm.prank(keeper);
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.releaseUsdcForZap();
    }

    function test_StartEpochAuction_CallableByKeeper() public {
        dov.setZapKeeper(keeper);

        vm.prank(keeper);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        assertEq(dov.currentEpochId(), 1);
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.AUCTIONING));
    }

    // ==========================================
    // SHARE INITIALIZATION
    // ==========================================

    function test_InitializeShares_MintsSharesForSeedCapital() public {
        uint256 expectedShares = stakedToken.convertToAssets(INITIAL_STAKED);
        dov.initializeShares();

        assertEq(dov.totalSupply(), expectedShares);
        assertEq(dov.balanceOf(address(this)), expectedShares);
    }

    function test_InitializeShares_RevertsIfAlreadyInitialized() public {
        dov.initializeShares();
        vm.expectRevert(PletherDOV.PletherDOV__AlreadyInitialized.selector);
        dov.initializeShares();
    }

    function test_InitializeShares_RevertsIfNoBalance() public {
        PletherDOV emptyDov =
            new PletherDOV("EMPTY", "EMPTY", address(marginEngine), address(stakedToken), address(usdc), false);
        vm.expectRevert(PletherDOV.PletherDOV__ZeroAmount.selector);
        emptyDov.initializeShares();
    }

    function test_InitializeShares_RevertsFromNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        dov.initializeShares();
    }

    // ==========================================
    // CLAIM SHARES
    // ==========================================

    function test_ClaimShares_AfterDepositZapAndEpochStart() public {
        dov.initializeShares();
        uint256 ownerShares = dov.balanceOf(address(this));

        vm.prank(alice);
        dov.deposit(1000e6);

        _mockZap();
        _startAuction();

        uint256 pending = dov.pendingSharesOf(alice);
        assertGt(pending, 0, "alice should have pending shares");

        vm.prank(alice);
        dov.claimShares();

        assertEq(dov.balanceOf(alice), pending, "alice received correct shares");
        assertEq(dov.userUsdcDeposits(alice), 0, "deposit cleared after claim");
        assertGt(dov.totalSupply(), ownerShares, "total supply increased");
    }

    function test_ClaimShares_AutoClaimsOnNewDeposit() public {
        dov.initializeShares();

        vm.prank(alice);
        dov.deposit(1000e6);

        _mockZap();
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        uint256 pending = dov.pendingSharesOf(alice);
        assertGt(pending, 0);

        vm.prank(alice);
        dov.deposit(500e6);

        assertEq(dov.balanceOf(alice), pending, "auto-claimed from previous epoch");
        assertEq(dov.userUsdcDeposits(alice), 500e6, "new deposit recorded");
    }

    function test_ClaimShares_RevertsIfNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(PletherDOV.PletherDOV__NothingToClaim.selector);
        dov.claimShares();
    }

    function test_ClaimShares_MultipleDepositors() public {
        dov.initializeShares();

        address bob = address(0x4);
        usdc.mint(bob, USDC_BALANCE);
        vm.prank(bob);
        usdc.approve(address(dov), type(uint256).max);

        vm.prank(alice);
        dov.deposit(1000e6);
        vm.prank(bob);
        dov.deposit(3000e6);

        _mockZap();
        _startAuction();

        uint256 alicePending = dov.pendingSharesOf(alice);
        uint256 bobPending = dov.pendingSharesOf(bob);

        assertApproxEqRel(bobPending, alicePending * 3, 1e14, "bob deposited 3x alice");

        vm.prank(alice);
        dov.claimShares();
        vm.prank(bob);
        dov.claimShares();

        assertEq(dov.balanceOf(alice), alicePending);
        assertEq(dov.balanceOf(bob), bobPending);
    }

    // ==========================================
    // DEPOSITS NOT ZAPPED GUARD
    // ==========================================

    function test_StartEpochAuction_RevertsIfDepositsNotZapped() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        vm.expectRevert(PletherDOV.PletherDOV__DepositsNotZapped.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    function test_StartEpochAuction_SucceedsWithoutDepositsAndWithoutZap() public {
        _startAuction();
        assertEq(dov.currentEpochId(), 1);
    }

    // ==========================================
    // WITHDRAW
    // ==========================================

    function test_Withdraw_RedeemsSplDXYDuringUnlocked() public {
        dov.initializeShares();
        uint256 shares = dov.balanceOf(address(this));
        uint256 halfShares = shares / 2;

        uint256 dovSplDXYBefore = stakedToken.balanceOf(address(dov));
        uint256 expectedSplDXY = (dovSplDXYBefore * halfShares) / dov.totalSupply();

        dov.withdraw(halfShares);

        assertEq(dov.balanceOf(address(this)), shares - halfShares);
        assertEq(stakedToken.balanceOf(address(this)), expectedSplDXY);
        assertEq(stakedToken.balanceOf(address(dov)), dovSplDXYBefore - expectedSplDXY);
    }

    function test_Withdraw_IncludesPremiumUsdc() public {
        dov.initializeShares();
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        uint256 premiumUsdc = usdc.balanceOf(address(dov));
        assertGt(premiumUsdc, 0, "DOV should hold premium USDC");

        uint256 shares = dov.balanceOf(address(this));
        uint256 supply = dov.totalSupply();
        uint256 expectedUsdc = (premiumUsdc * shares) / supply;

        uint256 usdcBefore = usdc.balanceOf(address(this));
        dov.withdraw(shares);

        assertEq(usdc.balanceOf(address(this)) - usdcBefore, expectedUsdc, "received proportional USDC");
    }

    function test_Withdraw_RevertsIfNotUnlocked() public {
        dov.initializeShares();
        _startAuction();

        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.withdraw(1);
    }

    function test_Withdraw_RevertsOnZeroShares() public {
        vm.expectRevert(PletherDOV.PletherDOV__ZeroAmount.selector);
        dov.withdraw(0);
    }

    function test_Withdraw_ExcludesPendingDepositsFromUsdc() public {
        dov.initializeShares();
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        uint256 premiumUsdc = usdc.balanceOf(address(dov));

        vm.prank(alice);
        dov.deposit(2000e6);

        uint256 shares = dov.balanceOf(address(this));
        uint256 supply = dov.totalSupply();
        uint256 expectedUsdc = (premiumUsdc * shares) / supply;

        uint256 usdcBefore = usdc.balanceOf(address(this));
        dov.withdraw(shares);

        assertEq(usdc.balanceOf(address(this)) - usdcBefore, expectedUsdc, "pending deposits excluded");
        assertEq(usdc.balanceOf(address(dov)), 2000e6, "alice deposit untouched");
    }

    // ==========================================
    // SHARE ACCOUNTING: MULTI-EPOCH LIFECYCLE
    // ==========================================

    function test_ShareAccounting_PremiumAccruesToExistingShareholders() public {
        dov.initializeShares();
        uint256 ownerShares = dov.balanceOf(address(this));

        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        uint256 splDXYAfter = stakedToken.balanceOf(address(dov));
        uint256 premiumUsdc = usdc.balanceOf(address(dov));

        assertEq(dov.balanceOf(address(this)), ownerShares, "no share dilution without deposits");
        assertGt(premiumUsdc, 0, "premium accrued");
        assertGt(splDXYAfter, 0, "residual collateral returned");
    }

    function test_ShareAccounting_FullLifecycleWithDepositsAndWithdrawals() public {
        dov.initializeShares();
        uint256 ownerShares = dov.balanceOf(address(this));
        uint256 initialSplDXY = stakedToken.balanceOf(address(dov));

        // Epoch 1: deposit + auction
        vm.prank(alice);
        dov.deposit(1000e6);
        _mockZap();

        uint256 postZapSplDXY = stakedToken.balanceOf(address(dov));
        assertGt(postZapSplDXY, initialSplDXY, "zap added splDXY");

        _startAuction();
        vm.prank(maker);
        dov.fillAuction();
        marginEngine.settle(1, new uint80[](0));
        dov.settleEpoch(new uint80[](0));

        // Alice claims shares
        vm.prank(alice);
        dov.claimShares();
        uint256 aliceShares = dov.balanceOf(alice);
        assertGt(aliceShares, 0, "alice got shares");

        uint256 totalShares = dov.totalSupply();
        assertEq(totalShares, ownerShares + aliceShares, "total = owner + alice");

        // Alice withdraws half
        uint256 aliceHalf = aliceShares / 2;
        uint256 aliceSplDXYBefore = stakedToken.balanceOf(alice);
        vm.prank(alice);
        dov.withdraw(aliceHalf);

        assertEq(dov.balanceOf(alice), aliceShares - aliceHalf);
        assertGt(stakedToken.balanceOf(alice), aliceSplDXYBefore, "alice received splDXY");
    }

    function test_ShareAccounting_NoDepositsNoSharesMinted() public {
        dov.initializeShares();
        uint256 supplyBefore = dov.totalSupply();

        _startAuction();

        (uint256 totalUsdc, uint256 sharesMinted) = dov.epochDeposits(1);
        assertEq(totalUsdc, 0);
        assertEq(sharesMinted, 0);
        assertEq(dov.totalSupply(), supplyBefore, "supply unchanged with no deposits");
    }

    function test_ShareAccounting_BootstrapWithoutSeedCapital() public {
        PletherDOV freshDov =
            new PletherDOV("FRESH", "FRESH", address(marginEngine), address(stakedToken), address(usdc), false);

        usdc.mint(alice, 5000e6);
        vm.prank(alice);
        usdc.approve(address(freshDov), type(uint256).max);

        vm.prank(alice);
        freshDov.deposit(5000e6);

        freshDov.setZapKeeper(address(this));
        uint256 released = freshDov.releaseUsdcForZap();
        stakedToken.mint(address(freshDov), released * 1e15);

        freshDov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        uint256 pending = freshDov.pendingSharesOf(alice);
        assertGt(pending, 0, "alice has pending shares on fresh vault");

        vm.prank(alice);
        freshDov.claimShares();
        assertEq(freshDov.balanceOf(alice), pending);
        assertEq(freshDov.totalSupply(), pending, "all shares belong to alice");
    }

    function test_ShareAccounting_NotInitializedRevertsIfSeedExists() public {
        dov.setZapKeeper(address(this));

        vm.prank(alice);
        dov.deposit(1000e6);

        dov.releaseUsdcForZap();
        stakedToken.mint(address(dov), 1000e6 * 1e15);

        vm.expectRevert(PletherDOV.PletherDOV__NotInitialized.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    function test_PendingSharesOf_ReturnsZeroBeforeProcessing() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        assertEq(dov.pendingSharesOf(alice), 0, "no pending shares before epoch start");
    }

    function test_TotalVaultAssets_ExcludesPendingDeposits() public {
        vm.prank(alice);
        dov.deposit(1000e6);

        (uint256 splDXYShares, uint256 usdcBalance) = dov.totalVaultAssets();
        assertEq(splDXYShares, INITIAL_STAKED);
        assertEq(usdcBalance, 0, "pending deposits excluded");
    }

}
