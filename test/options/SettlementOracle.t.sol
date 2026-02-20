// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import "forge-std/Test.sol";

contract SettlementOracleTest is Test {

    uint256 constant CAP = 2e8;

    // EUR: price $1.188 (118_800_000), base $1.08 (108_000_000), weight 60%
    // JPY: price $0.0067 (670_000), base $0.0067 (670_000), weight 40%
    //
    // Hand-calculated basket:
    //   EUR component = (118_800_000 * 6e17) / (108_000_000 * 1e10) = 66_000_000
    //   JPY component = (670_000 * 4e17) / (670_000 * 1e10)         = 40_000_000
    //   bearPrice = 106_000_000  ($1.06)
    //   bullPrice = 94_000_000   ($0.94)
    uint256 constant EXPECTED_BEAR = 106_000_000;
    uint256 constant EXPECTED_BULL = 94_000_000;

    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;
    SettlementOracle public oracle;

    function setUp() public {
        vm.warp(1_735_689_600);

        // Sequencer UP (answer=0)
        sequencerFeed = new MockOracle(0, "Sequencer");

        // Warp past grace period (1 hour)
        vm.warp(block.timestamp + 2 hours);

        eurFeed = new MockOracle(118_800_000, "EUR/USD");
        jpyFeed = new MockOracle(670_000, "JPY/USD");

        oracle = _deployOracle(address(sequencerFeed));
    }

    function _buildHints() internal view returns (uint80[] memory hints) {
        hints = new uint80[](2);
        (hints[0],,,,) = eurFeed.latestRoundData();
        (hints[1],,,,) = jpyFeed.latestRoundData();
    }

    function _deployOracle(
        address _sequencer
    ) internal returns (SettlementOracle) {
        address[] memory feeds = new address[](2);
        feeds[0] = address(eurFeed);
        feeds[1] = address(jpyFeed);

        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 600_000_000_000_000_000; // 60%
        quantities[1] = 400_000_000_000_000_000; // 40%

        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = 108_000_000;
        basePrices[1] = 670_000;

        return new SettlementOracle(feeds, quantities, basePrices, CAP, _sequencer);
    }

    // ==========================================
    // CONSTRUCTOR
    // ==========================================

    function test_Constructor_StoresComponentsAndCAP() public view {
        assertEq(oracle.CAP(), CAP);
        (AggregatorV3Interface feed0, uint256 q0, uint256 bp0) = oracle.components(0);
        assertEq(address(feed0), address(eurFeed));
        assertEq(q0, 600_000_000_000_000_000);
        assertEq(bp0, 108_000_000);
    }

    function test_Constructor_RevertsOnLengthMismatch() public {
        address[] memory feeds = new address[](2);
        feeds[0] = address(eurFeed);
        feeds[1] = address(jpyFeed);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;

        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = 108_000_000;
        basePrices[1] = 670_000;

        vm.expectRevert(SettlementOracle.SettlementOracle__LengthMismatch.selector);
        new SettlementOracle(feeds, quantities, basePrices, CAP, address(0));
    }

    function test_Constructor_RevertsOnZeroBasePrice() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(eurFeed);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 0;

        vm.expectRevert(SettlementOracle.SettlementOracle__InvalidBasePrice.selector);
        new SettlementOracle(feeds, quantities, basePrices, CAP, address(0));
    }

    function test_Constructor_RevertsOnWeightsNotSummingTo1e18() public {
        address[] memory feeds = new address[](2);
        feeds[0] = address(eurFeed);
        feeds[1] = address(jpyFeed);

        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 500_000_000_000_000_000; // 50%
        quantities[1] = 400_000_000_000_000_000; // 40% — total 90%

        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = 108_000_000;
        basePrices[1] = 670_000;

        vm.expectRevert(SettlementOracle.SettlementOracle__InvalidWeights.selector);
        new SettlementOracle(feeds, quantities, basePrices, CAP, address(0));
    }

    // ==========================================
    // getSettlementPrices
    // ==========================================

    function test_GetSettlementPrices_CorrectBasketCalculation() public view {
        (uint256 bear, uint256 bull) = oracle.getSettlementPrices(block.timestamp, _buildHints());
        assertEq(bear, EXPECTED_BEAR, "bearPrice should be $1.06");
        assertEq(bull, EXPECTED_BULL, "bullPrice should be $0.94");
    }

    function test_GetSettlementPrices_BearClampedToCAP() public {
        eurFeed.updatePrice(500_000_000); // $5.00 → basket >> CAP
        (uint256 bear, uint256 bull) = oracle.getSettlementPrices(block.timestamp, _buildHints());
        assertEq(bear, CAP);
        assertEq(bull, 0);
    }

    function test_GetSettlementPrices_BullZeroWhenBearAtCAP() public {
        eurFeed.updatePrice(500_000_000);
        (, uint256 bull) = oracle.getSettlementPrices(block.timestamp, _buildHints());
        assertEq(bull, 0);
    }

    function test_GetSettlementPrices_RevertsWhenSequencerDown() public {
        uint80[] memory hints = _buildHints();
        sequencerFeed.updatePrice(1); // answer=1 → DOWN
        vm.expectRevert(OracleLib.OracleLib__SequencerDown.selector);
        oracle.getSettlementPrices(block.timestamp, hints);
    }

    function test_GetSettlementPrices_RevertsInGracePeriod() public {
        uint80[] memory hints = _buildHints();
        sequencerFeed.setUpdatedAt(block.timestamp); // just came back up
        vm.expectRevert(OracleLib.OracleLib__SequencerGracePeriod.selector);
        oracle.getSettlementPrices(block.timestamp, hints);
    }

    function test_GetSettlementPrices_RevertsOnStaleFeed() public {
        uint80[] memory hints = _buildHints();
        eurFeed.setUpdatedAt(block.timestamp - 25 hours);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        oracle.getSettlementPrices(block.timestamp, hints);
    }

    function test_GetSettlementPrices_RevertsOnZeroPrice() public {
        uint80[] memory hints = _buildHints();
        eurFeed.updatePrice(0);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.SettlementOracle__InvalidPrice.selector, address(eurFeed))
        );
        oracle.getSettlementPrices(block.timestamp, hints);
    }

    function test_GetSettlementPrices_RevertsOnNegativePrice() public {
        uint80[] memory hints = _buildHints();
        eurFeed.updatePrice(-1);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.SettlementOracle__InvalidPrice.selector, address(eurFeed))
        );
        oracle.getSettlementPrices(block.timestamp, hints);
    }

    function test_GetSettlementPrices_SkipsSequencerWhenZeroAddress() public {
        SettlementOracle noSeq = _deployOracle(address(0));
        (uint256 bear, uint256 bull) = noSeq.getSettlementPrices(block.timestamp, _buildHints());
        assertEq(bear, EXPECTED_BEAR);
        assertEq(bull, EXPECTED_BULL);
    }

    function test_GetSettlementPrices_RevertsOnWrongHintCount() public {
        uint80[] memory badHints = new uint80[](1);
        badHints[0] = 1;

        vm.expectRevert(SettlementOracle.SettlementOracle__WrongHintCount.selector);
        oracle.getSettlementPrices(block.timestamp, badHints);
    }

    function test_GetSettlementPrices_RevertsOnFutureHint() public {
        vm.warp(block.timestamp + 1 hours);
        eurFeed.updatePrice(118_800_000);
        jpyFeed.updatePrice(670_000);

        uint256 expiry = block.timestamp - 1 hours;
        uint80[] memory hints = _buildHints(); // latest rounds are AFTER expiry

        vm.expectRevert(OracleLib.OracleLib__NoPriceAtExpiry.selector);
        oracle.getSettlementPrices(expiry, hints);
    }

    // ==========================================
    // HISTORICAL PRICE LOOKUP
    // ==========================================

    function test_GetSettlementPrices_UsesHistoricalPriceAtExpiry() public {
        // Warp forward and update prices — creates round 2 at new timestamp
        vm.warp(block.timestamp + 1 hours);
        eurFeed.updatePrice(130_000_000); // $1.30
        jpyFeed.updatePrice(800_000); // $0.008

        // Query at pre-warp time — hint round 1 (initial prices, before warp)
        uint256 expiry = block.timestamp - 1 hours;
        uint80[] memory hints = new uint80[](2);
        hints[0] = 1; // round 1 for EUR (created in setUp)
        hints[1] = 1; // round 1 for JPY (created in setUp)
        (uint256 bear, uint256 bull) = oracle.getSettlementPrices(expiry, hints);
        assertEq(bear, EXPECTED_BEAR, "should use historical EUR price");
        assertEq(bull, EXPECTED_BULL, "should use historical JPY price");
    }

    function test_GetSettlementPrices_RevertsWhenNoHistoricalPriceFound() public {
        uint256 expiryBeforeAnyRound = 1000;

        // Round 1's updatedAt is after expiry=1000, so hint validation fails
        uint80[] memory hints = new uint80[](2);
        hints[0] = 1;
        hints[1] = 1;

        vm.expectRevert(OracleLib.OracleLib__NoPriceAtExpiry.selector);
        oracle.getSettlementPrices(expiryBeforeAnyRound, hints);
    }

    // ==========================================
    // FUZZ
    // ==========================================

    function testFuzz_BearPlusBullEqualsCAP(
        uint256 eurPrice,
        uint256 jpyPrice
    ) public {
        eurPrice = bound(eurPrice, 1, 500_000_000);
        jpyPrice = bound(jpyPrice, 1, 5_000_000);

        eurFeed.updatePrice(int256(eurPrice));
        jpyFeed.updatePrice(int256(jpyPrice));

        (uint256 bear, uint256 bull) = oracle.getSettlementPrices(block.timestamp, _buildHints());
        assertEq(bear + bull, CAP, "bear + bull must equal CAP");
    }

    function testFuzz_BearNeverExceedsCAP(
        uint256 eurPrice,
        uint256 jpyPrice
    ) public {
        eurPrice = bound(eurPrice, 1, 500_000_000);
        jpyPrice = bound(jpyPrice, 1, 5_000_000);

        eurFeed.updatePrice(int256(eurPrice));
        jpyFeed.updatePrice(int256(jpyPrice));

        (uint256 bear,) = oracle.getSettlementPrices(block.timestamp, _buildHints());
        assertLe(bear, CAP, "bear must not exceed CAP");
    }

}
