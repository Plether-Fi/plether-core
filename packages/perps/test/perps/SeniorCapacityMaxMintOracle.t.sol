// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract SeniorCapacityMaxMintPricingPoolMock {

    uint256 internal seniorPricingAssets;

    function setSeniorPricingAssets(
        uint256 assets
    ) external {
        seniorPricingAssets = assets;
    }

    function getPendingDepositTrancheState() external view returns (uint256, uint256) {
        return (seniorPricingAssets, 0);
    }

}

contract SeniorCapacityMaxMintHarness is TrancheVault {

    constructor(
        IERC20 usdc,
        address pool
    ) TrancheVault(usdc, pool, true, "Senior Capacity Max-Mint Harness", "scMaxMint", 0, address(0)) {}

    function setShareSupply(
        uint256 shares
    ) external {
        _mint(address(this), shares);
    }

    function exposedMaxMintSharesForAssetCapacity(
        uint256 capacity,
        uint256 feeBps
    ) external view returns (uint256) {
        return _maxMintSharesForAssetCapacity(capacity, feeBps);
    }

    function exposedPreviewMintAssets(
        uint256 shares
    ) external view returns (uint256) {
        return _previewMintAssets(shares);
    }

    function exposedPreviewFrozenMintAssets(
        uint256 shares,
        uint256 feeBps
    ) external view returns (uint256) {
        return _previewFrozenMintAssets(shares, feeBps);
    }

}

