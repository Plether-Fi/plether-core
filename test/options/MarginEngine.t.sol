// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {OptionsTestSetup} from "../utils/OptionsTestSetup.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MarginEngineTest is OptionsTestSetup {

    address alice = address(0x1);
    address bob = address(0x2);
    address keeper = address(0x3);

    function setUp() public {
        _deployOptionsInfra();
        engine.grantRole(engine.SERIES_CREATOR_ROLE(), address(this));

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

        stakedBear.mint(address(this), 1_000_000e21);
        stakedBull.mint(address(this), 1_000_000e21);
        stakedBear.approve(address(engine), type(uint256).max);
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

    function test_CreateSeries_RevertsFromNonCreator() public {
        bytes32 role = engine.SERIES_CREATOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        engine.createSeries(false, 90e6, block.timestamp + 7 days, "X", "Y");
    }

    function test_CreateSeries_SucceedsFromGrantedDOV() public {
        engine.grantRole(engine.SERIES_CREATOR_ROLE(), bob);
        vm.prank(bob);
        uint256 id = engine.createSeries(false, 90e6, block.timestamp + 7 days, "DOV-BEAR", "oBEAR");
        assertEq(id, 1);
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

        uint256 selfBefore = stakedBear.balanceOf(address(this));

        engine.mintOptions(seriesId, optionsAmount);

        assertEq(engine.writerLockedShares(seriesId, address(this)), expectedShares);
        assertEq(engine.writerOptions(seriesId, address(this)), optionsAmount);
        assertEq(stakedBear.balanceOf(address(this)), selfBefore - expectedShares);
        assertEq(_getOptionToken(seriesId).balanceOf(address(this)), optionsAmount);
    }

    function test_MintOptions_RevertsOnZeroAmount() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.mintOptions(seriesId, 0);
    }

    function test_MintOptions_RevertsAfterExpiry() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        vm.expectRevert(MarginEngine.MarginEngine__Expired.selector);
        engine.mintOptions(seriesId, 1e18);
    }

    function test_MintOptions_RevertsWhenSplitterSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        vm.expectRevert(MarginEngine.MarginEngine__Expired.selector);
        engine.mintOptions(seriesId, 1e18);
    }

    function test_MintOptions_UsesCorrectVaultForBullSeries() public {
        uint256 seriesId = _createBullSeries(90e6);
        uint256 optionsAmount = 50e18;
        uint256 expectedShares = stakedBull.previewWithdraw(optionsAmount);

        uint256 selfBullBefore = stakedBull.balanceOf(address(this));

        engine.mintOptions(seriesId, optionsAmount);

        assertEq(stakedBull.balanceOf(address(this)), selfBullBefore - expectedShares);
        assertEq(engine.writerLockedShares(seriesId, address(this)), expectedShares);
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

        engine.mintOptions(seriesId, optionsAmount);
        assertEq(engine.writerLockedShares(seriesId, address(this)), sharesToLock);
    }

    // ==========================================
    // settle
    // ==========================================

    function test_Settle_LocksPriceForBearSeries() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice, uint256 settlementShareRate, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, BEAR_PRICE);
        assertEq(settlementShareRate, 1e18);
    }

    function test_Settle_LocksPriceForBullSeries() public {
        uint256 seriesId = _createBullSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, BULL_PRICE);
    }

    function test_Settle_RevertsBeforeExpiry() public {
        uint256 seriesId = _createBearSeries(90e6);
        uint80[] memory hints = _buildHints();
        vm.expectRevert(MarginEngine.MarginEngine__NotExpired.selector);
        engine.settle(seriesId, hints);
    }

    function test_Settle_SucceedsAfterLongDelay() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        // Refresh feeds near expiry so historical lookup finds fresh data at expiry
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        // Warp 3 more days — settle should still work via historical lookup
        vm.warp(block.timestamp + 3 days);
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, BEAR_PRICE);
    }

    function test_Settle_EarlyAccelerationWorks() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        // Refresh feeds at expiry so oracle has fresh data
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        vm.warp(block.timestamp + 2 hours);
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId, _buildHints());

        (,,,,,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
    }

    function test_Settle_RevertsWhenAlreadySettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        uint80[] memory hints = _buildHints();
        engine.settle(seriesId, hints);

        vm.expectRevert(MarginEngine.MarginEngine__AlreadySettled.selector);
        engine.settle(seriesId, hints);
    }

    function test_Settle_EarlyAccelerationBearGetsCAP() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, CAP);
    }

    function test_Settle_EarlyAccelerationBullGetsZero() public {
        uint256 seriesId = _createBullSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, 0);
    }

    function test_Settle_PermissionlessCallableByAnyone() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        vm.prank(keeper);
        engine.settle(seriesId, _buildHints());

        (,,,,,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
    }

    // ==========================================
    // exercise
    // ==========================================

    function test_Exercise_BurnsOptionsAndPaysShares() public {
        uint256 seriesId = _createBearSeries(90e6);
        uint256 optionsAmount = 100e18;

        engine.mintOptions(seriesId, optionsAmount);
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, optionsAmount);

        // Settle
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Hand-calculated: 100e18 * 16e6 / 106e6 = 15_094_339_622_641_509_433 assets
        // shares = assets * 1e3 = 15_094_339_622_641_509_433_000
        uint256 expectedSharePayout = 15_094_339_622_641_509_433_000;

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
        engine.settle(seriesId, _buildHints());

        vm.prank(bob);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.exercise(seriesId, 0);
    }

    function test_Exercise_RevertsIfNotSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.expectRevert(MarginEngine.MarginEngine__NotSettled.selector);
        engine.exercise(seriesId, 50e18);
    }

    function test_Exercise_RevertsIfOTM() public {
        // Strike 110e6 > bearPrice 106e6 → OTM
        uint256 seriesId = _createBearSeries(110e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.expectRevert(MarginEngine.MarginEngine__OptionIsOTM.selector);
        engine.exercise(seriesId, 50e18);
    }

    function test_Exercise_RevertsAfter90DayDeadline() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.warp(block.timestamp + 91 days);
        vm.expectRevert(MarginEngine.MarginEngine__Expired.selector);
        engine.exercise(seriesId, 50e18);
    }

    function test_Exercise_SucceedsJustBefore90DayDeadline() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.warp(block.timestamp + 89 days);
        engine.exercise(seriesId, 50e18);
        assertEq(_getOptionToken(seriesId).balanceOf(address(this)), 50e18);
    }

    function test_Exercise_PartialExercise() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        uint256 balBefore = stakedBear.balanceOf(address(this));

        engine.exercise(seriesId, 30e18);
        assertEq(_getOptionToken(seriesId).balanceOf(address(this)), 70e18);
        assertEq(
            stakedBear.balanceOf(address(this)) - balBefore,
            4_528_301_886_792_452_830_000,
            "exerciser received exact shares after first exercise"
        );

        uint256 balMid = stakedBear.balanceOf(address(this));

        engine.exercise(seriesId, 70e18);
        assertEq(_getOptionToken(seriesId).balanceOf(address(this)), 0);
        assertEq(
            stakedBear.balanceOf(address(this)) - balMid,
            10_566_037_735_849_056_603_000,
            "exerciser received exact shares after second exercise"
        );
    }

    function test_Exercise_NoStrandedCollateral() public {
        uint256 seriesId = _createBearSeries(90e6);

        engine.mintOptions(seriesId, 100e18);
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Bob exercises ALL options
        vm.prank(bob);
        engine.exercise(seriesId, 100e18);

        engine.unlockCollateral(seriesId);

        uint256 engineBalance = stakedBear.balanceOf(address(engine));
        assertEq(engineBalance, 0, "no shares stranded in engine");
    }

    function test_UnlockCollateral_CorrectAfterPartialExercise() public {
        uint256 seriesId = _createBearSeries(90e6);
        uint256 optionsAmount = 100e18;

        engine.mintOptions(seriesId, optionsAmount);
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, optionsAmount);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Bob exercises 30 of 100
        vm.prank(bob);
        engine.exercise(seriesId, 30e18);

        // Hand-calculated: sharesOwed = 100e18 * 16e6 / 106e6 * 1e3 = 15_094_339_622_641_509_433_000
        // expectedReturn = 100e21 - 15_094_339_622_641_509_433_000 = 84_905_660_377_358_490_567_000
        uint256 expectedReturn = 84_905_660_377_358_490_567_000;

        uint256 selfBefore = stakedBear.balanceOf(address(this));
        engine.unlockCollateral(seriesId);

        assertEq(stakedBear.balanceOf(address(this)) - selfBefore, expectedReturn, "writer gets correct shares back");
    }

    // ==========================================
    // unlockCollateral
    // ==========================================

    function test_UnlockCollateral_FullRecoveryWhenOTM() public {
        // Strike 110e6 > bearPrice 106e6 → OTM
        uint256 seriesId = _createBearSeries(110e6);
        engine.mintOptions(seriesId, 100e18);

        uint256 lockedShares = engine.writerLockedShares(seriesId, address(this));

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        uint256 selfBefore = stakedBear.balanceOf(address(this));

        engine.unlockCollateral(seriesId);

        assertEq(stakedBear.balanceOf(address(this)) - selfBefore, lockedShares, "full shares returned when OTM");
    }

    function test_UnlockCollateral_PartialRecoveryWhenITM() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Hand-calculated: 100e21 - 15_094_339_622_641_509_433_000 = 84_905_660_377_358_490_567_000
        uint256 expectedReturn = 84_905_660_377_358_490_567_000;

        uint256 selfBefore = stakedBear.balanceOf(address(this));

        engine.unlockCollateral(seriesId);

        assertEq(stakedBear.balanceOf(address(this)) - selfBefore, expectedReturn, "partial shares returned when ITM");
    }

    function test_UnlockCollateral_RevertsIfNotSettled() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.expectRevert(MarginEngine.MarginEngine__NotSettled.selector);
        engine.unlockCollateral(seriesId);
    }

    function test_UnlockCollateral_RevertsIfNoPosition() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.prank(bob);
        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.unlockCollateral(seriesId);
    }

    function test_UnlockCollateral_ClearsWriterState() public {
        uint256 seriesId = _createBearSeries(110e6); // OTM
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        engine.unlockCollateral(seriesId);

        assertEq(engine.writerLockedShares(seriesId, address(this)), 0);
        assertEq(engine.writerOptions(seriesId, address(this)), 0);
    }

    // ==========================================
    // AUDIT: FAILING TESTS
    // ==========================================

    /// @dev C-2: unlockCollateral reverts when >50% of options have been exercised.
    /// The totalSupply() approach makes sharesToReturn exceed the engine's actual balance
    /// because payoutFor(remaining=40) < payoutFor(exercised=60).
    function test_AUDIT_C2_UnlockCollateral_SucceedsAfterMajorityExercise() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Bob exercises 60 of 100 (majority)
        vm.prank(bob);
        engine.exercise(seriesId, 60e18);

        engine.unlockCollateral(seriesId);

        assertEq(engine.writerLockedShares(seriesId, address(this)), 0, "writer position cleared");
    }

    /// @dev H-2: After a cancelled auction, the writer (DOV) still holds unsold options.
    /// The fix: writer exercises their own options before unlocking, recovering full collateral
    /// via exercise payout + unlock return = lockedShares.
    function test_AUDIT_H2_UnlockCollateral_FullRecoveryWhenNoOptionsSold() public {
        uint256 seriesId = _createBearSeries(90e6);

        engine.mintOptions(seriesId, 100e18);
        uint256 lockedShares = engine.writerLockedShares(seriesId, address(this));

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        uint256 selfBefore = stakedBear.balanceOf(address(this));

        engine.exercise(seriesId, 100e18);

        engine.unlockCollateral(seriesId);

        uint256 selfReceived = stakedBear.balanceOf(address(this)) - selfBefore;
        assertEq(selfReceived, lockedShares, "writer recovers full collateral via exercise + unlock");
    }

    // ==========================================
    // EXERCISE CAP (Finding 2)
    // ==========================================

    function test_Exercise_CapsPayoutOnNegativeYield() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        uint256 lockedShares = engine.writerLockedShares(seriesId, address(this));

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        // Extreme negative yield: 1 share now worth 0.1 assets (90% loss)
        stakedBear.setExchangeRate(1, 10);

        engine.settle(seriesId, _buildHints());

        // Transfer options to bob for exercise
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        uint256 bobBefore = stakedBear.balanceOf(bob);

        vm.prank(bob);
        engine.exercise(seriesId, 100e18);

        uint256 bobReceived = stakedBear.balanceOf(bob) - bobBefore;
        assertLe(bobReceived, lockedShares, "payout capped to series collateral");
    }

    function test_Exercise_CrossSeriesIsolation() public {
        // Series A (Alice) and Series B (Bob)
        uint256 seriesA = _createBearSeries(90e6);
        uint256 seriesB = engine.createSeries(false, 90e6, block.timestamp + 7 days, "BEAR-B", "oBEAR-B");

        engine.mintOptions(seriesA, 100e18);
        uint256 seriesBShares = stakedBear.previewWithdraw(100e18);
        engine.mintOptions(seriesB, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        // Negative yield
        stakedBear.setExchangeRate(1, 10);

        engine.settle(seriesA, _buildHints());
        engine.settle(seriesB, _buildHints());

        OptionToken optA = _getOptionToken(seriesA);
        optA.transfer(keeper, 100e18);

        vm.prank(keeper);
        engine.exercise(seriesA, 100e18);

        // After exercising ALL of series A, engine must retain at least series B's locked shares
        uint256 engineBalance = stakedBear.balanceOf(address(engine));
        assertGe(engineBalance, seriesBShares, "series B collateral must be isolated");
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

    // ==========================================
    // H-1: POST-EXPIRY LIQUIDATION
    // ==========================================

    function test_Settle_PostExpiryLiquidationUsesOracle() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        vm.warp(block.timestamp + 1 hours);
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, BEAR_PRICE, "post-expiry liquidation should use oracle price");
    }

    // ==========================================
    // DELAYED EXECUTION MEV PREVENTION
    // ==========================================

    function test_Settle_DelayedExecutionStillUsesHardcodedPrice() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        // Liquidation happens mid-week (before expiry)
        splitter.setStatus(ISyntheticSplitter.Status.SETTLED);

        // MEV attacker delays settle() past expiry, hoping oracle price is more favorable
        vm.warp(block.timestamp + 7 days + 1 hours);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Despite block.timestamp > expiry, the liquidationTimestamp is before expiry
        // so hardcoded prices (CAP for bear, 0 for bull) must be used
        (,,,, uint256 settlementPrice,,) = engine.series(seriesId);
        assertEq(settlementPrice, CAP, "pre-expiry liquidation must use CAP regardless of settle timing");
    }

    // ==========================================
    // H-2: ADMIN SETTLEMENT ESCAPE HATCH
    // ==========================================

    function test_AdminSettle_WorksAfterGracePeriod() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days + 3 days);
        engine.adminSettle(seriesId, BEAR_PRICE);

        (,,,, uint256 settlementPrice,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, BEAR_PRICE);
    }

    function test_AdminSettle_RevertsBeforeGracePeriod() public {
        uint256 seriesId = _createBearSeries(90e6);

        vm.warp(block.timestamp + 7 days + 1 days);
        vm.expectRevert(MarginEngine.MarginEngine__AdminSettleTooEarly.selector);
        engine.adminSettle(seriesId, BEAR_PRICE);
    }

    function test_AdminSettle_RevertsFromNonAdmin() public {
        uint256 seriesId = _createBearSeries(90e6);

        vm.warp(block.timestamp + 7 days + 3 days);
        bytes32 role = engine.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        engine.adminSettle(seriesId, BEAR_PRICE);
    }

    // ==========================================
    // H-2: SHARE RATE SNAPSHOT AT MINT TIME
    // ==========================================

    function test_Settle_UsesCurrentShareRate() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        stakedBear.setExchangeRate(2, 1);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        (,,,, uint256 sp, uint256 ssr,) = engine.series(seriesId);
        assertEq(ssr, 2e18, "settlement rate must equal settle-time rate");
    }

    // ==========================================
    // L-2: STRIKE = 0 REJECTION
    // ==========================================

    function test_CreateSeries_RevertsOnZeroStrike() public {
        vm.expectRevert(MarginEngine.MarginEngine__InvalidParams.selector);
        engine.createSeries(false, 0, block.timestamp + 7 days, "X", "Y");
    }

    // ==========================================
    // M-4: ADMIN SETTLE PRICE VALIDATION
    // ==========================================

    function test_AdminSettle_SucceedsOnZeroPrice() public {
        uint256 seriesId = _createBullSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days + 3 days);
        engine.adminSettle(seriesId, 0);

        (,,,, uint256 settlementPrice,, bool settled) = engine.series(seriesId);
        assertTrue(settled);
        assertEq(settlementPrice, 0, "zero price settlement succeeds for BULL OTM");

        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__OptionIsOTM.selector);
        engine.exercise(seriesId, 50e18);
    }

    // ==========================================
    // M-1: SWEEP UNCLAIMED SHARES
    // ==========================================

    function test_SweepUnclaimedShares_RecoversAfter90Days() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        engine.unlockCollateral(seriesId);

        vm.warp(block.timestamp + 91 days);

        uint256 adminBefore = stakedBear.balanceOf(address(this));
        engine.sweepUnclaimedShares(seriesId);
        uint256 swept = stakedBear.balanceOf(address(this)) - adminBefore;
        assertEq(swept, 15_094_339_622_641_509_433_000, "swept unclaimed shares");
    }

    function test_SweepUnclaimedShares_RevertsBefore90Days() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        engine.unlockCollateral(seriesId);

        vm.warp(block.timestamp + 89 days);

        vm.expectRevert(MarginEngine.MarginEngine__SweepTooEarly.selector);
        engine.sweepUnclaimedShares(seriesId);
    }

    function test_SweepUnclaimedShares_ZeroWhenAllExercised() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.prank(bob);
        engine.exercise(seriesId, 100e18);

        engine.unlockCollateral(seriesId);

        vm.warp(block.timestamp + 91 days);

        vm.expectRevert(MarginEngine.MarginEngine__ZeroAmount.selector);
        engine.sweepUnclaimedShares(seriesId);
    }

    // ==========================================
    // SINGLE WRITER RESTRICTION
    // ==========================================

    function test_MintOptions_RevertsFromNonCreator() public {
        uint256 seriesId = _createBearSeries(90e6);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarginEngine__Unauthorized.selector);
        engine.mintOptions(seriesId, 100e18);
    }

    // ==========================================
    // L-01: adminSettle rejects price 0 for BEAR
    // ==========================================

    function test_AdminSettle_RevertsOnZeroPriceForBear() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days + 3 days);
        vm.expectRevert(MarginEngine.MarginEngine__InvalidParams.selector);
        engine.adminSettle(seriesId, 0);
    }

    // ==========================================
    // L-03: exercise allowed at exactly 90 days
    // ==========================================

    function test_Exercise_AllowedAtExact90Days() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        vm.warp(block.timestamp + 90 days);
        engine.exercise(seriesId, 50e18);
        assertEq(_getOptionToken(seriesId).balanceOf(address(this)), 50e18);
    }

    // ==========================================
    // WRITER UNLOCK UNDER NEGATIVE YIELD
    // ==========================================

    function test_UnlockCollateral_ModerateNegativeYield() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        uint256 lockedShares = engine.writerLockedShares(seriesId, address(this));
        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        // Moderate negative yield: 1 share worth 2/3 of original
        stakedBear.setExchangeRate(2, 3);
        engine.settle(seriesId, _buildHints());

        // Bob exercises all options
        vm.prank(bob);
        engine.exercise(seriesId, 100e18);

        uint256 exercisedShares = engine.totalSeriesExercisedShares(seriesId);

        uint256 selfBefore = stakedBear.balanceOf(address(this));
        engine.unlockCollateral(seriesId);
        uint256 returned = stakedBear.balanceOf(address(this)) - selfBefore;

        assertEq(returned, lockedShares - exercisedShares, "writer gets remainder after exercise");
    }

    function test_UnlockCollateral_ExtremeNegativeYield() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        // Extreme negative yield: 1 share worth 1/10 of original
        stakedBear.setExchangeRate(1, 10);
        engine.settle(seriesId, _buildHints());

        // Bob exercises all options — payout capped to totalShares
        vm.prank(bob);
        engine.exercise(seriesId, 100e18);

        uint256 selfBefore = stakedBear.balanceOf(address(this));
        engine.unlockCollateral(seriesId);
        uint256 returned = stakedBear.balanceOf(address(this)) - selfBefore;

        assertEq(returned, 0, "writer gets nothing under extreme negative yield");
    }

    // ==========================================
    // PARTIAL SWEEP
    // ==========================================

    function test_SweepUnclaimedShares_PartialExercise() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        // Bob exercises 33 of 100
        vm.prank(bob);
        engine.exercise(seriesId, 33e18);

        engine.unlockCollateral(seriesId);

        vm.warp(block.timestamp + 91 days);

        uint256 adminBefore = stakedBear.balanceOf(address(this));
        engine.sweepUnclaimedShares(seriesId);
        uint256 swept = stakedBear.balanceOf(address(this)) - adminBefore;

        // Hand-calculated: globalDebtShares(100) - exercisedShares(33)
        // = 15_094_339_622_641_509_433_000 - 4_981_132_075_471_698_113_000 = 10_113_207_547_169_811_320_000
        uint256 expectedSwept = 10_113_207_547_169_811_320_000;

        assertEq(swept, expectedSwept, "swept amount equals unclaimed debt shares");
    }

    // ==========================================
    // SWEEP ACCESS CONTROL
    // ==========================================

    function test_SweepUnclaimedShares_RevertsFromNonAdmin() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        OptionToken opt = _getOptionToken(seriesId);
        opt.transfer(bob, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        engine.settle(seriesId, _buildHints());

        engine.unlockCollateral(seriesId);
        vm.warp(block.timestamp + 91 days);

        bytes32 role = engine.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        engine.sweepUnclaimedShares(seriesId);
    }

    // ==========================================
    // ADMIN SETTLE PRICE > CAP
    // ==========================================

    function test_AdminSettle_RevertsOnPriceAboveCAP() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days + 3 days);
        vm.expectRevert(MarginEngine.MarginEngine__InvalidParams.selector);
        engine.adminSettle(seriesId, CAP + 1);
    }

    // ==========================================
    // EXCHANGE RATE ZERO FALLBACK
    // ==========================================

    function test_Settle_FallsBackToOneShareWhenRateIsZero() public {
        uint256 seriesId = _createBearSeries(90e6);
        engine.mintOptions(seriesId, 100e18);

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        stakedBear.setExchangeRate(0, 1);

        engine.settle(seriesId, _buildHints());

        (,,,,, uint256 settlementShareRate,) = engine.series(seriesId);
        assertEq(settlementShareRate, ONE_SHARE, "fallback to oneShare when rate is zero");
    }

}
