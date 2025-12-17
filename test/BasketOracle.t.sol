// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/BasketOracle.sol";
import "./utils/MockOracle.sol";

// 2. The Test Suite
contract BasketOracleTest is Test {
    BasketOracle public basket;
    
    MockOracle public feedEUR;
    MockOracle public feedJPY;

    function setUp() public {
        // 1. Deploy Shared Mocks
        // EUR = $1.10 (8 decimals)
        feedEUR = new MockOracle(110_000_000, "EUR/USD"); 
        // JPY = $0.01 (8 decimals)
        feedJPY = new MockOracle(1_000_000, "JPY/USD");

        address[] memory feeds = new address[](2);
        feeds[0] = address(feedEUR);
        feeds[1] = address(feedJPY);

        // Quantities (18 decimals)
        // Basket = "0.5 Euro + 50 Yen"
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0.5 ether; // 0.5 units
        quantities[1] = 50 ether;  // 50 units

        basket = new BasketOracle(feeds, quantities);
    }

    function test_Initialization() public {
        assertEq(basket.decimals(), 8);
        assertEq(basket.description(), "DXY Fixed Basket");
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
        // = $0.75

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
        new BasketOracle(feeds, quantities);
    }
}