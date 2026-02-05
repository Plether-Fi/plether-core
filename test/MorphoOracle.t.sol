// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoOracleTest is Test {

    MockOracle public basket;
    MorphoOracle public bearOracle;
    MorphoOracle public bullOracle;

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    uint256 constant COLLATERAL_DECIMALS = 18; // plDXY tokens
    uint256 constant LOAN_DECIMALS = 6; // USDC
    uint256 constant CHAINLINK_DECIMALS = 8;
    uint256 constant ORACLE_PRICE_SCALE = 1e36; // Morpho's divisor

    // Morpho spec: precision = 36 + loanDec - collateralDec = 24
    // Scale from Chainlink 8-dec: 10^(24 - 8) = 10^16
    uint256 constant SCALE = 10 ** (36 + LOAN_DECIMALS - COLLATERAL_DECIMALS - CHAINLINK_DECIMALS);

    function setUp() public {
        basket = new MockOracle(104_000_000, "Basket");
        bearOracle = new MorphoOracle(address(basket), CAP, false);
        bullOracle = new MorphoOracle(address(basket), CAP, true);
    }

    // ==========================================
    // 1. plDXY-BEAR - Direct Token Logic
    // ==========================================
    function test_BearOracle_ReturnsBasketPrice() public view {
        uint256 price = bearOracle.price();

        // Morpho requires: 36 + loanDec - collateralDec = 36 + 6 - 18 = 24 decimals of precision
        // $1.04 in 24 decimals = 1.04e24
        // From Chainlink 8-dec: 104_000_000 * SCALE
        uint256 expected = 104_000_000 * SCALE;
        assertEq(price, expected);
        assertEq(price, 1.04e24);
    }

    // ==========================================
    // 2. plDXY-BULL - Inverse Token Logic
    // ==========================================
    function test_BullOracle_ReturnsInvertedPrice() public view {
        uint256 price = bullOracle.price();

        // CAP($2.00) - Basket($1.04) = $0.96 in 24 decimals
        uint256 expected = 96_000_000 * SCALE;
        assertEq(price, expected);
        assertEq(price, 0.96e24);
    }

    function test_BullOracle_UpdatesDynamically() public {
        basket.updatePrice(50_000_000);

        uint256 price = bullOracle.price();

        // CAP($2.00) - Basket($0.50) = $1.50 in 24 decimals
        uint256 expected = 150_000_000 * SCALE;
        assertEq(price, expected);
        assertEq(price, 1.5e24);
    }

    // ==========================================
    // 3. Edge Cases
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

    // ==========================================
    // 4. Morpho Integration Sanity
    // ==========================================
    function test_BearOracle_MorphoHealthCheck() public view {
        // Verify oracle price produces correct maxBorrow when used in Morpho's formula:
        //   maxBorrow = collateral * oraclePrice / ORACLE_PRICE_SCALE * lltv
        //
        // 1 plDXY-BEAR token ($1.04) as collateral, LLTV = 86%
        uint256 collateral = 1e18; // 1 token (18 decimals)
        uint256 lltv = 0.86e18;
        uint256 oraclePrice = bearOracle.price();

        uint256 maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * lltv / 1e18;

        // 1 token * $1.04 * 86% = ~$0.8944 USDC = ~894_400 in 6-dec
        assertApproxEqAbs(maxBorrow, 894_400, 100);
    }

    function test_BullOracle_MorphoHealthCheck() public view {
        uint256 collateral = 1e18;
        uint256 lltv = 0.86e18;
        uint256 oraclePrice = bullOracle.price();

        uint256 maxBorrow = (collateral * oraclePrice / ORACLE_PRICE_SCALE) * lltv / 1e18;

        // 1 token * $0.96 * 86% = ~$0.8256 USDC = ~825_600 in 6-dec
        assertApproxEqAbs(maxBorrow, 825_600, 100);
    }

    function test_ScaleFactorMatchesMorphoSpec() public pure {
        // Morpho spec: precision = 36 + loan_decimals - collateral_decimals
        uint256 requiredPrecision = 36 + LOAN_DECIMALS - COLLATERAL_DECIMALS; // = 24
        uint256 chainlinkDecimals = 8;

        // Scale converts Chainlink 8-dec to required precision
        uint256 expectedScale = 10 ** (requiredPrecision - chainlinkDecimals); // 10^16
        assertEq(SCALE, expectedScale);
    }

}
