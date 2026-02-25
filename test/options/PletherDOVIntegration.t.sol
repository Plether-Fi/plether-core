// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {PletherDOV} from "../../src/options/PletherDOV.sol";
import {MockUSDCPermit} from "../utils/MockUSDCPermit.sol";
import {OptionsTestSetup} from "../utils/OptionsTestSetup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PletherDOV Integration — real MarginEngine, SettlementOracle, OptionToken
contract PletherDOVIntegrationTest is OptionsTestSetup {

    uint256 constant INITIAL_STAKED = 1000e21;

    MockUSDCPermit public usdc;
    PletherDOV public dov;

    address alice = address(0x1);
    address maker = address(0x2);

    function setUp() public {
        _deployOptionsInfra();
        usdc = new MockUSDCPermit();

        dov = new PletherDOV("BEAR DOV", "bDOV", address(engine), address(stakedBear), address(usdc), false);

        engine.grantRole(engine.SERIES_CREATOR_ROLE(), address(dov));

        stakedBear.mint(address(dov), INITIAL_STAKED);
        dov.initializeShares();

        usdc.mint(alice, 100_000e6);
        usdc.mint(maker, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(dov), type(uint256).max);
        vm.prank(maker);
        usdc.approve(address(dov), type(uint256).max);
    }

    function _mockZap() internal {
        dov.setZapKeeper(address(this));
        uint256 released = dov.releaseUsdcForZap();
        if (released > 0) {
            stakedBear.mint(address(dov), released * 1e15);
        }
    }

    // ==========================================
    // EXISTING LIFECYCLE TESTS (with shares)
    // ==========================================

    function test_FullLifecycle_RealContracts() public {
        uint256 ownerShares = dov.balanceOf(address(this));
        assertEq(ownerShares, 1000e18, "initial shares = seed assets");

        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        (, uint256 optionsMinted,,,,,) = dov.epochs(1);
        assertEq(optionsMinted, 1000e18, "options minted");

        vm.prank(maker);
        dov.fillAuction();

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        dov.settleEpoch(_buildHints());

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        uint256 dovBalance = stakedBear.balanceOf(address(dov));
        assertEq(dovBalance, 849_056_603_773_584_905_661_000, "DOV residual collateral");

        assertEq(dov.totalSupply(), ownerShares, "no dilution without deposits");
        assertGt(usdc.balanceOf(address(dov)), 0, "premium USDC accrued");
    }

    function test_FullLifecycle_WithExercise() public {
        uint256 dovBefore = stakedBear.balanceOf(address(dov));

        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        (uint256 seriesId, uint256 optionsMinted,,,,,) = dov.epochs(1);

        vm.prank(maker);
        dov.fillAuction();

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        dov.settleEpoch(_buildHints());

        (,,, address optAddr,,,) = engine.series(seriesId);
        uint256 makerOptBalance = OptionToken(optAddr).balanceOf(maker);
        assertEq(makerOptBalance, optionsMinted, "maker holds all options");

        vm.prank(maker);
        engine.exercise(seriesId, optionsMinted);

        uint256 makerReceived = stakedBear.balanceOf(maker);
        uint256 dovAfter = stakedBear.balanceOf(address(dov));
        uint256 engineRemaining = stakedBear.balanceOf(address(engine));

        assertEq(dovAfter + makerReceived + engineRemaining, dovBefore, "total shares conserved");
    }

    function test_TwoEpochs_RealContracts() public {
        this.runEpoch1();
        this.runEpoch2();
    }

    function runEpoch1() external {
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
        vm.prank(maker);
        dov.fillAuction();
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertEq(stakedBear.balanceOf(address(dov)), 849_056_603_773_584_905_661_000, "DOV collateral after epoch 1");
    }

    function runEpoch2() external {
        uint256 t0 = block.timestamp;
        uint256 expiry = t0 + 7 days;

        dov.startEpochAuction(95e6, expiry, 800_000, 50_000, 2 hours);
        assertEq(dov.currentEpochId(), 2);

        vm.warp(t0 + 1 hours);
        vm.prank(maker);
        dov.fillAuction();

        vm.warp(expiry);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        assertGt(stakedBear.balanceOf(address(dov)), 0, "DOV should hold collateral after epoch 2");
    }

    // ==========================================
    // SHARE ACCOUNTING INTEGRATION
    // ==========================================

    function test_DepositClaimWithdraw_FullCycle() public {
        vm.prank(alice);
        dov.deposit(5000e6);

        _mockZap();
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        uint256 alicePending = dov.pendingSharesOf(alice);
        assertGt(alicePending, 0, "alice has pending shares");

        vm.prank(alice);
        dov.claimShares();
        assertEq(dov.balanceOf(alice), alicePending);

        vm.prank(maker);
        dov.fillAuction();
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        uint256 aliceShares = dov.balanceOf(alice);
        uint256 supply = dov.totalSupply();
        uint256 dovSplDXY = stakedBear.balanceOf(address(dov));
        uint256 expectedSplDXY = (dovSplDXY * aliceShares) / supply;

        vm.prank(alice);
        dov.withdraw(aliceShares);

        assertEq(dov.balanceOf(alice), 0);
        assertEq(stakedBear.balanceOf(alice), expectedSplDXY);
    }

    function test_PremiumAccrualThenDeposit_SharePriceAppreciates() public {
        this._runPremiumAccrualTest();
    }

    function _runPremiumAccrualTest() external {
        uint256 ownerSharesBefore = dov.balanceOf(address(this));

        uint256 expiry1 = block.timestamp + 7 days;
        dov.startEpochAuction(90e6, expiry1, 1e6, 100_000, 1 hours);
        vm.prank(maker);
        dov.fillAuction();
        vm.warp(expiry1);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        uint256 premiumUsdc = usdc.balanceOf(address(dov));
        assertGt(premiumUsdc, 0, "premium earned");

        this._runPremiumAccrualEpoch2(ownerSharesBefore, expiry1);
    }

    function _runPremiumAccrualEpoch2(
        uint256 ownerSharesBefore,
        uint256 expiry1
    ) external {
        vm.prank(alice);
        dov.deposit(5000e6);

        _mockZap();

        uint256 splDXYPostZap = stakedBear.balanceOf(address(dov));
        uint256 expiry2 = block.timestamp + 7 days;

        dov.startEpochAuction(90e6, expiry2, 1e6, 100_000, 1 hours);

        uint256 supply = dov.totalSupply();
        uint256 ownerSplDXY = (splDXYPostZap * ownerSharesBefore) / supply;

        uint256 initialSeedAssets = stakedBear.convertToAssets(INITIAL_STAKED);
        assertGt(ownerSplDXY, initialSeedAssets * 1e3, "owner value grew from premium");
    }

    function test_MultiEpochDepositsAndWithdrawals() public {
        this._runMultiEpochEpoch1();
        this._runMultiEpochEpoch2();
    }

    function _runMultiEpochEpoch1() external {
        uint256 expiry1 = block.timestamp + 7 days;
        vm.prank(alice);
        dov.deposit(5000e6);
        _mockZap();
        dov.startEpochAuction(90e6, expiry1, 1e6, 100_000, 1 hours);

        vm.prank(maker);
        dov.fillAuction();
        vm.warp(expiry1);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        vm.prank(alice);
        dov.claimShares();
        assertGt(dov.balanceOf(alice), 0);

        uint256 ownerShares = dov.balanceOf(address(this));
        dov.withdraw(ownerShares / 2);
    }

    function _runMultiEpochEpoch2() external {
        uint256 aliceShares = dov.balanceOf(alice);
        uint256 expiry2 = block.timestamp + 7 days;
        dov.startEpochAuction(95e6, expiry2, 800_000, 50_000, 2 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(maker);
        dov.fillAuction();
        vm.warp(expiry2);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        assertEq(dov.balanceOf(alice), aliceShares, "alice shares unchanged");
        assertGt(stakedBear.balanceOf(address(dov)), 0, "vault still has collateral");
        assertGt(usdc.balanceOf(address(dov)), 0, "vault earned epoch 2 premium");
    }

    function test_WithdrawReceivesBothSplDXYAndPremiumUsdc() public {
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);
        vm.prank(maker);
        dov.fillAuction();
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        dov.settleEpoch(_buildHints());

        uint256 dovSplDXY = stakedBear.balanceOf(address(dov));
        uint256 dovUsdc = usdc.balanceOf(address(dov));
        assertGt(dovSplDXY, 0);
        assertGt(dovUsdc, 0);

        uint256 shares = dov.balanceOf(address(this));
        uint256 supply = dov.totalSupply();
        uint256 expectedSplDXY = (dovSplDXY * shares) / supply;
        uint256 expectedUsdc = (dovUsdc * shares) / supply;

        uint256 usdcBefore = usdc.balanceOf(address(this));
        dov.withdraw(shares);

        assertEq(stakedBear.balanceOf(address(this)), expectedSplDXY);
        assertEq(usdc.balanceOf(address(this)) - usdcBefore, expectedUsdc);
        assertEq(dov.totalSupply(), 0, "all shares burned");
    }

}
