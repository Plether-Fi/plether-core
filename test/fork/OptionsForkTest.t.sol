// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import "forge-std/Test.sol";

/// @notice Mock SEK/USD feed (no mainnet Chainlink feed available)
contract MockSEKFeedOptions is AggregatorV3Interface {

    int256 private _price;
    uint256 private _updatedAt;

    constructor(
        int256 price_
    ) {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function setPrice(
        int256 newPrice
    ) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "SEK / USD (Mock)";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

}

/// @notice Mock Curve pool for BasketOracle comparison
contract MockCurvePoolForOptions {

    uint256 public oraclePrice;

    constructor(
        uint256 _price
    ) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }

}

/// @title Options Fork Test — SettlementOracle with real Chainlink feeds
contract OptionsForkTest is Test {

    address constant CL_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    address constant CL_JPY_USD = 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3;
    address constant CL_GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address constant CL_CAD_USD = 0xa34317DB73e77d453b1B8d04550c44D10e981C8e;
    address constant CL_CHF_USD = 0x449d117117838fFA61263B61dA6301AA2a88B13A;

    uint256 constant WEIGHT_EUR = 576e15;
    uint256 constant WEIGHT_JPY = 136e15;
    uint256 constant WEIGHT_GBP = 119e15;
    uint256 constant WEIGHT_CAD = 91e15;
    uint256 constant WEIGHT_SEK = 42e15;
    uint256 constant WEIGHT_CHF = 36e15;

    uint256 constant BASE_EUR = 108_000_000;
    uint256 constant BASE_JPY = 670_000;
    uint256 constant BASE_GBP = 126_000_000;
    uint256 constant BASE_CAD = 74_000_000;
    uint256 constant BASE_SEK = 9_500_000;
    uint256 constant BASE_CHF = 112_000_000;

    uint256 constant CAP = 2e8;
    uint256 constant FORK_BLOCK = 24_136_062;

    SettlementOracle public settlementOracle;
    MockSEKFeedOptions public sekFeed;

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, FORK_BLOCK);
        } catch {
            revert("Missing MAINNET_RPC_URL");
        }

        // Warp past the oldest feed's updatedAt + sequencer grace period
        (,,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR_USD).latestRoundData();
        uint256 target = updatedAt + 1 hours;
        if (target < block.timestamp) {
            target = block.timestamp;
        }
        vm.warp(target);

        sekFeed = new MockSEKFeedOptions(int256(BASE_SEK));

        address[] memory feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        uint256[] memory basePrices = new uint256[](6);
        basePrices[0] = BASE_EUR;
        basePrices[1] = BASE_JPY;
        basePrices[2] = BASE_GBP;
        basePrices[3] = BASE_CAD;
        basePrices[4] = BASE_SEK;
        basePrices[5] = BASE_CHF;

        settlementOracle = new SettlementOracle(feeds, quantities, basePrices, CAP, address(0));
    }

    function test_SettlementOracle_ReturnsRealisticPrices() public view {
        (uint256 bear, uint256 bull) = settlementOracle.getSettlementPrices();

        assertGt(bear, 80_000_000, "bearPrice should be > $0.80");
        assertLt(bear, 120_000_000, "bearPrice should be < $1.20");
        assertGt(bull, 80_000_000, "bullPrice should be > $0.80");
        assertLt(bull, 120_000_000, "bullPrice should be < $1.20");
    }

    function test_SettlementOracle_BearPlusBullEqualsCAP() public view {
        (uint256 bear, uint256 bull) = settlementOracle.getSettlementPrices();
        assertEq(bear + bull, CAP, "bear + bull must equal CAP");
    }

    function test_SettlementOracle_MatchesBasketOracle() public {
        // Deploy BasketOracle with same params
        address[] memory feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        uint256[] memory basePrices = new uint256[](6);
        basePrices[0] = BASE_EUR;
        basePrices[1] = BASE_JPY;
        basePrices[2] = BASE_GBP;
        basePrices[3] = BASE_CAD;
        basePrices[4] = BASE_SEK;
        basePrices[5] = BASE_CHF;

        BasketOracle basket = new BasketOracle(feeds, quantities, basePrices, 500, address(this));

        // BasketOracle needs a Curve pool — use aligned price so deviation check passes
        (uint256 bear,) = settlementOracle.getSettlementPrices();
        uint256 bearPrice18 = bear * 1e10;
        MockCurvePoolForOptions pool = new MockCurvePoolForOptions(bearPrice18);
        basket.setCurvePool(address(pool));

        (, int256 basketPrice,,,) = basket.latestRoundData();

        // SettlementOracle strips Curve deviation check but uses same basket math
        assertEq(bear, uint256(basketPrice), "settlement oracle should match basket oracle");
    }

    function test_SettlementOracle_StaleAfter24Hours() public {
        // Warp 25 hours
        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        settlementOracle.getSettlementPrices();
    }

}
