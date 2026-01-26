// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

// Mock Curve Pool for bound validation
contract MockCurvePool {

    uint256 public oraclePrice;

    constructor(
        uint256 _price
    ) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }

    function setPrice(
        uint256 _price
    ) external {
        oraclePrice = _price;
    }

}

// 2. The Test Suite
contract BasketOracleTest is Test {

    BasketOracle public basket;
    MockCurvePool public curvePool;

    MockOracle public feedEUR;
    MockOracle public feedJPY;

    // Base prices for normalization (8 decimals)
    uint256 constant BASE_EUR = 110_000_000; // $1.10
    uint256 constant BASE_JPY = 1_000_000; // $0.01

    function setUp() public {
        // 1. Deploy Shared Mocks
        // EUR = $1.21 (10% above base of $1.10) - intentionally ≠ base to catch formula bugs
        feedEUR = new MockOracle(121_000_000, "EUR/USD");
        // JPY = $0.01 (8 decimals)
        feedJPY = new MockOracle(1_000_000, "JPY/USD");

        // With normalized formula and 50/50 weights:
        // basket = 0.5 * (1.21/1.10) + 0.5 * (0.01/0.01) = 0.5 * 1.1 + 0.5 = 1.05
        // BEAR = basket = $1.05 (BEAR tracks basket directly)
        curvePool = new MockCurvePool(1.05 ether);

        address[] memory feeds = new address[](2);
        feeds[0] = address(feedEUR);
        feeds[1] = address(feedJPY);

        // Weights: 50% EUR, 50% JPY (sum to 1.0)
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0.5 ether; // 50%
        quantities[1] = 0.5 ether; // 50%

        // Base prices for normalization
        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = BASE_EUR;
        basePrices[1] = BASE_JPY;

        // 200 bps = 2% max deviation, CAP = $2.00
        basket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
        basket.setCurvePool(address(curvePool));
    }

    function test_Math_CalculatesCorrectSum() public {
        // Normalized formula: Sum(weight_i * price_i / basePrice_i)
        // = 0.5 * (121_000_000 / 110_000_000) + 0.5 * (1_000_000 / 1_000_000)
        // = 0.5 * 1.1 + 0.5 * 1.0
        // = 1.05

        (, int256 answer,,,) = basket.latestRoundData();

        // $1.05 in 8 decimals = 105,000,000
        assertEq(answer, 105_000_000);
    }

    function test_Math_UpdatesDynamically() public {
        // Shock: Euro crashes to $0.55 (50% drop from $1.10)
        feedEUR.updatePrice(55_000_000);

        // Normalized Math:
        // = 0.5 * (55_000_000 / 110_000_000) + 0.5 * (1_000_000 / 1_000_000)
        // = 0.5 * 0.5 + 0.5 * 1.0
        // = 0.25 + 0.50 = 0.75
        // BEAR = basket = $0.75 (BEAR tracks basket directly)

        // Update Curve price to match BEAR (within 2% threshold)
        curvePool.setPrice(0.75 ether);

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
        uint256[] memory basePrices = new uint256[](2);

        vm.expectRevert(BasketOracle.BasketOracle__LengthMismatch.selector);
        new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
    }

    function test_Components() public view {
        // Verify component access
        (AggregatorV3Interface feed, uint256 quantity, uint256 basePrice) = basket.components(0);
        assertEq(address(feed), address(feedEUR));
        assertEq(quantity, 0.5 ether);
        assertEq(basePrice, BASE_EUR);
    }

    function test_Revert_InvalidBasePrice() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 0; // Invalid: zero base price

        vm.expectRevert(BasketOracle.BasketOracle__InvalidBasePrice.selector);
        new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
    }

    function test_Revert_InvalidDecimals() public {
        // Create a mock oracle with wrong decimals
        MockOracleWrongDecimals wrongDecimalFeed = new MockOracleWrongDecimals(110_000_000, "BAD/USD");

        address[] memory feeds = new address[](1);
        feeds[0] = address(wrongDecimalFeed);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 110_000_000;

        vm.expectRevert(
            abi.encodeWithSelector(BasketOracle.BasketOracle__InvalidPrice.selector, address(wrongDecimalFeed))
        );
        new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
    }

    // ==========================================
    // BOUND VALIDATION TESTS
    // ==========================================

    function test_SetCurvePool_OnlyOwner() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xdead)));
        newBasket.setCurvePool(address(curvePool));
    }

    function test_SetCurvePool_OnlyOnce() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
        newBasket.setCurvePool(address(curvePool));

        vm.expectRevert(BasketOracle.BasketOracle__AlreadySet.selector);
        newBasket.setCurvePool(address(curvePool));
    }

    function test_SkipsDeviationCheck_WhenPoolNotSet() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));
        // Don't set curvePool - deviation check should be skipped
        // Normalized: 1.0 * (121_000_000 / 110_000_000) = 1.1 = 110_000_000
        (, int256 answer,,,) = newBasket.latestRoundData();
        assertEq(answer, 110_000_000);
    }

    function test_Revert_PriceDeviationExceedsThreshold() public {
        // basket = $1.05, BEAR = $1.05
        // Set Curve price 5% higher (1.1025 vs 1.05 = 5% deviation, exceeds 2% threshold)
        curvePool.setPrice(1.1025 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BasketOracle.BasketOracle__PriceDeviation.selector,
                1.05 ether, // theoreticalBear
                1.1025 ether // spotBear
            )
        );
        basket.latestRoundData();
    }

    function test_Success_PriceDeviationWithinThreshold() public {
        // basket = $1.05, BEAR = $1.05
        // Set Curve price 1% higher (1.0605 vs 1.05 = 1% deviation, within 2% threshold)
        curvePool.setPrice(1.0605 ether);

        (, int256 answer,,,) = basket.latestRoundData();
        assertEq(answer, 105_000_000);
    }

    function test_Revert_ZeroSpotPrice() public {
        curvePool.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(BasketOracle.BasketOracle__InvalidPrice.selector, address(curvePool)));
        basket.latestRoundData();
    }

    // ==========================================
    // CURVE POOL TIMELOCK TESTS
    // ==========================================

    function test_ProposeCurvePool_OnlyOwner() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xdead)));
        basket.proposeCurvePool(address(newPool));
    }

    function test_ProposeCurvePool_RevertsIfPoolNotSet() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));

        vm.expectRevert(BasketOracle.BasketOracle__InvalidProposal.selector);
        newBasket.proposeCurvePool(address(curvePool));
    }

    function test_ProposeCurvePool_SetsPendingAndActivationTime() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);

        basket.proposeCurvePool(address(newPool));

        assertEq(basket.pendingCurvePool(), address(newPool));
        assertEq(basket.curvePoolActivationTime(), block.timestamp + 7 days);
    }

    function test_ProposeCurvePool_EmitsEvent() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);

        vm.expectEmit(true, false, false, true);
        emit BasketOracle.CurvePoolProposed(address(newPool), block.timestamp + 7 days);

        basket.proposeCurvePool(address(newPool));
    }

    function test_FinalizeCurvePool_OnlyOwner() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);
        basket.proposeCurvePool(address(newPool));

        vm.warp(block.timestamp + 7 days);

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xdead)));
        basket.finalizeCurvePool();
    }

    function test_FinalizeCurvePool_RevertsIfNoPendingProposal() public {
        vm.expectRevert(BasketOracle.BasketOracle__InvalidProposal.selector);
        basket.finalizeCurvePool();
    }

    function test_FinalizeCurvePool_RevertsBeforeTimelock() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);
        basket.proposeCurvePool(address(newPool));

        vm.warp(block.timestamp + 6 days);

        vm.expectRevert(BasketOracle.BasketOracle__TimelockActive.selector);
        basket.finalizeCurvePool();
    }

    function test_FinalizeCurvePool_UpdatesPoolAfterTimelock() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);
        address oldPool = address(basket.curvePool());

        basket.proposeCurvePool(address(newPool));
        vm.warp(block.timestamp + 7 days);

        basket.finalizeCurvePool();

        assertEq(address(basket.curvePool()), address(newPool));
        assertEq(basket.pendingCurvePool(), address(0));
        assertTrue(address(basket.curvePool()) != oldPool);
    }

    function test_FinalizeCurvePool_EmitsEvent() public {
        MockCurvePool newPool = new MockCurvePool(0.95 ether);
        address oldPool = address(basket.curvePool());

        basket.proposeCurvePool(address(newPool));
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, false, false);
        emit BasketOracle.CurvePoolUpdated(oldPool, address(newPool));

        basket.finalizeCurvePool();
    }

    function test_SetCurvePool_EmitsEvent() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feedEUR);

        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1 ether;

        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        BasketOracle newBasket = new BasketOracle(feeds, quantities, basePrices, 200, 2e8, address(this));

        vm.expectEmit(true, true, false, false);
        emit BasketOracle.CurvePoolUpdated(address(0), address(curvePool));

        newBasket.setCurvePool(address(curvePool));
    }

    // ==========================================
    // TIMESTAMP TRACKING TESTS
    // ==========================================

    function test_UpdatedAt_ReturnsOldestTimestamp() public {
        vm.warp(10 hours);
        uint256 olderTimestamp = block.timestamp - 1 hours;
        uint256 newerTimestamp = block.timestamp;

        feedEUR.setUpdatedAt(newerTimestamp);
        feedJPY.setUpdatedAt(olderTimestamp);

        (,,, uint256 updatedAt,) = basket.latestRoundData();

        assertEq(updatedAt, olderTimestamp, "Should return oldest feed timestamp");
    }

    function test_UpdatedAt_ReturnsOldestWhenFirstFeedIsOlder() public {
        vm.warp(10 hours);
        uint256 olderTimestamp = block.timestamp - 2 hours;
        uint256 newerTimestamp = block.timestamp;

        feedEUR.setUpdatedAt(olderTimestamp);
        feedJPY.setUpdatedAt(newerTimestamp);

        (,,, uint256 updatedAt,) = basket.latestRoundData();

        assertEq(updatedAt, olderTimestamp, "Should return oldest feed timestamp");
    }

    // ==========================================
    // DEVIATION CHECK BRANCH COVERAGE
    // ==========================================

    function test_DeviationCheck_WhenTheoreticalGreaterThanSpot() public {
        // basket = $1.05, BEAR = $1.05
        // Set spot BELOW theoretical to exercise the first branch of the ternary
        // (theoreticalBear18 > spotBear18 ? theoreticalBear18 - spotBear18 : ...)
        curvePool.setPrice(1.04 ether); // spot < theoretical, within 2% threshold

        (, int256 answer,,,) = basket.latestRoundData();
        assertEq(answer, 105_000_000);
    }

    function test_DeviationCheck_RevertsWhenTheoreticalGreaterThanSpotExceedsThreshold() public {
        // basket = $1.05, BEAR = $1.05, set spot 5% lower to exceed 2% threshold
        curvePool.setPrice(0.9975 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BasketOracle.BasketOracle__PriceDeviation.selector,
                1.05 ether, // theoreticalBear
                0.9975 ether // spotBear
            )
        );
        basket.latestRoundData();
    }

    function test_DeviationCheck_RevertsWhenSpotIsDoubleTheoretical() public {
        // basket = $1.05, BEAR = $1.05, set spot to 2x theoretical
        // This catches modulo mutation: 2.1 % 1.05 = 0 (wrong) vs 2.1 - 1.05 = 1.05 (correct)
        curvePool.setPrice(2.1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BasketOracle.BasketOracle__PriceDeviation.selector,
                1.05 ether, // theoreticalBear
                2.1 ether // spotBear
            )
        );
        basket.latestRoundData();
    }

    function test_DeviationCheck_RevertsWhenSpotIsHalfTheoretical() public {
        // basket = $1.05, BEAR = $1.05, set spot to half theoretical
        // This catches modulo mutation in first branch
        curvePool.setPrice(0.525 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BasketOracle.BasketOracle__PriceDeviation.selector,
                1.05 ether, // theoreticalBear
                0.525 ether // spotBear
            )
        );
        basket.latestRoundData();
    }

    function test_DeviationCheck_PassesAtExactBoundary() public {
        // basket = $1.05, BEAR = $1.05, spot = $1.029 (2% below)
        // With MAX-based threshold: basePrice = 1.05, threshold = 0.021
        // diff = 0.021, diff == threshold -> PASS
        curvePool.setPrice(1.029 ether);
        basket.latestRoundData();
    }

    function test_DeviationCheck_RevertsWhenExceedingBoundary() public {
        // basket = $1.05, BEAR = $1.05, spot = $1.018 (>2% below)
        // With MAX-based threshold: basePrice = 1.05, threshold = 0.021
        // diff = 0.032, diff > threshold -> REVERT
        curvePool.setPrice(1.018 ether);

        vm.expectRevert(
            abi.encodeWithSelector(BasketOracle.BasketOracle__PriceDeviation.selector, 1.05 ether, 1.018 ether)
        );
        basket.latestRoundData();
    }

    function test_DeviationCheck_BearTracksBasketDirectly() public {
        // BEAR = basket (direct correlation), NOT CAP - basket
        // When USD weakens, foreign currencies become more expensive -> basket UP -> BEAR UP
        //
        // Setup: EUR rises 10% from $1.10 to $1.21 (USD weakened)
        feedEUR.updatePrice(121_000_000); // $1.21

        // New basket = 0.5 * (1.21/1.10) + 0.5 * (0.01/0.01) = 0.5 * 1.1 + 0.5 = 1.05
        // Correct: BEAR = basket = $1.05
        // Buggy:   BEAR = CAP - basket = $2.00 - $1.05 = $0.95

        // Set Curve to show correct BEAR price ($1.05)
        curvePool.setPrice(1.05 ether);

        // This should NOT revert - Curve correctly tracks basket
        // But buggy code calculates theoretical as $0.95, sees 10% deviation, and reverts
        (, int256 answer,,,) = basket.latestRoundData();
        assertEq(answer, 105_000_000, "Basket should be $1.05");
    }

}

// Helper mock with wrong decimals (6 instead of 8)
contract MockOracleWrongDecimals {

    int256 public price;
    string public description;

    constructor(
        int256 _price,
        string memory _description
    ) {
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
