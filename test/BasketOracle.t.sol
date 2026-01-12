// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/oracles/BasketOracle.sol";
import "./utils/MockOracle.sol";

// Mock Curve Pool for bound validation
contract MockCurvePool {
    uint256 public oraclePrice;

    constructor(uint256 _price) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }

    function setPrice(uint256 _price) external {
        oraclePrice = _price;
    }
}

// 2. The Test Suite
contract BasketOracleTest is Test {
    BasketOracle public basket;
    MockCurvePool public curvePool;

    MockOracle public feedEUR;
    MockOracle public feedJPY;

    function setUp() public {
        // 1. Deploy Shared Mocks
        // EUR = $1.10 (8 decimals)
        feedEUR = new MockOracle(110_000_000, "EUR/USD");
        // JPY = $0.01 (8 decimals)
        feedJPY = new MockOracle(1_000_000, "JPY/USD");

        // Expected basket price (DXY) = $1.05 (8 dec) = 105_000_000
        // DXY-BEAR = CAP - DXY = $2.00 - $1.05 = $0.95
        // Mock Curve pool returns DXY-BEAR price in 18 decimals
        curvePool = new MockCurvePool(0.95 ether);

        address[] memory feeds = new address[](2);
        feeds[0] = address(feedEUR);
        feeds[1] = address(feedJPY);

        // Quantities (18 decimals)
        // Basket = "0.5 Euro + 50 Yen"
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0.5 ether; // 0.5 units
        quantities[1] = 50 ether; // 50 units

        // 200 bps = 2% max deviation, CAP = $2.00
        basket = new BasketOracle(feeds, quantities, 200, 2e8, address(this));
        basket.setCurvePool(address(curvePool));
    }

    function test_Math_CalculatesCorrectSum() public {
        // Expected Math:
        // (PriceEUR * QtyEUR) + (PriceJPY * QtyJPY)
        // ($1.10 * 0.5) + ($0.01 * 50)
        // $0.55 + $0.50
        // = $1.05

        (, int256 answer,,,) = basket.latestRoundData();

        // $1.05 in 8 decimals = 105,000,000
        assertEq(answer, 105_000_000);
    }

    function test_Math_UpdatesDynamically() public {
        // Shock: Euro crashes to $0.50
        feedEUR.updatePrice(50_000_000);

        // New Math:
        // ($0.50 * 0.5) + ($0.01 * 50)
        // $0.25 + $0.50
        // = $0.75 DXY
        // DXY-BEAR = CAP - DXY = $2.00 - $0.75 = $1.25

        // Update Curve price to match DXY-BEAR (within 2% threshold)
        curvePool.setPrice(1.25 ether);

        (, int256 answer,,,) = basket.latestRoundData();
        assertEq(answer, 75_000_000);
    }

    function test_Revert_IfComponentInvalid() public {
        // Chainlink feed breaks (returns 0)
        feedEUR.updatePrice(0);

        // Basket should revert to protect the protocol
        vm.expectRevert(abi.encodeWithSelector(BasketOracle.BasketOracle__InvalidPrice.selector, address(feedEUR)));
        basket.latestRoundData();
    }

    function test_Revert_LengthMismatch() public {
        address[] memory feeds = new address[](1);
        uint256[] memory quantities = new uint256[](2);

        vm.expectRevert(BasketOracle.BasketOracle__LengthMismatch.selector);
        new BasketOracle(feeds, quantities, 200, 2e8, address(this));
    }

    function test_Components() public view {
        // Verify component access
        (AggregatorV3Interface feed, uint256 quantity) = basket.components(0);
        assertEq(address(feed), address(feedEUR));
        assertEq(quantity, 0.5 ether);
    }

    function test_Revert_InvalidDecimals() public {
        // Create a mock oracle with wrong decimals
        MockOracleWrongDecimals wrongDecimalFeed = new MockOracleWrongDecimals(110_000_000, "BAD/USD");

        address[] memory feeds = new address[](1);
        feeds[0] = address(wrongDecimalFeed);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(BasketOracle.BasketOracle__InvalidPrice.selector, address(wrongDecimalFeed))
        );
        new BasketOracle(feeds, quantities, 200, 2e8, address(this));
    }

    // ==========================================
    // BOUND VALIDATION TESTS
    // ==========================================

    function test_SetCurvePool_OnlyOwner() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, 200, 2e8, address(this));

        vm.prank(address(0xdead));
        vm.expectRevert(BasketOracle.BasketOracle__Unauthorized.selector);
        newBasket.setCurvePool(address(curvePool));
    }

    function test_SetCurvePool_OnlyOnce() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, 200, 2e8, address(this));
        newBasket.setCurvePool(address(curvePool));

        vm.expectRevert(BasketOracle.BasketOracle__AlreadySet.selector);
        newBasket.setCurvePool(address(curvePool));
    }

    function test_SkipsDeviationCheck_WhenPoolNotSet() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, 200, 2e8, address(this));
        // Don't set curvePool - deviation check should be skipped
        (, int256 answer,,,) = newBasket.latestRoundData();
        assertEq(answer, 110_000_000); // EUR price
    }

    function test_Revert_PriceDeviationExceedsThreshold() public {
        // DXY = $1.05, CAP = $2.00, so theoreticalBear = $0.95
        // Set Curve price 5% higher (0.9975 vs 0.95 = ~5% deviation, exceeds 2% threshold)
        curvePool.setPrice(0.9975 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BasketOracle.BasketOracle__PriceDeviation.selector,
                0.95 ether, // theoreticalBear (CAP - DXY scaled to 18 dec)
                0.9975 ether // spotBear
            )
        );
        basket.latestRoundData();
    }

    function test_Success_PriceDeviationWithinThreshold() public {
        // DXY = $1.05, CAP = $2.00, so theoreticalBear = $0.95
        // Set Curve price 1% higher (0.9595 vs 0.95 = ~1% deviation, within 2% threshold)
        curvePool.setPrice(0.9595 ether);

        (, int256 answer,,,) = basket.latestRoundData();
        assertEq(answer, 105_000_000);
    }

    function test_Revert_ZeroSpotPrice() public {
        curvePool.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(BasketOracle.BasketOracle__InvalidPrice.selector, address(curvePool)));
        basket.latestRoundData();
    }
}

// Helper mock with wrong decimals (6 instead of 8)
contract MockOracleWrongDecimals {
    int256 public price;
    string public description;

    constructor(int256 _price, string memory _description) {
        price = _price;
        description = _description;
    }

    function decimals() external pure returns (uint8) {
        return 6; // Wrong! Should be 8
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
