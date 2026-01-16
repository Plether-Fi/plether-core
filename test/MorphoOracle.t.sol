// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoOracleTest is Test {

    MockOracle public basket; // The Source
    MorphoOracle public bearOracle;
    MorphoOracle public bullOracle;

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    function setUp() public {
        // 1. Deploy Mock Basket starting at $1.04
        basket = new MockOracle(104_000_000, "Basket");

        // 2. Deploy Bear Oracle (Standard)
        // isInverse = false
        bearOracle = new MorphoOracle(address(basket), CAP, false);

        // 3. Deploy Bull Oracle (Inverse)
        // isInverse = true
        bullOracle = new MorphoOracle(address(basket), CAP, true);
    }

    // ==========================================
    // 1. plDXY-BEAR - Direct Token Logic
    // ==========================================
    function test_BearOracle_ReturnsBasketPrice() public {
        // Basket = $1.04
        uint256 price = bearOracle.price();

        // Expected: 1.04 * 1e36
        // In code: 104_000_000 * 1e28
        uint256 expected = 104_000_000 * 1e28;

        assertEq(price, expected);
    }

    // ==========================================
    // 2. plDXY-BULL - Inverse Token Logic
    // ==========================================
    function test_BullOracle_ReturnsInvertedPrice() public {
        // Basket = $1.04
        // Cap = $2.00
        // Expected Value = $0.96

        uint256 price = bullOracle.price();

        uint256 expected = 96_000_000 * 1e28; // ($0.96 scaled)
        assertEq(price, expected);
    }

    function test_BullOracle_UpdatesDynamically() public {
        // Market Shock: Basket drops to $0.50 (Dollar Strong)
        basket.updatePrice(50_000_000);

        // Bull Token should go UP to $1.50 ($2.00 - $0.50)
        uint256 price = bullOracle.price();

        uint256 expected = 150_000_000 * 1e28;
        assertEq(price, expected);
    }

    // ==========================================
    // 3. Edge Cases
    // ==========================================
    function test_BullOracle_RevertsIfCapBreached() public {
        // Market Shock: Basket pumps to $2.10 (Dollar Crash)
        // Cap is $2.00.
        // Value would technically be -$0.10.
        // Oracle must revert to signal liquidation state.

        basket.updatePrice(210_000_000);

        vm.expectRevert(MorphoOracle.MorphoOracle__PriceExceedsCap.selector);
        bullOracle.price();
    }

    function test_Revert_IfBasketIsBroken() public {
        // Basket returns 0 or negative
        basket.updatePrice(0);

        vm.expectRevert(MorphoOracle.MorphoOracle__InvalidPrice.selector);
        bearOracle.price();
    }

}
