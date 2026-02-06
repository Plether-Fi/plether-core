// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DecimalConstants} from "../src/libraries/DecimalConstants.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoOracleTest is Test {

    MockOracle public basket;
    MorphoOracle public bearOracle;
    MorphoOracle public bullOracle;

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    function setUp() public {
        basket = new MockOracle(104_000_000, "Basket");
        bearOracle = new MorphoOracle(address(basket), CAP, false);
        bullOracle = new MorphoOracle(address(basket), CAP, true);
    }

    // ==========================================
    // 1. Scale Factor Pinned to Known Value
    // ==========================================
    function test_ScaleFactorMatchesMorphoSpec() public pure {
        assertEq(DecimalConstants.CHAINLINK_TO_MORPHO_SCALE, 1e16, "Scale should be 1e16");
    }

    // ==========================================
    // 2. plDXY-BEAR - Direct Token Logic
    // ==========================================
    function test_BearOracle_ReturnsBasketPrice() public view {
        uint256 price = bearOracle.price();
        // $1.04 in 24 decimals = 1.04e24
        assertEq(price, 1.04e24);
    }

    // ==========================================
    // 3. plDXY-BULL - Inverse Token Logic
    // ==========================================
    function test_BullOracle_ReturnsInvertedPrice() public view {
        uint256 price = bullOracle.price();
        // CAP($2.00) - Basket($1.04) = $0.96 in 24 decimals
        assertEq(price, 0.96e24);
    }

    function test_BullOracle_UpdatesDynamically() public {
        basket.updatePrice(50_000_000);
        uint256 price = bullOracle.price();
        // CAP($2.00) - Basket($0.50) = $1.50 in 24 decimals
        assertEq(price, 1.5e24);
    }

    // ==========================================
    // 4. Edge Cases
    // ==========================================
    function test_BullOracle_RevertsIfCapBreached() public {
        basket.updatePrice(210_000_000);

        vm.expectRevert(MorphoOracle.MorphoOracle__PriceExceedsCap.selector);
        bullOracle.price();
    }

    function test_Revert_IfBasketIsBroken() public {
        basket.updatePrice(0);

        vm.expectRevert(MorphoOracle.MorphoOracle__InvalidPrice.selector);
        bearOracle.price();
    }

}
