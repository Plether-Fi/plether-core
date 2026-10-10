// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: differential. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#3-canonical-lp-reconciliation-and-share-pricing-view

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract PendingDepositLifecycleNavTest is BasePerpTest {

    /// @dev differential; source: ACCOUNTING_SPEC.md#3-canonical-lp-reconciliation-and-share-pricing-view.
    function test_DepositPricingMatchesWithdrawalNavForDeltaNeutralExposure() public {
        uint256 revenueUsdc = 500_000e6;
        usdc.mint(address(pool), revenueUsdc);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            revenueUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        uint256 depositUsdc = 300_000e6;
        address long = address(0xB011);
        address short = address(0xBEA2);
        uint256 size = 400_000e18;
        _fundTrader(long, 20_000e6);
        _fundTrader(short, 20_000e6);
        _open(long, CfdTypes.Side.LONG, size, 20_000e6, 1e8);
        _open(short, CfdTypes.Side.SHORT, size, 20_000e6, 1e8);

        (, uint256 depositJuniorAssets) = pool.getPendingDepositTrancheState();
        uint256 withdrawalJuniorAssets = juniorVault.totalAssets();

        assertEq(
            depositJuniorAssets,
            withdrawalJuniorAssets,
            "entry and exit must use the same terminal NAV for delta-neutral exposure"
        );
        assertEq(
            juniorVault.estimateDepositShares(depositUsdc),
            juniorVault.quoteDepositFromState(depositUsdc, withdrawalJuniorAssets, juniorVault.totalSupply(), 0),
            "deposit quote must use the shared terminal NAV"
        );
    }

    /// @dev differential; source: ACCOUNTING_SPEC.md#3-canonical-lp-reconciliation-and-share-pricing-view.
    function test_DepositPricingMatchesWithdrawalNavAfterUnrealizedProfit() public {
        uint256 depositUsdc = 300_000e6;
        uint256 sharesBeforeMtm = juniorVault.estimateDepositShares(depositUsdc);
        uint256 juniorAssetsBeforeMtm = juniorVault.totalAssets();

        address long = address(0xB012);
        address short = address(0xBEA3);
        uint256 size = 300_000e18;
        _fundTrader(long, 20_000e6);
        _fundTrader(short, 20_000e6);
        _open(long, CfdTypes.Side.LONG, size, 20_000e6, 1e8);
        _open(short, CfdTypes.Side.SHORT, size, 20_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(120_000_000, uint64(block.timestamp));

        (, uint256 depositJuniorAssets) = pool.getPendingDepositTrancheState();
        uint256 withdrawalJuniorAssets = juniorVault.totalAssets();

        assertEq(
            depositJuniorAssets,
            withdrawalJuniorAssets,
            "entry and exit must use the same terminal NAV after unrealized trader profit"
        );
        assertLt(
            withdrawalJuniorAssets,
            juniorAssetsBeforeMtm,
            "unrealized trader profit must reduce the shared junior terminal NAV"
        );
        assertGt(
            juniorVault.estimateDepositShares(depositUsdc),
            sharesBeforeMtm,
            "new deposits must receive more shares at the same impaired NAV used for exits"
        );
        assertEq(
            juniorVault.estimateDepositShares(depositUsdc),
            juniorVault.quoteDepositFromState(depositUsdc, withdrawalJuniorAssets, juniorVault.totalSupply(), 0),
            "deposit quote must use the shared terminal NAV"
        );
    }

    /// @dev differential; source: ACCOUNTING_SPEC.md#3-canonical-lp-reconciliation-and-share-pricing-view.
    function test_DepositPricingAllowsDiscountedSharesAfterRealJuniorLoss() public {
        uint256 depositUsdc = 100_000e6;
        uint256 sharesBeforeLoss = juniorVault.estimateDepositShares(depositUsdc);

        vm.prank(address(engine));
        pool.payOut(address(0xD15C0), 200_000e6);

        assertGt(
            juniorVault.estimateDepositShares(depositUsdc),
            sharesBeforeLoss,
            "real junior losses should mint at the impaired NAV, not a hard 1.0 floor"
        );
    }

}

contract DeltaNeutralDepositNavTest is BasePerpTest {

    address longTrader = address(0xB011);
    address shortTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev differential; source: ACCOUNTING_SPEC.md#3-canonical-lp-reconciliation-and-share-pricing-view.
    function test_DeltaNeutralZeroPnlCannotDiscountNewJuniorDeposits() public {
        uint256 depositAssets = 100_000e6;
        uint256 baselineShares = juniorVault.estimateDepositShares(depositAssets);

        _fundTrader(longTrader, 25_000e6);
        _fundTrader(shortTrader, 25_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);
        _open(shortTrader, CfdTypes.Side.SHORT, 200_000e18, 10_000e6, 1e8);

        assertEq(_unrealizedTraderPnl(), 0, "Equal and opposite positions opened at the mark have zero current PnL");

        uint256 sharesAfterNeutralOpen = juniorVault.estimateDepositShares(depositAssets);
        assertLe(
            sharesAfterNeutralOpen,
            baselineShares,
            "Zero-PnL delta-neutral exposure must not let new LPs mint discounted junior shares"
        );
    }

}
