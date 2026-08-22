// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";
import {Test} from "forge-std/Test.sol";

contract HousePoolRedemptionMathHarness {

    function netAssetsForShares(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256) {
        return
            HousePoolRedemptionMathLib.netAssetsForShares(
                shares, principal, supply, virtualAssets, virtualShares, feeBps
            );
    }

    function maxSharesForNetBudget(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 fundedShares, uint256 netAssets) {
        return HousePoolRedemptionMathLib.maxSharesForNetBudget(
            budget, maxShares, principal, supply, virtualAssets, virtualShares, feeBps
        );
    }

}

contract HousePoolRedemptionMathLibTest is Test {

    uint256 internal constant BPS = 10_000;

    HousePoolRedemptionMathHarness internal harness;

    function setUp() public {
        harness = new HousePoolRedemptionMathHarness();
    }

    function test_NetAssetsForShares_AppliesBothFloorsInOrder() public view {
        // gross = floor(1 * (18 + 1) / (3 + 1)) = 4
        // net   = floor(4 * (10_000 - 3_333) / 10_000) = 2
        // Applying one combined floor would incorrectly produce 3 here.
        uint256 netAssets = harness.netAssetsForShares(1, 18, 3, 1, 1, 3333);

        assertEq(netAssets, 2);
    }

    function test_NetAssetsForShares_ZeroFeeReturnsGrossAssets() public view {
        uint256 netAssets = harness.netAssetsForShares(7, 100, 9, 1, 1, 0);

        assertEq(netAssets, 70);
    }

    function test_NetAssetsForShares_HundredPercentFeeReturnsZero() public view {
        assertEq(harness.netAssetsForShares(1000, 100, 1000, 1, 1000, BPS), 0);
    }

    function test_NetAssetsForShares_UsesVirtualOffsets() public view {
        // Even an empty tranche has the ERC-4626 virtual 1 asset / 1,000 shares conversion rate.
        assertEq(harness.netAssetsForShares(1000, 0, 0, 1, 1000, 0), 1);
    }

    function test_NetAssetsForShares_RevertsAboveHundredPercentFee() public {
        vm.expectRevert(HousePoolRedemptionMathLib.HousePoolRedemptionMathLib__InvalidFeeBps.selector);
        harness.netAssetsForShares(1, 1, 1, 1, 1, BPS + 1);
    }

    function test_MaxSharesForNetBudget_RevertsAboveHundredPercentFee() public {
        vm.expectRevert(HousePoolRedemptionMathLib.HousePoolRedemptionMathLib__InvalidFeeBps.selector);
        harness.maxSharesForNetBudget(1, 1, 1, 1, 1, 1, BPS + 1);
    }

    function test_MaxSharesForNetBudget_FullFillAtExactBudget() public view {
        (uint256 fundedShares, uint256 netAssets) = harness.maxSharesForNetBudget(49, 1000, 100, 1000, 1, 1000, 100);

        assertEq(fundedShares, 1000);
        assertEq(netAssets, 49);
    }

    function test_MaxSharesForNetBudget_PartialFillIsMaximal() public view {
        (uint256 fundedShares, uint256 netAssets) = harness.maxSharesForNetBudget(100, 1000, 1000, 1000, 1, 1000, 0);

        assertEq(fundedShares, 201);
        assertEq(netAssets, 100);
        assertEq(harness.netAssetsForShares(fundedShares + 1, 1000, 1000, 1, 1000, 0), 101);
    }

    function test_MaxSharesForNetBudget_DoesNotBurnSharesForZeroPayout() public view {
        (uint256 fundedShares, uint256 netAssets) = harness.maxSharesForNetBudget(1, 999, 0, 0, 1, 1000, 0);

        assertEq(fundedShares, 0);
        assertEq(netAssets, 0);
    }

    function test_MaxSharesForNetBudget_HundredPercentFeeDoesNotBurnShares() public view {
        (uint256 fundedShares, uint256 netAssets) = harness.maxSharesForNetBudget(100, 1000, 1000, 1000, 1, 1000, BPS);

        assertEq(fundedShares, 0);
        assertEq(netAssets, 0);
    }

    function testFuzz_MaxSharesForNetBudget_MatchesSmallBruteForceOracle(
        uint256 budgetSeed,
        uint256 maxSharesSeed,
        uint256 principalSeed,
        uint256 supplySeed,
        uint256 virtualAssetsSeed,
        uint256 virtualSharesSeed,
        uint256 feeBpsSeed
    ) public view {
        uint256 budget = bound(budgetSeed, 0, 512);
        uint256 maxShares = bound(maxSharesSeed, 0, 256);
        uint256 principal = bound(principalSeed, 0, 512);
        uint256 supply = bound(supplySeed, 0, 512);
        uint256 virtualAssets = bound(virtualAssetsSeed, 1, 32);
        uint256 virtualShares = bound(virtualSharesSeed, 1, 32);
        uint256 feeBps = bound(feeBpsSeed, 0, BPS);

        (uint256 expectedShares, uint256 expectedAssets) =
            _bruteForceMaxShares(budget, maxShares, principal, supply, virtualAssets, virtualShares, feeBps);
        (uint256 actualShares, uint256 actualAssets) =
            harness.maxSharesForNetBudget(budget, maxShares, principal, supply, virtualAssets, virtualShares, feeBps);

        assertEq(actualShares, expectedShares, "funded shares");
        assertEq(actualAssets, expectedAssets, "net assets");
        assertEq(
            harness.netAssetsForShares(actualShares, principal, supply, virtualAssets, virtualShares, feeBps),
            actualAssets,
            "canonical quote"
        );
    }

    function testFuzz_NetAssetsForShares_MatchesNestedFloorOracle(
        uint256 sharesSeed,
        uint256 principalSeed,
        uint256 supplySeed,
        uint256 virtualAssetsSeed,
        uint256 virtualSharesSeed,
        uint256 feeBpsSeed
    ) public view {
        uint256 shares = bound(sharesSeed, 0, 256);
        uint256 principal = bound(principalSeed, 0, 512);
        uint256 supply = bound(supplySeed, 0, 512);
        uint256 virtualAssets = bound(virtualAssetsSeed, 1, 32);
        uint256 virtualShares = bound(virtualSharesSeed, 1, 32);
        uint256 feeBps = bound(feeBpsSeed, 0, BPS);

        assertEq(
            harness.netAssetsForShares(shares, principal, supply, virtualAssets, virtualShares, feeBps),
            _oracleNetAssets(shares, principal, supply, virtualAssets, virtualShares, feeBps)
        );
    }

    function _bruteForceMaxShares(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) internal pure returns (uint256 fundedShares, uint256 netAssets) {
        for (uint256 candidateShares = 1; candidateShares <= maxShares; ++candidateShares) {
            uint256 candidateAssets =
                _oracleNetAssets(candidateShares, principal, supply, virtualAssets, virtualShares, feeBps);
            if (candidateAssets > budget) {
                break;
            }
            if (candidateAssets > 0) {
                fundedShares = candidateShares;
                netAssets = candidateAssets;
            }
        }
    }

    function _oracleNetAssets(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) internal pure returns (uint256) {
        uint256 grossAssets = shares * (principal + virtualAssets) / (supply + virtualShares);
        return grossAssets * (BPS - feeBps) / BPS;
    }

}