/// @dev Differential tests for senior max-mint arithmetic. The bounded tests use direct native-width algebra. The
///      overflow-scale tests use a deliberately separate base-2^64 big-integer implementation: they do not call
///      `previewMint`, `Math.mulDiv`, the vault's fit predicate, or its 512/768-bit helpers to derive expected values.
contract SeniorCapacityMaxMintOracleTest is Test {

    uint256 internal constant BPS = 10_000;
    uint256 internal constant VIRTUAL_SHARES = 1000;
    uint256 internal constant BIG_LIMB_BASE = 1 << 64;
    uint256 internal constant BIG_LIMB_MASK = BIG_LIMB_BASE - 1;

    struct OracleBigInt {
        uint256[12] limbs;
    }

    function testFuzz_NormalMaxMintMatchesIndependentNativeOracle(
        uint256 capacityRaw,
        uint256 adjustedSharesRaw,
        uint256 adjustedAssetsRaw
    ) public {
        uint256 capacity = bound(capacityRaw, 1, 1e24);
        uint256 adjustedShares = bound(adjustedSharesRaw, VIRTUAL_SHARES, 1e24);
        uint256 adjustedAssets = bound(adjustedAssetsRaw, 1, 1e24);
        SeniorCapacityMaxMintHarness vault = _newHarness(adjustedShares, adjustedAssets);

        uint256 expectedMaxShares = (capacity * adjustedShares) / adjustedAssets;
        uint256 actualMaxShares = vault.exposedMaxMintSharesForAssetCapacity(capacity, 0);

        assertEq(actualMaxShares, expectedMaxShares, "normal maxMint must match independent floor oracle");
        assertEq(
            _oracleNormalMaxMint(capacity, adjustedShares, adjustedAssets),
            expectedMaxShares,
            "big-integer oracle must agree with native algebra in its safe range"
        );

        uint256 expectedAssets = _ceilDiv(expectedMaxShares * adjustedAssets, adjustedShares);
        uint256 expectedNextAssets = _ceilDiv((expectedMaxShares + 1) * adjustedAssets, adjustedShares);
        assertEq(vault.exposedPreviewMintAssets(expectedMaxShares), expectedAssets);
        assertEq(vault.exposedPreviewMintAssets(expectedMaxShares + 1), expectedNextAssets);
        assertLe(expectedAssets, capacity, "maxMint quote must fit normal capacity");
        assertGt(expectedNextAssets, capacity, "one additional normal share must exceed capacity");
    }

    function testFuzz_FrozenMaxMintMatchesIndependentNativeOracle(
        uint256 capacityRaw,
        uint256 adjustedSharesRaw,
        uint256 adjustedAssetsRaw,
        uint256 feeBpsRaw
    ) public {
        uint256 capacity = bound(capacityRaw, 1, 1e24);
        uint256 adjustedShares = bound(adjustedSharesRaw, VIRTUAL_SHARES, 1e24);
        uint256 adjustedAssets = bound(adjustedAssetsRaw, 1, 1e24);
        uint256 feeBps = bound(feeBpsRaw, 1, BPS - 1);
        SeniorCapacityMaxMintHarness vault = _newHarness(adjustedShares, adjustedAssets);

        uint256 expectedMaxShares = _nativeFrozenMaxMint(capacity, feeBps, adjustedShares, adjustedAssets);
        uint256 actualMaxShares = vault.exposedMaxMintSharesForAssetCapacity(capacity, feeBps);

        assertEq(actualMaxShares, expectedMaxShares, "frozen maxMint must match independent rational oracle");
        assertEq(
            _oracleFrozenMaxMint(capacity, feeBps, adjustedShares, adjustedAssets),
            expectedMaxShares,
            "big-integer oracle must agree with native algebra in its safe range"
        );

        uint256 expectedAssets = _nativeFrozenPreview(expectedMaxShares, feeBps, adjustedShares, adjustedAssets);
        uint256 expectedNextAssets = _nativeFrozenPreview(expectedMaxShares + 1, feeBps, adjustedShares, adjustedAssets);
        assertEq(vault.exposedPreviewFrozenMintAssets(expectedMaxShares, feeBps), expectedAssets);
        assertEq(vault.exposedPreviewFrozenMintAssets(expectedMaxShares + 1, feeBps), expectedNextAssets);
        assertLe(expectedAssets, capacity, "maxMint quote must fit frozen gross capacity");
        assertGt(expectedNextAssets, capacity, "one additional frozen share must exceed capacity");
    }

    function testFuzz_WideFrozenMaxMintMatchesIndependentBigIntegerOracle(
        uint256 capacityRaw,
        uint256 adjustedSharesRaw,
        uint256 adjustedAssetsRaw,
        uint256 feeBpsRaw
    ) public {
        uint256 capacity = bound(capacityRaw, 1, type(uint256).max - 1);
        uint256 adjustedShares = bound(adjustedSharesRaw, VIRTUAL_SHARES, type(uint256).max);
        uint256 adjustedAssets = bound(adjustedAssetsRaw, 1, type(uint256).max);
        uint256 feeBps = bound(feeBpsRaw, 1, BPS - 1);

        _assertWideFrozenCase(capacity, feeBps, adjustedShares, adjustedAssets);
    }

    function testFuzz_WideNormalMaxMintMatchesIndependentBigIntegerOracle(
        uint256 capacityRaw,
        uint256 adjustedSharesRaw,
        uint256 adjustedAssetsRaw
    ) public {
        uint256 capacity = bound(capacityRaw, 1, type(uint256).max - 1);
        uint256 adjustedShares = bound(adjustedSharesRaw, VIRTUAL_SHARES, type(uint256).max);
        uint256 adjustedAssets = bound(adjustedAssetsRaw, 1, type(uint256).max);
        SeniorCapacityMaxMintHarness vault = _newHarness(adjustedShares, adjustedAssets);

        uint256 expectedMaxShares = _oracleNormalMaxMint(capacity, adjustedShares, adjustedAssets);
        uint256 actualMaxShares = vault.exposedMaxMintSharesForAssetCapacity(capacity, 0);
        assertEq(actualMaxShares, expectedMaxShares, "wide normal maxMint must match independent big-integer oracle");

        (uint256 expectedAssets, bool maxPreviewOverflowed) =
            _oracleNormalPreview(expectedMaxShares, adjustedShares, adjustedAssets);
        assertFalse(maxPreviewOverflowed, "the independently derived maxMint quote must remain representable");
        uint256 actualAssets = vault.exposedPreviewMintAssets(actualMaxShares);
        assertEq(actualAssets, expectedAssets, "wide normal preview at maxMint must match independent oracle");
        assertLe(actualAssets, capacity, "wide normal maxMint quote must fit gross capacity");

        if (actualMaxShares < type(uint256).max) {
            (uint256 expectedNextAssets, bool nextPreviewOverflowed) =
                _oracleNormalPreview(actualMaxShares + 1, adjustedShares, adjustedAssets);
            try vault.exposedPreviewMintAssets(actualMaxShares + 1) returns (uint256 actualNextAssets) {
                assertFalse(nextPreviewOverflowed, "a representable production preview must not overflow in the oracle");
                assertEq(actualNextAssets, expectedNextAssets, "wide normal preview above maxMint must match oracle");
                assertGt(actualNextAssets, capacity, "one additional wide normal share must exceed capacity");
            } catch {
                assertTrue(
                    nextPreviewOverflowed,
                    "normal preview may revert only when the independent result is strictly above uint256.max"
                );
            }
        }
    }

    function test_UnboundedCapacitySentinelMatchesNormalMaximumAndFrozenAsymptote() public {
        uint256 adjustedShares = 1e24;
        uint256 adjustedAssets = adjustedShares;
        uint256 unboundedCapacity = type(uint256).max;
        uint256 feeBps = 25;
        SeniorCapacityMaxMintHarness vault = _newHarness(adjustedShares, adjustedAssets);

        assertEq(
            _oracleNormalMaxMint(unboundedCapacity, adjustedShares, adjustedAssets),
            type(uint256).max,
            "independent normal oracle must derive the full uint256 share range"
        );
        assertEq(
            vault.exposedMaxMintSharesForAssetCapacity(unboundedCapacity, 0),
            type(uint256).max,
            "unbounded normal capacity must return the ERC-4626 maximum"
        );
        (uint256 normalMaxAssets, bool normalMaxOverflowed) =
            _oracleNormalPreview(type(uint256).max, adjustedShares, adjustedAssets);
        assertFalse(normalMaxOverflowed, "an exact uint256.max quote is representable, not overflow");
        assertEq(normalMaxAssets, type(uint256).max);
        assertEq(vault.exposedPreviewMintAssets(type(uint256).max), normalMaxAssets);

        uint256 expectedAsymptoteShares = _oracleFrozenAsymptote(adjustedShares, feeBps);
        uint256 actualAsymptoteShares = vault.exposedMaxMintSharesForAssetCapacity(unboundedCapacity, feeBps);
        assertEq(
            actualAsymptoteShares,
            expectedAsymptoteShares,
            "unbounded frozen capacity must stop at the independent fee asymptote"
        );

        uint256 expectedAsymptoteAssets =
            _oracleFrozenPreview(expectedAsymptoteShares, feeBps, adjustedShares, adjustedAssets);
        assertLt(expectedAsymptoteAssets, type(uint256).max, "last asymptote share must have a finite quote");
        assertEq(
            vault.exposedPreviewFrozenMintAssets(actualAsymptoteShares, feeBps),
            expectedAsymptoteAssets,
            "last asymptote share preview must match the independent oracle"
        );

        uint256 expectedPastAsymptoteAssets =
            _oracleFrozenPreview(expectedAsymptoteShares + 1, feeBps, adjustedShares, adjustedAssets);
        assertEq(expectedPastAsymptoteAssets, type(uint256).max);
        assertEq(
            vault.exposedPreviewFrozenMintAssets(actualAsymptoteShares + 1, feeBps),
            expectedPastAsymptoteAssets,
            "one share past the fee asymptote must be unpriceable"
        );
    }

    function test_WideFrozenMaxMintCoversOverflowAndAsymptoteEdges() public {
        uint256 wideAssets = type(uint256).max / 9000 + 1;
        _assertWideFrozenCase(2e6, 25, wideAssets - 1000, wideAssets);
        _assertWideFrozenCase(type(uint256).max - 1, 1, type(uint256).max, type(uint256).max);
        _assertWideFrozenCase(type(uint256).max - 1, 9999, type(uint256).max / 2, type(uint256).max);
        _assertWideFrozenCase(type(uint256).max / 2, 5000, type(uint256).max, type(uint256).max / 2);
    }

    function _assertWideFrozenCase(
        uint256 capacity,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal {
        SeniorCapacityMaxMintHarness vault = _newHarness(adjustedShares, adjustedAssets);
        uint256 expectedMaxShares = _oracleFrozenMaxMint(capacity, feeBps, adjustedShares, adjustedAssets);
        uint256 actualMaxShares = vault.exposedMaxMintSharesForAssetCapacity(capacity, feeBps);

        assertEq(actualMaxShares, expectedMaxShares, "wide frozen maxMint must match independent big-integer oracle");

        uint256 expectedAssets = _oracleFrozenPreview(expectedMaxShares, feeBps, adjustedShares, adjustedAssets);
        uint256 actualAssets = vault.exposedPreviewFrozenMintAssets(actualMaxShares, feeBps);
        assertEq(actualAssets, expectedAssets, "wide preview at maxMint must match independent oracle");
        assertLe(actualAssets, capacity, "wide maxMint quote must fit frozen gross capacity");

        if (actualMaxShares < type(uint256).max) {
            uint256 expectedNextAssets =
                _oracleFrozenPreview(actualMaxShares + 1, feeBps, adjustedShares, adjustedAssets);
            uint256 actualNextAssets = vault.exposedPreviewFrozenMintAssets(actualMaxShares + 1, feeBps);
            assertEq(actualNextAssets, expectedNextAssets, "wide preview above maxMint must match independent oracle");
            assertGt(actualNextAssets, capacity, "one additional wide frozen share must exceed capacity");
        }
    }

    function _newHarness(
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal returns (SeniorCapacityMaxMintHarness vault) {
        MockUSDC usdc = new MockUSDC();
        SeniorCapacityMaxMintPricingPoolMock pricingPool = new SeniorCapacityMaxMintPricingPoolMock();
        pricingPool.setSeniorPricingAssets(adjustedAssets - 1);
        vault = new SeniorCapacityMaxMintHarness(IERC20(address(usdc)), address(pricingPool));
        vault.setShareSupply(adjustedShares - VIRTUAL_SHARES);
    }

    function _nativeFrozenMaxMint(
        uint256 capacity,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256) {
        uint256 numerator = capacity * (BPS - feeBps) * adjustedShares;
        uint256 denominator = BPS * adjustedAssets + feeBps * capacity;
        return numerator / denominator;
    }

    function _nativeFrozenPreview(
        uint256 shares,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256) {
        uint256 feeAdjustedShareValue = (BPS - feeBps) * adjustedShares;
        uint256 feeShareValue = feeBps * shares;
        if (feeShareValue >= feeAdjustedShareValue) {
            return type(uint256).max;
        }
        return _ceilDiv(BPS * shares * adjustedAssets, feeAdjustedShareValue - feeShareValue);
    }

    function _ceilDiv(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }

    function _oracleNormalMaxMint(
        uint256 capacity,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256) {
        OracleBigInt memory numerator = _bigMul(_bigFromUint(capacity), _bigFromUint(adjustedShares));
        (uint256 quotient,,) = _bigDivFloor(numerator, _bigFromUint(adjustedAssets));
        return quotient;
    }

    function _oracleNormalPreview(
        uint256 shares,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256 assets, bool overflowed) {
        OracleBigInt memory numerator = _bigMul(_bigFromUint(shares), _bigFromUint(adjustedAssets));
        (uint256 quotient, bool quotientOverflowed, bool hasRemainder) =
            _bigDivFloor(numerator, _bigFromUint(adjustedShares));
        if (quotientOverflowed || (quotient == type(uint256).max && hasRemainder)) {
            return (type(uint256).max, true);
        }
        return (hasRemainder ? quotient + 1 : quotient, false);
    }

    function _oracleFrozenAsymptote(
        uint256 adjustedShares,
        uint256 feeBps
    ) internal pure returns (uint256) {
        OracleBigInt memory numerator = _bigMul(_bigFromUint(BPS - feeBps), _bigFromUint(adjustedShares));
        (uint256 quotient, bool overflowed, bool hasRemainder) = _bigDivFloor(numerator, _bigFromUint(feeBps));
        if (overflowed) {
            return type(uint256).max;
        }
        return hasRemainder ? quotient : quotient - 1;
    }

    function _oracleFrozenMaxMint(
        uint256 capacity,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256) {
        OracleBigInt memory numerator = _bigMul(_bigFromUint(capacity), _bigFromUint(BPS - feeBps));
        numerator = _bigMul(numerator, _bigFromUint(adjustedShares));

        OracleBigInt memory denominator = _bigMul(_bigFromUint(BPS), _bigFromUint(adjustedAssets));
        denominator = _bigAdd(denominator, _bigMul(_bigFromUint(feeBps), _bigFromUint(capacity)));

        (uint256 quotient,,) = _bigDivFloor(numerator, denominator);
        return quotient;
    }

    function _oracleFrozenPreview(
        uint256 shares,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) internal pure returns (uint256) {
        OracleBigInt memory denominator = _bigMul(_bigFromUint(BPS - feeBps), _bigFromUint(adjustedShares));
        OracleBigInt memory feeShareValue = _bigMul(_bigFromUint(feeBps), _bigFromUint(shares));
        if (_bigCompare(denominator, feeShareValue) <= 0) {
            return type(uint256).max;
        }
        denominator = _bigSubtract(denominator, feeShareValue);

        OracleBigInt memory numerator = _bigMul(_bigFromUint(BPS), _bigFromUint(shares));
        numerator = _bigMul(numerator, _bigFromUint(adjustedAssets));
        (uint256 quotient, bool overflowed, bool hasRemainder) = _bigDivFloor(numerator, denominator);
        if (overflowed || (quotient == type(uint256).max && hasRemainder)) {
            return type(uint256).max;
        }
        return hasRemainder ? quotient + 1 : quotient;
    }

    function _bigFromUint(
        uint256 value
    ) internal pure returns (OracleBigInt memory result) {
        for (uint256 i = 0; i < 4; ++i) {
            result.limbs[i] = (value >> (i * 64)) & BIG_LIMB_MASK;
        }
    }

    function _bigMul(
        OracleBigInt memory x,
        OracleBigInt memory y
    ) internal pure returns (OracleBigInt memory result) {
        for (uint256 i = 0; i < 12; ++i) {
            if (x.limbs[i] == 0) {
                continue;
            }
            for (uint256 j = 0; j + i < 12; ++j) {
                if (y.limbs[j] != 0) {
                    result.limbs[i + j] += x.limbs[i] * y.limbs[j];
                }
            }
        }
        for (uint256 i = 0; i < 11; ++i) {
            result.limbs[i + 1] += result.limbs[i] >> 64;
            result.limbs[i] &= BIG_LIMB_MASK;
        }
        assertEq(result.limbs[11] >> 64, 0, "test oracle exceeded its 768-bit range");
    }

    function _bigAdd(
        OracleBigInt memory x,
        OracleBigInt memory y
    ) internal pure returns (OracleBigInt memory result) {
        uint256 carry;
        for (uint256 i = 0; i < 12; ++i) {
            uint256 sum = x.limbs[i] + y.limbs[i] + carry;
            result.limbs[i] = sum & BIG_LIMB_MASK;
            carry = sum >> 64;
        }
        assertEq(carry, 0, "test oracle addition exceeded its 768-bit range");
    }

    function _bigSubtract(
        OracleBigInt memory x,
        OracleBigInt memory y
    ) internal pure returns (OracleBigInt memory result) {
        uint256 borrow;
        for (uint256 i = 0; i < 12; ++i) {
            uint256 subtrahend = y.limbs[i] + borrow;
            if (x.limbs[i] >= subtrahend) {
                result.limbs[i] = x.limbs[i] - subtrahend;
                borrow = 0;
            } else {
                result.limbs[i] = BIG_LIMB_BASE + x.limbs[i] - subtrahend;
                borrow = 1;
            }
        }
        assertEq(borrow, 0, "test oracle subtraction underflowed");
    }

    function _bigDivFloor(
        OracleBigInt memory numerator,
        OracleBigInt memory denominator
    ) internal pure returns (uint256 quotient, bool overflowed, bool hasRemainder) {
        OracleBigInt memory remainder;
        uint256 numeratorBits = _bigBitLength(numerator);
        for (uint256 cursor = numeratorBits; cursor > 0; --cursor) {
            uint256 bitIndex = cursor - 1;
            _bigShiftLeftOne(remainder);
            remainder.limbs[0] |= (numerator.limbs[bitIndex / 64] >> (bitIndex % 64)) & 1;
            if (_bigCompare(remainder, denominator) >= 0) {
                remainder = _bigSubtract(remainder, denominator);
                if (bitIndex >= 256) {
                    return (type(uint256).max, true, false);
                }
                quotient |= uint256(1) << bitIndex;
            }
        }
        return (quotient, false, _bigBitLength(remainder) != 0);
    }

    function _bigShiftLeftOne(
        OracleBigInt memory value
    ) internal pure {
        uint256 carry;
        for (uint256 i = 0; i < 12; ++i) {
            uint256 nextCarry = value.limbs[i] >> 63;
            value.limbs[i] = ((value.limbs[i] << 1) & BIG_LIMB_MASK) | carry;
            carry = nextCarry;
        }
        assertEq(carry, 0, "test oracle shift exceeded its 768-bit range");
    }

    function _bigCompare(
        OracleBigInt memory x,
        OracleBigInt memory y
    ) internal pure returns (int256) {
        for (uint256 cursor = 12; cursor > 0; --cursor) {
            uint256 i = cursor - 1;
            if (x.limbs[i] != y.limbs[i]) {
                return x.limbs[i] < y.limbs[i] ? int256(-1) : int256(1);
            }
        }
        return 0;
    }

    function _bigBitLength(
        OracleBigInt memory value
    ) internal pure returns (uint256) {
        for (uint256 cursor = 12; cursor > 0; --cursor) {
            uint256 i = cursor - 1;
            uint256 limb = value.limbs[i];
            if (limb == 0) {
                continue;
            }
            uint256 limbBits;
            while (limb != 0) {
                ++limbBits;
                limb >>= 1;
            }
            return i * 64 + limbBits;
        }
        return 0;
    }

}
