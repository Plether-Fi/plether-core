// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockToken} from "@plether/test-utils/MockToken.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Numeric quote boundaries without mutable pool accounting or synthetic token balances.
contract JuniorDepositQuoteTest is Test {

    uint256 internal constant MAX_SUPPLY = type(uint256).max - 1000;

    TrancheVault internal junior;
    TrancheVault internal senior;

    function setUp() public {
        IERC20 token = IERC20(address(new MockToken("Settlement", "SETTLEMENT", 6)));
        // Zero-fee construction and state quotes do not read the pool.
        junior = new TrancheVault(token, address(0x123), false, "Junior", "JUNIOR", 0, address(0));
        senior = new TrancheVault(token, address(0x123), true, "Senior", "SENIOR", 0, address(0));
    }

    function test_EmptySeedRetainsInitialConversion() public view {
        assertEq(junior.quoteDepositFromState(1e6, 0, 0, 0), 1e9);
        assertEq(senior.quoteDepositFromState(1e6, 0, 0, 0), 1e9);
    }

    function test_FloorBoundaryIncludesOffsetsAndDoesNotApplyToSenior() public view {
        uint256 supply = 1e18 - 1000;

        assertEq(junior.quoteDepositFromState(1e6, 1e9 - 2, supply, 0), 0);
        assertEq(junior.quoteDepositFromState(1e6, 1e9 - 1, supply, 0), 1e15);
        assertEq(junior.quoteDepositFromState(1e6, 1e9, supply, 0), 999_999_999_000_000);
        assertGt(senior.quoteDepositFromState(1e6, 1e9 - 2, supply, 0), 1e15);
    }

    function test_DiscountedAndRetainedFeeQuotesRemainExact() public view {
        assertEq(junior.quoteDepositFromState(2e6, 499_999, 999_999_000, 0), 4e9);
        assertEq(junior.quoteDepositFromState(1e6, 999_999, 999_999_000, 500), 904_761_904);
    }

    function test_NonExpandingQuoteAllowsExactHeadroom() public view {
        uint256 supply = MAX_SUPPLY - 10;
        uint256 adjustedSupply = supply + 1000;

        assertEq(junior.quoteDepositFromState(10, adjustedSupply - 1, supply, 0), 10);
        assertEq(junior.quoteDepositFromState(11, adjustedSupply - 1, supply, 0), 0);
        // The denominator may be uint256.max, and rounding can still leave an exact ten-share fit.
        assertEq(junior.quoteDepositFromState(11, type(uint256).max - 1, supply, 0), 10);
        assertEq(junior.quoteDepositFromState(12, type(uint256).max - 1, supply, 0), 0);
    }

    function test_ExpandingQuoteAllowsExactHeadroom() public view {
        uint256 supply = MAX_SUPPLY - 10;
        uint256 assets = (supply + 1000) / 2 - 1;

        assertEq(junior.quoteDepositFromState(5, assets, supply, 0), 10);
        assertEq(junior.quoteDepositFromState(6, assets, supply, 0), 0);
    }

    function test_OverflowingNominalQuoteReturnsZero() public view {
        uint256 supply = (MAX_SUPPLY / 4) * 3;
        uint256 assets = supply / 1e9 + 1;

        // The floor is satisfied and the old denominator sum fits, but the nominal share quotient cannot fit.
        assertEq(junior.quoteDepositFromState(type(uint256).max / 2, assets, supply, 0), 0);
        assertEq(senior.quoteDepositFromState(type(uint256).max / 2, assets, supply, 0), 0);
    }

    function test_DenominatorCancellationDoesNotOverflow() public view {
        // Independent integer vectors where adding gross assets first would overflow before cancelling them.
        assertEq(junior.quoteDepositFromState(type(uint256).max - 1, type(uint256).max - 1, 0, 0), 999);
        assertEq(junior.quoteDepositFromState(type(uint256).max, type(uint256).max / 4, 999_999_000, 5000), 666_666_666);
    }

    function test_UnrepresentableSupplyAndDenominatorReturnZero() public view {
        assertEq(junior.quoteDepositFromState(1e6, type(uint256).max - 1, MAX_SUPPLY + 1, 0), 0);
        assertEq(senior.quoteDepositFromState(1e6, type(uint256).max - 1, type(uint256).max, 0), 0);
        assertEq(junior.quoteDepositFromState(1, type(uint256).max, 0, 0), 0);
        assertEq(junior.quoteDepositFromState(2, type(uint256).max - 1, 0, 5000), 0);
        assertEq(junior.quoteDepositFromState(1e6, 1e6, 1e9, 10_000), 0);
    }

    function test_InvalidFeeStillRevertsBeforeNumericRejection() public {
        vm.expectRevert(TrancheVault.TrancheVault__InvalidFee.selector);
        junior.quoteDepositFromState(1, type(uint256).max, type(uint256).max, 10_001);
        vm.expectRevert(TrancheVault.TrancheVault__InvalidFee.selector);
        senior.quoteDepositFromState(1, type(uint256).max, type(uint256).max, 10_001);
    }

    function testFuzz_QuotesNeverExceedRemainingSupply(
        uint256 assets,
        uint256 pricingAssets,
        uint256 pricingSupply,
        uint256 feeSeed
    ) public view {
        uint256 feeBps = bound(feeSeed, 0, 10_000);
        uint256 juniorShares = junior.quoteDepositFromState(assets, pricingAssets, pricingSupply, feeBps);
        uint256 seniorShares = senior.quoteDepositFromState(assets, pricingAssets, pricingSupply, feeBps);

        if (pricingSupply > MAX_SUPPLY) {
            assertEq(juniorShares, 0);
            assertEq(seniorShares, 0);
        } else {
            assertLe(juniorShares, MAX_SUPPLY - pricingSupply);
            assertLe(seniorShares, MAX_SUPPLY - pricingSupply);
        }
    }

    function testFuzz_OneToOneQuoteAllowsExactHeadroom(
        uint256 supplySeed
    ) public view {
        uint256 supply = bound(supplySeed, 0, MAX_SUPPLY);
        uint256 headroom = MAX_SUPPLY - supply;
        // Equal adjusted assets and shares make the exact quote one raw share per asset atom.
        assertEq(junior.quoteDepositFromState(headroom, supply + 999, supply, 0), headroom);
        assertEq(junior.quoteDepositFromState(headroom + 1, supply + 999, supply, 0), 0);
    }

}
