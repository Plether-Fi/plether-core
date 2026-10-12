// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OracleMathPolicyFixture, PletherOracleMathHarness} from "../../shared/PletherOracleMathHarness.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract NormalizePythFuzzTest is Test {

    PletherOracleMathHarness internal oracle;

    function setUp() public {
        oracle = new PletherOracleMathHarness(address(new OracleMathPolicyFixture()), address(new MockPyth()));
    }

    function test_NormalizationKnownDecimalVectors() public view {
        assertEq(oracle.normalizePythPrice(12, -1), 120_000_000);
        assertEq(oracle.normalizePythPrice(120_000_000, -8), 120_000_000);
        assertEq(oracle.normalizePythPrice(1_234_567_890, -9), 123_456_789);
        assertEq(oracle.normalizePythPrice(1_234_567_899, -9), 123_456_789, "discard sub-atom remainder");
        assertEq(oracle.normalizePythPrice(9_999_999_999, -18), 0);
        assertEq(oracle.normalizePythPrice(10_000_000_000, -18), 1);
        assertEq(oracle.normalizePythPrice(12, 0), 1_200_000_000);
        assertEq(oracle.normalizePythPrice(12, 2), 120_000_000_000);
        assertEq(oracle.normalizePythPrice(1, 18), 1e26);
    }

    function test_InversionKnownDecimalAndRoundingVectors() public view {
        // Decimal reciprocals: 1 / 0.8 = 1.25; 1 / 1.25 = 0.8; 1 / 156.7 = 0.0063816209...
        assertEq(oracle.invertPythPrice(8, -1), 125_000_000);
        assertEq(oracle.invertPythPrice(125, -2), 80_000_000);
        assertEq(oracle.invertPythPrice(156_700, -3), 638_162);
        assertEq(oracle.invertPythPrice(3, 0), 33_333_333);
        assertEq(oracle.invertPythPrice(7, 0), 14_285_714);
        assertEq(oracle.invertPythPrice(1, -18), 1e26);
        assertEq(oracle.invertPythPrice(1, 18), 0);

        // Round the reciprocal at 26 decimals before truncation to eight. The first value lies
        // within half a 26-decimal unit below 0.00000002; its immediate neighbor lies outside it.
        assertEq(oracle.invertPythPrice(5_000_000_000_000_000_001, -11), 2);
        assertEq(oracle.invertPythPrice(5_000_000_000_000_000_002, -11), 1);
    }

    function testFuzz_NormalizationSatisfiesExactDecimalFloor(
        uint64 rawPrice,
        int32 exponent
    ) public view {
        int64 price = int64(uint64(bound(rawPrice, 1, uint64(type(int64).max))));
        exponent = int32(bound(int256(exponent), -18, 18));
        (uint256 numerator, uint256 denominator) = _decimalRatio(price, exponent);
        uint256 result = oracle.normalizePythPrice(price, exponent);
        // Rational inequalities specify floor rounding without repeating the production exponent branches.
        assertLe(result * denominator, numerator * 1e8);
        assertGt((result + 1) * denominator, numerator * 1e8);
    }

    function testFuzz_InversionSatisfiesReciprocalRoundingInterval(
        uint64 rawPrice,
        int32 exponent
    ) public view {
        int64 price = int64(uint64(bound(rawPrice, 1, uint64(type(int64).max))));
        exponent = int32(bound(int256(exponent), -18, 18));
        (uint256 numerator, uint256 denominator) = _decimalRatio(price, exponent);
        uint256 result = oracle.invertPythPrice(price, exponent);
        // Reciprocal in eight-decimal units is (1e8 * denominator) / numerator. Rounding to the
        // nearest 26-decimal unit permits half of 1e-18 output atoms before the final floor.
        uint256 twiceScaledReciprocal = 2 * 1e18 * 1e8 * denominator;
        assertLe(2 * 1e18 * result * numerator, twiceScaledReciprocal + numerator);
        assertGt(2 * 1e18 * (result + 1) * numerator, twiceScaledReciprocal + numerator);
    }

    function testFuzz_EquivalentDecimalRepresentationsPreserveBothPrices(
        uint64 rawPrice,
        int32 exponent
    ) public view {
        int64 price = int64(uint64(bound(rawPrice, 1, uint64(type(int64).max) / 10)));
        exponent = int32(bound(int256(exponent), -17, 18));
        assertEq(oracle.normalizePythPrice(price, exponent), oracle.normalizePythPrice(price * 10, exponent - 1));
        assertEq(oracle.invertPythPrice(price, exponent), oracle.invertPythPrice(price * 10, exponent - 1));
    }

    function test_ZeroPricesAreRejectedByBothHelpers() public {
        _assertInvalidPrice(0);
    }

    function testFuzz_NegativePricesAreRejectedByBothHelpers(
        int64 price
    ) public {
        price = int64(bound(int256(price), type(int64).min, -1));
        _assertInvalidPrice(price);
    }

    function _assertInvalidPrice(
        int64 price
    ) private {
        bytes memory expected =
            abi.encodeWithSelector(IPletherOracle.PletherOracle__InvalidPrice.selector, bytes32(0), price);
        vm.expectRevert(expected);
        oracle.normalizePythPrice(price, -8);
        vm.expectRevert(expected);
        oracle.invertPythPrice(price, -8);
    }

    /// @dev Interpret the input as a decimal rational independently of the oracle's eight-decimal normalization.
    ///      Positive int64 prices and exponents [-18,18] keep every property cross-product below 2e55.
    function _decimalRatio(
        int64 price,
        int32 exponent
    ) private pure returns (uint256 numerator, uint256 denominator) {
        numerator = uint64(price);
        denominator = 1;
        if (exponent < 0) {
            denominator = 10 ** uint32(-exponent);
        } else {
            numerator *= 10 ** uint32(exponent);
        }
    }

}
