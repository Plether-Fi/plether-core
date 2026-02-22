// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "./MockOracle.sol";
import {MockOptionsSplitter, MockStakedTokenOptions} from "./OptionsMocks.sol";
import "forge-std/Test.sol";

abstract contract OptionsTestSetup is Test {

    uint256 constant CAP = 2e8;
    uint256 constant BEAR_PRICE = 106_000_000;
    uint256 constant BULL_PRICE = 94_000_000;
    uint256 constant ONE_SHARE = 1e21;

    MockOptionsSplitter public splitter;
    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;
    SettlementOracle public oracle;
    MockStakedTokenOptions public stakedBear;
    MockStakedTokenOptions public stakedBull;
    OptionToken public optionImpl;
    MarginEngine public engine;

    function _deployOptionsInfra() internal {
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

        engine = new MarginEngine(
            address(splitter), address(oracle), address(stakedBear), address(stakedBull), address(optionImpl)
        );
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

}
