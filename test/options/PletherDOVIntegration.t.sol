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

    address maker = address(0x2);

    function setUp() public {
        _deployOptionsInfra();
        usdc = new MockUSDCPermit();

        dov = new PletherDOV("BEAR DOV", "bDOV", address(engine), address(stakedBear), address(usdc), false);

        engine.grantRole(engine.SERIES_CREATOR_ROLE(), address(dov));

        stakedBear.mint(address(dov), INITIAL_STAKED);
        usdc.mint(maker, 100_000e6);
        vm.prank(maker);
        usdc.approve(address(dov), type(uint256).max);
    }

    function test_FullLifecycle_RealContracts() public {
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
    }

    function test_FullLifecycle_WithExercise() public {
        uint256 dovBefore = stakedBear.balanceOf(address(dov));

        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        (uint256 seriesId, uint256 optionsMinted,,,,,) = dov.epochs(1);
        uint256 totalLocked = engine.totalSeriesShares(seriesId);

        vm.prank(maker);
        dov.fillAuction();

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        dov.settleEpoch(_buildHints());

        // Maker exercises all options
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
        assertGt(stakedBear.balanceOf(address(dov)), 0, "DOV should hold collateral after epoch 1");
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

}
