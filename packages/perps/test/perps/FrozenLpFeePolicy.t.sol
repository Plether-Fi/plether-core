// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract FrozenLpFeePolicyTest is BasePerpTest {

    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600;
    uint256 internal constant SUNDAY_FAD_ONLY = 1_710_105_000;

    function _enterFrozenWindow() internal {
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));
    }

    function _applyFee(
        uint256 assets,
        uint256 feeBps
    ) internal pure returns (uint256) {
        return (assets * (10_000 - feeBps)) / 10_000;
    }

    function test_SeniorDeposit_ChargesFrozenFeeAndBenefitsIncumbents() public {
        address incumbent = address(0xA11CE);
        address entrant = address(0xBEEF);
        uint256 assets = 100_000e6;

        _fundSenior(incumbent, 500_000e6);
        _fundJunior(address(0xC0FFEE), 500_000e6);
        _enterFrozenWindow();

        uint256 quotedShares = seniorVault.estimateDepositShares(assets);
        uint256 requestId = _requestDeposit(seniorVault, entrant, assets);
        _prepareFrozenEpoch(requestId);
        uint256 priceBefore = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceBefore = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();
        uint256 noFeeShares = seniorVault.convertToShares(assets);
        uint256 maturedEstimate = seniorVault.estimateDepositShares(assets);
        pool.settleLpEpoch();
        vm.prank(entrant);
        uint256 mintedShares = seniorVault.claimDeposit(requestId, assets, entrant, entrant);

        uint256 priceAfter = (seniorVault.totalAssets() * 1e18) / seniorVault.totalSupply();
        uint256 juniorPriceAfter = (juniorVault.totalAssets() * 1e18) / juniorVault.totalSupply();

        assertEq(pool.frozenLpFeeBps(true), 25, "Senior frozen LP fee should be 25 bps");
        assertEq(mintedShares, maturedEstimate, "Matured frozen estimate should match synchronized settlement");
        assertLe(mintedShares, quotedShares, "Senior coupon accrual may only lower the nonbinding entry estimate");
        assertLt(mintedShares, noFeeShares, "Frozen senior deposit should mint fewer shares than no-fee pricing");
        assertGt(priceAfter, priceBefore, "Frozen senior deposit fee should improve incumbent share price");
        assertEq(juniorPriceAfter, juniorPriceBefore, "Senior frozen fee should not reprice the junior tranche");
    }

    function test_FrozenDeposit_FeesSharesWithoutLeakingBackToLargeEntrant() public {
        address incumbent = address(0xAAA1);
        address entrant = address(0xAAA2);
        uint256 assets = 10_000_000e6;

        _fundSenior(incumbent, 100_000e6);
        _fundJunior(address(0xAAA3), 100_000e6);
        _enterFrozenWindow();

        uint256 frozenFeeBps = pool.frozenLpFeeBps(true);
        uint256 grossShares = seniorVault.convertToShares(assets);
        uint256 expectedNetAssets = _applyFee(assets, frozenFeeBps);
        uint256 mintedShares = _asyncDeposit(seniorVault, entrant, assets);
        uint256 entrantGrossClaimAfter = seniorVault.convertToAssets(mintedShares);

        assertLt(mintedShares, grossShares, "Frozen deposit should still mint fewer shares than no-fee pricing");
        assertLe(
            entrantGrossClaimAfter,
            expectedNetAssets,
            "Large entrant should not recapture the frozen fee through post-deposit share-price uplift"
        );
    }

    function test_FrozenDeposit_RetainedFeeNumericallyBenefitsIncumbentOnly() public {
        address incumbent = address(0xAAB1);
        address entrant = address(0xAAB2);
        uint256 incumbentAssets = 100_000e6;
        uint256 entrantAssets = 100_000e6;

        _fundSenior(incumbent, incumbentAssets);
        _fundJunior(address(0xAAB3), 100_000e6);
        _enterFrozenWindow();

        uint256 frozenFeeBps = pool.frozenLpFeeBps(true);
        uint256 expectedNetAssets = _applyFee(entrantAssets, frozenFeeBps);
        uint256 incumbentClaimBefore = seniorVault.convertToAssets(seniorVault.balanceOf(incumbent));

        uint256 mintedShares = _asyncDeposit(seniorVault, entrant, entrantAssets);

        uint256 entrantGrossClaimAfter = seniorVault.convertToAssets(mintedShares);
        uint256 incumbentClaimAfter = seniorVault.convertToAssets(seniorVault.balanceOf(incumbent));

        assertLe(
            entrantGrossClaimAfter,
            expectedNetAssets,
            "Entrant should not recapture the retained frozen fee through ownership leakage"
        );
        assertGt(incumbentClaimAfter, incumbentClaimBefore, "Retained frozen fee should increase incumbent gross claim");
    }

    function testFuzz_FrozenDeposit_EntrantClaimNeverExceedsNetAssets(
        uint256 incumbentAssetsFuzz,
        uint256 entrantAssetsFuzz
    ) public {
        address incumbent = address(0xAAB8);
        address entrant = address(0xAAB9);
        uint256 incumbentAssets = bound(incumbentAssetsFuzz, 1e6, 2_000_000e6);
        uint256 entrantAssets = bound(entrantAssetsFuzz, 1e6, 20_000_000e6);

        _fundSenior(incumbent, incumbentAssets);
        _fundJunior(address(0xAAC0), incumbentAssets);
        _enterFrozenWindow();

        uint256 feeBps = pool.frozenLpFeeBps(true);
        uint256 estimatedShares = seniorVault.estimateDepositShares(entrantAssets);
        uint256 expectedNetAssets = _applyFee(entrantAssets, feeBps);
        uint256 incumbentClaimBefore = seniorVault.convertToAssets(seniorVault.balanceOf(incumbent));

        uint256 mintedShares = _asyncDeposit(seniorVault, entrant, entrantAssets);

        uint256 entrantGrossClaimAfter = seniorVault.convertToAssets(mintedShares);
        uint256 incumbentClaimAfter = seniorVault.convertToAssets(seniorVault.balanceOf(incumbent));

        assertLe(
            mintedShares,
            estimatedShares,
            "Senior coupon accrual may only lower the nonbinding estimate across bounded states"
        );
        assertLe(
            entrantGrossClaimAfter,
            expectedNetAssets,
            "Entrant gross claim should never exceed net assets after the frozen fee"
        );
        assertGe(
            incumbentClaimAfter, incumbentClaimBefore, "Incumbent claim should not fall when the entrant pays the fee"
        );
    }

    function test_FrozenDeposit_DustDepositStillKeepsFeeWithIncumbents() public {
        address incumbent = address(0xAAC1);
        address entrant = address(0xAAC2);
        uint256 entrantAssets = 1e6;

        _fundSenior(incumbent, 2e6);
        _fundJunior(address(0xAAC3), 2e6);
        _enterFrozenWindow();

        uint256 feeBps = pool.frozenLpFeeBps(true);
        uint256 estimatedShares = seniorVault.estimateDepositShares(entrantAssets);
        uint256 expectedNetAssets = _applyFee(entrantAssets, feeBps);

        uint256 mintedShares = _asyncDeposit(seniorVault, entrant, entrantAssets);
        uint256 entrantGrossClaimAfter = seniorVault.convertToAssets(mintedShares);

        assertLe(mintedShares, estimatedShares, "Dust settlement may reflect senior coupon accrued while pending");
        assertGt(mintedShares, 0, "Dust frozen deposit should still mint shares above the virtual offset floor");
        assertLe(
            entrantGrossClaimAfter,
            expectedNetAssets,
            "Dust entrant should not recover more than the intended net assets through share-price uplift"
        );
    }

    function test_FrozenMint_GrossesUpSharesFeeAndHonorsEstimate() public {
        address lp = address(0xAAA4);
        uint256 targetShares = 100_000e9;

        _fundSenior(address(0xAAA5), 500_000e6);
        _fundJunior(address(0xAAA6), 500_000e6);
        _enterFrozenWindow();

        uint256 quotedAssets = seniorVault.estimateMintAssets(targetShares);
        uint256 noFeeAssets = seniorVault.convertToAssets(targetShares);
        uint256 requestedAssets = quotedAssets + (quotedAssets / 1000) + 1;
        uint256 chargedAssets = _asyncMint(seniorVault, lp, targetShares, requestedAssets);

        assertGe(chargedAssets, quotedAssets, "A delayed mint claim must include intervening senior coupon accrual");
        assertLe(chargedAssets, requestedAssets, "Mint claim must not consume more than its escrowed request basis");
        assertGt(chargedAssets, noFeeAssets, "Frozen mint should charge more assets than no-fee mint pricing");
        assertEq(seniorVault.balanceOf(lp), targetShares, "Frozen mint should deliver the requested net shares");
    }

    function test_FrozenMint_EstimateCapsFiniteFeeAsymptote() public {
        address lp = address(0xAAA7);

        _fundSenior(address(0xAAA8), 500_000e6);
        _fundJunior(address(0xAAA9), 500_000e6);
        _enterFrozenWindow();

        uint256 capacity = seniorVault.maxRequestDeposit(lp);
        uint256 maxEstimatedShares = seniorVault.estimateDepositShares(capacity);
        uint256 maxAssets = seniorVault.estimateMintAssets(maxEstimatedShares);
        uint256 nextAssets = seniorVault.estimateMintAssets(maxEstimatedShares + 1);

        uint256 feeBps = pool.frozenLpFeeBps(true);
        uint256 adjustedShares = seniorVault.totalSupply() + 10 ** (seniorVault.decimals() - usdc.decimals());
        uint256 feeAsymptoteNumerator = adjustedShares * (10_000 - feeBps);
        uint256 feeAsymptoteShares = feeAsymptoteNumerator / feeBps;
        if (feeAsymptoteNumerator % feeBps == 0) {
            feeAsymptoteShares -= 1;
        }

        assertEq(seniorVault.maxMint(lp), 0, "maxMint must expose claims, not request capacity");
        assertGt(maxEstimatedShares, 0, "Frozen request capacity should imply bounded estimated shares");
        assertLe(
            maxEstimatedShares,
            feeAsymptoteShares,
            "Frozen estimated shares should remain bounded by the finite fee asymptote"
        );
        assertLe(maxAssets, capacity, "The largest estimated share target should fit gross request capacity");
        assertGt(nextAssets, capacity, "One share past the request-cap estimate should exceed gross capacity");
        assertLt(
            seniorVault.estimateMintAssets(feeAsymptoteShares),
            type(uint256).max,
            "The final share at the frozen-fee asymptote should remain estimable"
        );
        assertEq(
            seniorVault.estimateMintAssets(feeAsymptoteShares + 1),
            type(uint256).max,
            "Estimate past the frozen-fee asymptote should not underflow the pricing denominator"
        );
    }

    function test_FrozenDepositAndMint_MatchEquivalentNetOwnership() public {
        address depositLp = address(0xAAB4);
        address mintLp = address(0xAAB5);
        uint256 assets = 100_000e6;

        _fundSenior(address(0xAAB6), 500_000e6);
        _fundJunior(address(0xAAB7), 500_000e6);
        _enterFrozenWindow();

        uint256 snap = vm.snapshotState();
        uint256 depositEstimatedShares = seniorVault.estimateDepositShares(assets);
        uint256 depositShares = _asyncDeposit(seniorVault, depositLp, assets);

        vm.revertToState(snap);
        uint256 mintEstimatedAssets = seniorVault.estimateMintAssets(depositShares);
        uint256 mintAssets = _asyncMint(seniorVault, mintLp, depositShares, assets);

        assertLe(depositShares, depositEstimatedShares, "Deposit settlement may include pending senior coupon accrual");
        assertEq(
            depositShares, seniorVault.balanceOf(mintLp), "Mint path should deliver the same net share ownership target"
        );
        assertEq(mintAssets, assets, "Equivalent all-share mint claim should consume the same escrowed asset basis");
        assertLe(mintEstimatedAssets, mintAssets, "Request-time mint estimate remains explicitly nonbinding");
    }

    function testFuzz_FrozenDepositAndMint_MatchEquivalentNetOwnershipAcrossAsymmetricStates(
        uint256 seniorSeedFuzz,
        uint256 juniorSeedFuzz,
        uint256 assetsFuzz
    ) public {
        address depositLp = address(0xAAC4);
        address mintLp = address(0xAAC5);
        uint256 seniorSeed = bound(seniorSeedFuzz, 10_000e6, 2_000_000e6);
        uint256 juniorSeed = bound(juniorSeedFuzz, 10_000e6, 2_000_000e6);
        uint256 assets = bound(assetsFuzz, 1e6, 500_000e6);

        _fundSenior(address(0xAAC6), seniorSeed);
        _fundJunior(address(0xAAC7), juniorSeed);
        _enterFrozenWindow();

        uint256 snap = vm.snapshotState();
        uint256 depositEstimatedShares = seniorVault.estimateDepositShares(assets);
        uint256 depositShares = _asyncDeposit(seniorVault, depositLp, assets);

        vm.revertToState(snap);
        uint256 mintEstimatedAssets = seniorVault.estimateMintAssets(depositShares);
        uint256 mintAssets = _asyncMint(seniorVault, mintLp, depositShares, assets);

        assertEq(
            depositShares,
            seniorVault.balanceOf(mintLp),
            "Deposit and mint claims should deliver the same settled ownership across asymmetric states"
        );
        assertLe(depositShares, depositEstimatedShares, "Pending senior coupon may lower the request-time estimate");
        assertEq(mintAssets, assets, "Equivalent mint claim should consume the same escrowed asset basis");
        assertLe(mintEstimatedAssets, mintAssets, "Request-time mint estimate remains nonbinding across states");
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
        pool.settleLpEpoch();
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

    function test_GovernedFrozenFeeUpdate_FlowsThroughFrozenPricing() public {
        address lp = address(0x1234);
        uint256 assets = 100_000e6;

        _fundSenior(address(0xA11CE), 500_000e6);
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        _enterFrozenWindow();

        uint256 quotedShares = seniorVault.estimateDepositShares(assets);
        uint256 noFeeShares = seniorVault.convertToShares(assets);
        uint256 expectedNetAssets = _applyFee(assets, 40);
        uint256 mintedShares = _asyncDeposit(seniorVault, lp, assets);
        uint256 entrantGrossClaimAfter = seniorVault.convertToAssets(mintedShares);

        assertEq(pool.frozenLpFeeBps(true), 40, "Updated governed senior frozen fee should become active");
        assertLe(mintedShares, quotedShares, "Governed entry estimate remains nonbinding while senior coupon accrues");
        assertLt(
            mintedShares, noFeeShares, "Updated governed fee should still discount minted shares versus no-fee pricing"
        );
        assertLe(
            entrantGrossClaimAfter,
            expectedNetAssets,
            "Governed frozen fee should still stay with incumbents rather than leaking back to the entrant"
        );
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
        pool.settleLpEpoch();
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
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch();
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

    function _requestDeposit(
        TrancheVault vault,
        address lp,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(lp, assets);
        vm.startPrank(lp);
        usdc.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, lp, lp);
        vm.stopPrank();
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
        result = pool.settleLpEpoch();
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

    function _asyncDeposit(
        TrancheVault vault,
        address lp,
        uint256 assets
    ) internal returns (uint256 shares) {
        uint256 requestId = _requestDeposit(vault, lp, assets);
        assertEq(vault.maxDeposit(lp), 0, "deposit claim must remain unavailable before settlement");
        _prepareFrozenEpoch(requestId);
        uint256 maturedEstimate = vault.estimateDepositShares(assets);
        pool.settleLpEpoch();
        assertEq(vault.maxDeposit(lp), assets, "settlement should make the full deposit basis claimable");
        vm.prank(lp);
        shares = vault.claimDeposit(requestId, assets, lp, lp);
        assertEq(shares, maturedEstimate, "matured frozen entry estimate must match synchronized settlement");
    }

    function _asyncMint(
        TrancheVault vault,
        address lp,
        uint256 shares,
        uint256 requestedAssets
    ) internal returns (uint256 claimedAssets) {
        uint256 requestId = _requestDeposit(vault, lp, requestedAssets);
        assertEq(vault.maxMint(lp), 0, "mint claim must remain unavailable before settlement");
        _settleFrozenEpoch(requestId);
        assertGe(vault.maxMint(lp), shares, "settlement should fund the requested net share target");
        vm.prank(lp);
        claimedAssets = vault.mint(shares, lp);
    }

    function _asyncRedeem(
        TrancheVault vault,
        address lp,
        uint256 shares
    ) internal returns (uint256 assets) {
        uint256 requestId = _requestRedeem(vault, lp, shares);
        assertEq(vault.maxRedeem(lp), 0, "redeem claim must remain unavailable before settlement");
        _prepareFrozenEpoch(requestId);
        uint256 maturedEstimate = vault.estimateRedeemAssets(shares);
        pool.settleLpEpoch();
        assertEq(vault.maxRedeem(lp), shares, "settlement should fund the full redeem request");
        vm.prank(lp);
        assets = vault.claimRedeem(requestId, shares, lp, lp);
        assertEq(assets, maturedEstimate, "matured frozen exit estimate must match synchronized settlement");
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
        pool.settleLpEpoch();
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

}
