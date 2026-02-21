// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {PletherDOV} from "../../src/options/PletherDOV.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {MockUSDCPermit} from "../utils/MockUSDCPermit.sol";
import {MockOptionsSplitter, MockStakedTokenOptions} from "../utils/OptionsMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title PletherDOV Integration — real MarginEngine, SettlementOracle, OptionToken
contract PletherDOVIntegrationTest is Test {

    uint256 constant CAP = 2e8;
    uint256 constant BEAR_PRICE = 106_000_000;
    uint256 constant INITIAL_STAKED = 1000e21;

    MockOptionsSplitter public splitter;
    SettlementOracle public oracle;
    MockStakedTokenOptions public stakedBear;
    MockStakedTokenOptions public stakedBull;
    OptionToken public optionImpl;
    MarginEngine public engine;
    MockUSDCPermit public usdc;
    PletherDOV public dov;

    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;

    address maker = address(0x2);

    function setUp() public {
        vm.warp(1_735_689_600);

        splitter = new MockOptionsSplitter();

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
        usdc = new MockUSDCPermit();

        engine = new MarginEngine(
            address(splitter), address(oracle), address(stakedBear), address(stakedBull), address(optionImpl)
        );

        dov = new PletherDOV("BEAR DOV", "bDOV", address(engine), address(stakedBear), address(usdc), false);

        engine.grantRole(engine.SERIES_CREATOR_ROLE(), address(dov));

        stakedBear.mint(address(dov), INITIAL_STAKED);
        usdc.mint(maker, 100_000e6);
        vm.prank(maker);
        usdc.approve(address(dov), type(uint256).max);
    }

    function _refreshFeeds() internal {
        eurFeed.updatePrice(118_800_000);
        jpyFeed.updatePrice(670_000);
    }

    function _buildHints() internal view returns (uint80[] memory hints) {
        hints = new uint80[](2);
        (hints[0],,,,) = eurFeed.latestRoundData();
        (hints[1],,,,) = jpyFeed.latestRoundData();
    }

    function test_FullLifecycle_RealContracts() public {
        dov.startEpochAuction(90e6, block.timestamp + 7 days, 1e6, 100_000, 1 hours);

        (, uint256 optionsMinted,,,,,) = dov.epochs(1);
        assertGt(optionsMinted, 0, "options minted");

        vm.prank(maker);
        dov.fillAuction();

        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();

        dov.settleEpoch(_buildHints());

        assertEq(uint256(dov.currentState()), uint256(PletherDOV.State.UNLOCKED));
        uint256 dovBalance = stakedBear.balanceOf(address(dov));
        assertGt(dovBalance, 0, "DOV should hold residual collateral");
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
