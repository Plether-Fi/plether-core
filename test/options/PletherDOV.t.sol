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

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function convertToAssets(
        uint256 shares
    ) external pure returns (uint256) {
        return shares / 1e3;
    }

    function previewWithdraw(
        uint256 assets
    ) external pure returns (uint256) {
        return assets * 1e3;
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

    function unlockCollateral(
        uint256 seriesId
    ) external {
        uint256 shares = sharesLocked[seriesId];
        sharesLocked[seriesId] = 0;
        if (shares > 0) {
            stakedToken.safeTransfer(msg.sender, shares);
        }
    }

    function exercise(
        uint256 seriesId,
        uint256 optionsAmount
    ) external {
        MockOptionERC20(_series[seriesId].optionToken).burn(msg.sender, optionsAmount);
    }

    function series(
        uint256 seriesId
    ) external view returns (bool, uint256, uint256, address, uint256, uint256, bool, uint256) {
        MockSeries storage s = _series[seriesId];
        return (s.isBull, s.strike, s.expiry, s.optionToken, s.settlementPrice, s.settlementShareRate, s.isSettled, 0);
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

    uint256 constant INITIAL_STAKED = 1000e21; // 1000 assets worth of staked tokens (21 dec)
    uint256 constant USDC_BALANCE = 100_000e6;

    function setUp() public {
        vm.warp(1_735_689_600);

        stakedToken = new MockStakedTokenForDOV("splDXY-BEAR", "splBEAR");
        usdc = new MockUSDCPermit();
        splitter = new MockSplitterForDOV();

        marginEngine = new MockMarginEngine(address(stakedToken), address(splitter));

        dov = new PletherDOV("BEAR DOV", "bDOV", address(marginEngine), address(stakedToken), address(usdc), false);

        // Fund DOV with staked tokens
        stakedToken.mint(address(dov), INITIAL_STAKED);

        // Fund users
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
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
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

        // Maker paid USDC premium
        assertEq(makerUsdcBefore - usdc.balanceOf(maker), expectedPremium);

        // Maker received option tokens
        (,,, address optAddr,,,,) = marginEngine.series(1);
        assertEq(IERC20(optAddr).balanceOf(maker), optionsMinted);
    }

    function test_FillAuction_RevertsIfNotAuctioning() public {
        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.fillAuction();
    }

    function test_FillAuction_RevertsAfterDuration() public {
        _startAuction();
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(maker);
        vm.expectRevert(PletherDOV.PletherDOV__AuctionEnded.selector);
        dov.fillAuction();
    }

    function test_CancelAuction_UnlocksExpiredAuction() public {
        _startAuction();
        vm.warp(block.timestamp + 2 hours);

        dov.cancelAuction();
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));

        // Settle previous epoch's series before starting new one (M-5 fix)
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

        // Settle the series in the margin engine first
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

        // Should revert: epoch was filled (winningMaker != address(0)),
        // only settleEpoch should be able to unlock this collateral.
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.reclaimCollateral(1);
    }

    function test_ExerciseUnsoldOptions_BurnsAfterCancel() public {
        _startAuction();

        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        marginEngine.settle(1, new uint80[](0));

        (,,, address optAddr,,,,) = marginEngine.series(1);
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
        // Force OTM: settlement price below strike
        marginEngine.setSettlementPrice(1, 80_000_000);

        (,,, address optAddr,,,,) = marginEngine.series(1);
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

        dov.emergencyWithdraw(IERC20(address(stakedToken)));
        assertEq(stakedToken.balanceOf(address(dov)), 0, "all staked tokens withdrawn");
    }

    function test_EmergencyWithdraw_RecoversPremiumUsdc() public {
        _startAuction();
        vm.prank(maker);
        dov.fillAuction();

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        uint256 usdcBalance = usdc.balanceOf(address(dov));
        assertGt(usdcBalance, 0, "DOV should hold USDC premium");

        dov.emergencyWithdraw(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(address(dov)), 0, "all USDC withdrawn");
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

        // Do NOT call marginEngine.settle() separately — settleEpoch should handle it
        dov.settleEpoch(new uint80[](0));

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertGt(stakedToken.balanceOf(address(dov)), 0, "DOV should receive collateral back");
    }

    // ==========================================
    // M-3: EARLY CANCEL ON LIQUIDATION
    // ==========================================

    function test_CancelAuction_AllowsEarlyCancelOnLiquidation() public {
        _startAuction();

        // Liquidation happens mid-auction, before duration expires
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        // Should succeed despite auction not expired
        dov.cancelAuction();
        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
    }

    // ==========================================
    // M-5: EPOCH ORDERING ENFORCEMENT
    // ==========================================

    function test_StartEpochAuction_RevertsIfPreviousUnsettled() public {
        _startAuction();
        vm.warp(block.timestamp + 2 hours);
        dov.cancelAuction();

        // Previous epoch series is NOT settled — should revert
        vm.expectRevert(PletherDOV.PletherDOV__WrongState.selector);
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
    }

}
