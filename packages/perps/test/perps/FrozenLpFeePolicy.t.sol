// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract FrozenLpFeePolicyTest is BasePerpTest {

    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600;
    uint256 internal constant SUNDAY_FAD_ONLY = 1_710_105_000;
    uint256 internal constant MAINTENANCE_FEE_APR_BPS = 1000;

    address internal constant MAINTENANCE_FEE_RECIPIENT = address(0xFEE70002);

    function _enterFrozenWindow() internal {
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));
    }

    function test_SeniorFrozenWindowRejectsNewDepositRequests() public {
        address incumbent = address(0xA11CE);
        address entrant = address(0xBEEF);
        uint256 assets = 100_000e6;

        _fundSenior(incumbent, 500_000e6);
        _fundJunior(address(0xC0FFEE), 500_000e6);
        _enterFrozenWindow();

        assertEq(seniorVault.maxRequestDeposit(entrant), 0, "frozen Senior entry capacity must be zero");
        usdc.mint(entrant, assets);
        vm.startPrank(entrant);
        usdc.approve(address(seniorVault), assets);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(assets, entrant, entrant);
        vm.stopPrank();
    }

    function test_JuniorRedeem_ChargesFrozenFee() public {
        address incumbent = address(0xB0B);
        uint256 shares = 100_000e9;

        _fundJunior(incumbent, 500_000e6);
        _fundSenior(address(0xD00D), 500_000e6);
        _enterFrozenWindow();

        uint256 quotedAssets = juniorVault.estimateRedeemAssets(shares);
        uint256 balanceBefore = usdc.balanceOf(incumbent);
        uint256 requestId = _requestRedeem(juniorVault, incumbent, shares);
        _prepareFrozenEpoch(requestId);
        uint256 maturedEstimate = juniorVault.estimateRedeemAssets(shares);
        uint256 noFeeAssets = juniorVault.convertToAssets(shares);
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        _settleLpEpochForTest();
        vm.prank(incumbent);
        uint256 redeemedAssets = juniorVault.claimRedeem(requestId, shares, incumbent, incumbent);

        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();

        assertEq(pool.frozenLpFeeBps(false), 75, "Junior frozen LP fee should be 75 bps");
        assertEq(redeemedAssets, maturedEstimate, "Matured frozen estimate should match synchronized settlement");
        assertLe(redeemedAssets, quotedAssets, "Junior coupon funding may lower the nonbinding exit estimate");
        assertLt(redeemedAssets, noFeeAssets, "Frozen junior redeem should pay fewer assets than no-fee pricing");
        assertEq(
            usdc.balanceOf(incumbent), balanceBefore + redeemedAssets, "Redeem claim should transfer the funded assets"
        );
        assertGt(
            juniorPriceAfter,
            juniorPriceBefore,
            "Junior frozen redeem fee should improve remaining junior LP share price"
        );
        assertEq(seniorPriceAfter, seniorPriceBefore, "Junior frozen fee should not reprice the senior tranche");
    }

    function test_JuniorMaintenanceFee_ComposesWithFrozenExitFee() public {
        address incumbent = address(0xB0C);
        uint256 shares = 100_000e9;

        _fundJunior(incumbent, 500_000e6);
        _fundSenior(address(0xD00E), 500_000e6);
        _enableJuniorMaintenanceFee();
        _enterFrozenWindow();

        uint256 requestId = _requestRedeem(juniorVault, incumbent, shares);
        _prepareFrozenEpoch(requestId);
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 recipientSharesBefore = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        uint256 noFrozenFeeAssets = juniorVault.convertToAssets(shares);
        uint256 frozenEstimate = juniorVault.estimateRedeemAssets(shares);
        assertGt(pendingFeeShares, 0, "weekend delay must accrue a maintenance fee");
        assertLt(frozenEstimate, noFrozenFeeAssets, "frozen exit fee must reduce the accrued-supply quote");

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorFundedShares, shares);
        assertEq(result.juniorFundedAssets, frozenEstimate);
        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT) - recipientSharesBefore,
            pendingFeeShares,
            "funding burn must materialize the maintenance fee exactly once"
        );
        assertEq(
            juniorVault.totalSupply(),
            rawSupplyBefore + pendingFeeShares - shares,
            "maintenance dilution and frozen redemption burn must compose exactly"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);

        uint256 rawSupplyAfterFunding = juniorVault.totalSupply();
        vm.prank(incumbent);
        uint256 redeemedAssets = juniorVault.claimRedeem(requestId, shares, incumbent, incumbent);
        assertEq(redeemedAssets, frozenEstimate);
        assertEq(juniorVault.totalSupply(), rawSupplyAfterFunding, "funded claim cannot burn or checkpoint again");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientSharesBefore + pendingFeeShares);
    }

    function test_FrozenLpClaims_CannotBypassAsyncRequestsAndPreviewsStayDisabled() public {
        address lp = address(0xB0C);
        uint256 shares = 10_000e9;

        _fundJunior(lp, 500_000e6);
        _fundSenior(address(0xD00E), 500_000e6);
        _enterFrozenWindow();

        assertEq(juniorVault.maxRedeem(lp), 0, "No redeem claim should exist before an async request settles");
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, lp, shares, 0));
        juniorVault.redeem(shares, lp, lp);

        vm.expectRevert(TrancheVault.TrancheVault__AsyncPreviewUnavailable.selector);
        juniorVault.previewDeposit(1e6);
        vm.expectRevert(TrancheVault.TrancheVault__AsyncPreviewUnavailable.selector);
        juniorVault.previewMint(shares);
        vm.expectRevert(TrancheVault.TrancheVault__AsyncPreviewUnavailable.selector);
        juniorVault.previewWithdraw(1e6);
        vm.expectRevert(TrancheVault.TrancheVault__AsyncPreviewUnavailable.selector);
        juniorVault.previewRedeem(shares);
    }

    function test_FadOnlyShoulder_DoesNotActivateFrozenFee() public {
        vm.warp(SUNDAY_FAD_ONLY);

        assertTrue(engine.isFadWindow(), "setup should remain inside FAD");
        assertFalse(engine.isOracleFrozen(), "setup should be after the oracle-frozen window");
        assertEq(pool.frozenLpFeeBps(true), 0, "Senior fee should be disabled when only FAD is active");
        assertEq(pool.frozenLpFeeBps(false), 0, "Junior fee should be disabled when only FAD is active");
    }

    function test_FrozenWindow_EstimateWithdrawMatchesSettledClaim() public {
        address lp = address(0xCAFE);
        uint256 netAssets = 100_000e6;

        _fundJunior(lp, 500_000e6);
        _enterFrozenWindow();

        uint256 quotedShares = juniorVault.estimateWithdrawShares(netAssets);
        uint256 balanceBefore = usdc.balanceOf(lp);
        uint256 consumedShares = _asyncWithdraw(juniorVault, lp, netAssets, quotedShares + 1e9);

        assertGe(consumedShares, quotedShares, "Delayed withdrawal may consume more shares after junior coupon funding");
        assertEq(usdc.balanceOf(lp), balanceBefore + netAssets, "Withdraw claim should transfer the requested assets");
    }

    function test_GovernedFrozenFeeUpdate_FlowsThroughFrozenExitPricing() public {
        address lp = address(0x1234);
        uint256 shares = 100_000e9;

        _fundSenior(lp, 500_000e6);
        _fundJunior(address(0xA11CE), 500_000e6);
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        _enterFrozenWindow();

        uint256 requestId = _requestRedeem(seniorVault, lp, shares);
        _prepareFrozenEpoch(requestId);
        uint256 maturedEstimate = seniorVault.estimateRedeemAssets(shares);
        uint256 noFeeAssets = seniorVault.convertToAssets(shares);
        uint256 seniorPriceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        _settleLpEpochForTest();
        vm.prank(lp);
        uint256 redeemedAssets = seniorVault.claimRedeem(requestId, shares, lp, lp);

        uint256 seniorPriceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();

        assertEq(pool.frozenLpFeeBps(true), 40, "Updated governed senior frozen fee should become active");
        assertEq(redeemedAssets, maturedEstimate, "Matured governed exit estimate should match settlement");
        assertLt(redeemedAssets, noFeeAssets, "Updated governed fee should reduce the frozen exit payout");
        assertGt(seniorPriceAfter, seniorPriceBefore, "Retained exit fee should benefit remaining Senior shares");
        assertEq(juniorPriceAfter, juniorPriceBefore, "Senior frozen exit fee must remain tranche-local");
    }

    function test_FrozenWithdrawFee_RemainsJuniorLocal() public {
        address juniorLp = address(0xFADE);
        address seniorLp = address(0xFACE);
        uint256 netAssets = 100_000e6;

        _fundJunior(juniorLp, 500_000e6);
        _fundSenior(seniorLp, 500_000e6);
        _enterFrozenWindow();

        uint256 quotedShares = juniorVault.estimateWithdrawShares(netAssets);
        uint256 requestId = _requestRedeem(juniorVault, juniorLp, quotedShares + 1e9);
        _prepareFrozenEpoch(requestId);
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 seniorPriceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        _settleLpEpochForTest();
        assertGe(juniorVault.maxWithdraw(juniorLp), netAssets, "settlement must fund the requested withdrawal");
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

    function test_FrozenWindow_MaxWithdraw_ExposesSettledNetPayout() public {
        address lp = address(0xAAA7);
        _fundSenior(lp, 500_000e6);
        _fundJunior(address(0xAAA8), 500_000e6);
        _enterFrozenWindow();

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 25;
        config.juniorFrozenLpFeeBps = 75;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();
        _enterFrozenWindow();

        uint256 requestedShares = seniorVault.maxRequestRedeem(lp);
        assertEq(seniorVault.maxWithdraw(lp), 0, "maxWithdraw should be zero until the request is funded");

        uint256 requestId = _requestRedeem(seniorVault, lp, requestedShares);
        _prepareFrozenEpoch(requestId);
        uint256 estimatedFullAssets = seniorVault.estimateRedeemAssets(requestedShares);
        (,, uint256 poolCap,) = pool.getPendingTrancheState();
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        uint256 quotedAssets = seniorVault.maxWithdraw(lp);
        uint256 expectedAssets = estimatedFullAssets < poolCap ? estimatedFullAssets : poolCap;

        assertEq(quotedAssets, result.seniorFundedAssets, "maxWithdraw should expose funded claim escrow");
        assertLe(quotedAssets, expectedAssets, "Settled assets must respect both owner value and the pool budget");

        uint256 balanceBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        seniorVault.withdraw(quotedAssets, lp, lp);
        assertEq(usdc.balanceOf(lp), balanceBefore + quotedAssets, "Withdraw should claim the quoted funded assets");
    }

    function test_FrozenWindow_MaxRedeem_ExposesSettledFundedShares() public {
        address lp = address(0xAAA9);
        _fundJunior(lp, 500_000e6);
        _fundSenior(address(0xAABA), 500_000e6);
        _enterFrozenWindow();

        uint256 poolCap = pool.getMaxJuniorWithdraw();
        uint256 ownerShares = juniorVault.maxRequestRedeem(lp);
        uint256 estimatedFullAssets = juniorVault.estimateRedeemAssets(ownerShares);
        assertEq(juniorVault.maxRedeem(lp), 0, "maxRedeem should be zero until the request is funded");

        uint256 requestId = _requestRedeem(juniorVault, lp, ownerShares);
        IHousePool.LpEpochSettlementResult memory result = _settleFrozenEpoch(requestId);
        uint256 quotedShares = juniorVault.maxRedeem(lp);
        uint256 expectedAssetCap = estimatedFullAssets < poolCap ? estimatedFullAssets : poolCap;

        assertEq(quotedShares, result.juniorFundedShares, "maxRedeem should expose funded request shares");
        assertLe(
            result.juniorFundedAssets, expectedAssetCap, "Funded redeem assets must respect the frozen pool budget"
        );

        uint256 balanceBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 redeemedAssets = juniorVault.redeem(quotedShares, lp, lp);
        assertEq(redeemedAssets, result.juniorFundedAssets, "Redeem should consume the funded epoch payout");
        assertEq(usdc.balanceOf(lp), balanceBefore + redeemedAssets, "Redeem should claim the quoted funded assets");
    }

    function _requestRedeem(
        TrancheVault vault,
        address lp,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(lp);
        requestId = vault.requestRedeem(shares, lp, lp);
    }

    function _settleFrozenEpoch(
        uint256 requestId
    ) internal returns (IHousePool.LpEpochSettlementResult memory result) {
        _prepareFrozenEpoch(requestId);
        result = _settleLpEpochForTest();
    }

    function _prepareFrozenEpoch(
        uint256 requestId
    ) internal {
        uint256 activationTime = pool.lpEpochStart(requestId);
        if (block.timestamp < activationTime) {
            vm.warp(activationTime);
        }
        assertTrue(engine.isOracleFrozen(), "request must mature while the frozen fee is active");
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

    function _asyncWithdraw(
        TrancheVault vault,
        address lp,
        uint256 assets,
        uint256 requestedShares
    ) internal returns (uint256 shares) {
        uint256 requestId = _requestRedeem(vault, lp, requestedShares);
        assertEq(vault.maxWithdraw(lp), 0, "withdraw claim must remain unavailable before settlement");
        _prepareFrozenEpoch(requestId);
        uint256 maturedEstimate = vault.estimateWithdrawShares(assets);
        _settleLpEpochForTest();
        assertGe(vault.maxWithdraw(lp), assets, "settlement should fund the requested net withdrawal");
        vm.prank(lp);
        shares = vault.withdraw(assets, lp, lp);
        assertApproxEqAbs(
            shares,
            maturedEstimate,
            1e6,
            "matured frozen withdraw estimate should match the settled claim ratio up to rounding dust"
        );
    }

    function _enableJuniorMaintenanceFee() internal {
        juniorVault.proposeMaintenanceFeeConfig(MAINTENANCE_FEE_APR_BPS, MAINTENANCE_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
    }

}
