// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {BasePerpTest} from "./BasePerpTest.sol";

contract FrozenLpFeePolicyTest is BasePerpTest {

    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600;
    uint256 internal constant SUNDAY_FAD_ONLY = 1_710_106_200;

    function _enterFrozenWindow() internal {
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));
    }

    function test_SeniorDeposit_ChargesFrozenFeeAndBenefitsIncumbents() public {
        address incumbent = address(0xA11CE);
        address entrant = address(0xBEEF);
        uint256 assets = 100_000e6;

        _fundSenior(incumbent, 500_000e6);
        _fundJunior(address(0xC0FFEE), 500_000e6);
        _enterFrozenWindow();

        usdc.mint(entrant, assets);

        uint256 priceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 quotedShares = seniorVault.previewDeposit(assets);
        uint256 noFeeShares = seniorVault.convertToShares(assets);

        vm.startPrank(entrant);
        usdc.approve(address(seniorVault), assets);
        uint256 mintedShares = seniorVault.deposit(assets, entrant);
        vm.stopPrank();

        uint256 priceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();

        assertEq(pool.frozenLpFeeBps(true), 25, "Senior frozen LP fee should be 25 bps");
        assertEq(mintedShares, quotedShares, "Frozen senior deposit should honor previewDeposit");
        assertLt(mintedShares, noFeeShares, "Frozen senior deposit should mint fewer shares than no-fee pricing");
        assertGt(priceAfter, priceBefore, "Frozen senior deposit fee should improve incumbent share price");
        assertEq(juniorPriceAfter, juniorPriceBefore, "Senior frozen fee should not reprice the junior tranche");
    }

    function test_JuniorRedeem_ChargesFrozenFee() public {
        address incumbent = address(0xB0B);
        uint256 shares = 100_000e9;

        _fundJunior(incumbent, 500_000e6);
        _fundSenior(address(0xD00D), 500_000e6);
        _enterFrozenWindow();

        uint256 quotedAssets = juniorVault.previewRedeem(shares);
        uint256 noFeeAssets = juniorVault.convertToAssets(shares);
        uint256 balanceBefore = usdc.balanceOf(incumbent);
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();

        vm.prank(incumbent);
        uint256 redeemedAssets = juniorVault.redeem(shares, incumbent, incumbent);

        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();

        assertEq(pool.frozenLpFeeBps(false), 75, "Junior frozen LP fee should be 75 bps");
        assertEq(redeemedAssets, quotedAssets, "Frozen junior redeem should honor previewRedeem");
        assertLt(redeemedAssets, noFeeAssets, "Frozen junior redeem should pay fewer assets than no-fee pricing");
        assertEq(
            usdc.balanceOf(incumbent), balanceBefore + redeemedAssets, "Redeem should transfer the net quoted assets"
        );
        assertGt(
            juniorPriceAfter,
            juniorPriceBefore,
            "Junior frozen redeem fee should improve remaining junior LP share price"
        );
        assertEq(seniorPriceAfter, seniorPriceBefore, "Junior frozen fee should not reprice the senior tranche");
    }

    function test_FadOnlyHour_DoesNotActivateFrozenFee() public {
        vm.warp(SUNDAY_FAD_ONLY);

        assertTrue(engine.isFadWindow(), "setup should remain inside FAD");
        assertFalse(engine.isOracleFrozen(), "setup should be after the oracle-frozen window");
        assertEq(pool.frozenLpFeeBps(true), 0, "Senior fee should be disabled when only FAD is active");
        assertEq(pool.frozenLpFeeBps(false), 0, "Junior fee should be disabled when only FAD is active");
    }

    function test_FrozenWindow_PreviewWithdrawMatchesLiveWithdraw() public {
        address lp = address(0xCAFE);
        uint256 netAssets = 100_000e6;

        _fundJunior(lp, 500_000e6);
        _enterFrozenWindow();

        uint256 quotedShares = juniorVault.previewWithdraw(netAssets);
        uint256 balanceBefore = usdc.balanceOf(lp);

        vm.prank(lp);
        uint256 burnedShares = juniorVault.withdraw(netAssets, lp, lp);

        assertEq(burnedShares, quotedShares, "Frozen junior withdraw should honor previewWithdraw");
        assertEq(usdc.balanceOf(lp), balanceBefore + netAssets, "Withdraw should transfer the quoted net assets");
    }

    function test_GovernedFrozenFeeUpdate_FlowsThroughFrozenPricing() public {
        address lp = address(0x1234);
        uint256 assets = 100_000e6;

        _fundSenior(address(0xA11CE), 500_000e6);
        pool.proposeFrozenLpFees(40, 90);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeFrozenLpFees();

        _enterFrozenWindow();
        usdc.mint(lp, assets);

        uint256 quotedShares = seniorVault.previewDeposit(assets);
        uint256 expectedEffectiveAssets = (assets * (10_000 - 40)) / 10_000;
        uint256 noFeeShares = seniorVault.convertToShares(assets);
        uint256 expectedShares = seniorVault.convertToShares(expectedEffectiveAssets);

        vm.startPrank(lp);
        usdc.approve(address(seniorVault), assets);
        uint256 mintedShares = seniorVault.deposit(assets, lp);
        vm.stopPrank();

        assertEq(pool.frozenLpFeeBps(true), 40, "Updated governed senior frozen fee should become active");
        assertEq(quotedShares, expectedShares, "Preview should reflect the updated governed frozen fee");
        assertEq(mintedShares, quotedShares, "Live deposit should match governed frozen-fee preview");
        assertLt(
            mintedShares, noFeeShares, "Updated governed fee should still discount minted shares versus no-fee pricing"
        );
    }

    function test_FrozenWithdrawFee_RemainsJuniorLocal() public {
        address juniorLp = address(0xFADE);
        address seniorLp = address(0xFACE);
        uint256 netAssets = 100_000e6;

        _fundJunior(juniorLp, 500_000e6);
        _fundSenior(seniorLp, 500_000e6);
        _enterFrozenWindow();

        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();

        vm.prank(juniorLp);
        juniorVault.withdraw(netAssets, juniorLp, juniorLp);

        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();

        assertGt(
            juniorPriceAfter,
            juniorPriceBefore,
            "Junior frozen withdraw fee should improve remaining junior LP share price"
        );
        assertEq(seniorPriceAfter, seniorPriceBefore, "Junior frozen withdraw fee should not affect the senior tranche");
    }

}
