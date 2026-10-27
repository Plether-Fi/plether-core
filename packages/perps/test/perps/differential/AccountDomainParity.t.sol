// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

contract AccountDomainParityTest is BasePerpTest {

    function test_DomainHelpers_SeparateGenericAndTerminalReachability() public pure {
        IMarginClearinghouse.AccountAssetBuckets memory buckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: 12_000e6,
            totalLockedMarginAssets: 9000e6,
            activePositionMarginAssets: 3000e6,
            otherLockedMarginAssets: 6000e6,
            freeSettlementAssets: 3000e6
        });

        assertEq(buckets.settlementBalanceAssets, 12_000e6);
        assertEq(buckets.freeSettlementAssets, 3000e6);
        assertEq(buckets.activePositionMarginAssets, 3000e6);
        assertEq(buckets.otherLockedMarginAssets, 6000e6);
        assertEq(buckets.freeSettlementAssets + buckets.activePositionMarginAssets, 6000e6);
        assertEq(MarginClearinghouseAccountingLib.getTerminalReachableAssets(buckets), 12_000e6);
    }

    function test_AccountCollateralView_UsesNamedDomains() public {
        address trader = address(0xD011A1);
        address account = trader;
        address counterparty = address(0xD011A2);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(account);
        ICfdEngineTypes.AccountCollateralView memory collateralView =
            engineAccountLens.getAccountCollateralView(account);

        assertEq(
            collateralView.settlementBalanceAssets,
            buckets.settlementBalanceAssets,
            "Collateral view settlement balance should come from the named domain"
        );
        assertEq(
            collateralView.freeSettlementAssets,
            buckets.freeSettlementAssets,
            "Collateral view free settlement should come from the named domain"
        );
        assertEq(
            collateralView.activePositionMarginAssets,
            buckets.activePositionMarginAssets,
            "Collateral view position margin should come from the named domain"
        );
        assertEq(
            collateralView.otherLockedMarginAssets,
            buckets.otherLockedMarginAssets,
            "Collateral view queued reservations should come from the named domain"
        );
        assertEq(
            collateralView.closeReachableAssets,
            buckets.freeSettlementAssets,
            "Close reachability should remain free settlement only"
        );
        assertEq(
            collateralView.liquidationReachableSettlementAssets,
            buckets.settlementBalanceAssets - router.getAccountReservations(account).executionBountyAssets,
            "Liquidation settlement reachability should exclude queued execution bounty"
        );
        assertLt(
            buckets.freeSettlementAssets + buckets.activePositionMarginAssets,
            collateralView.liquidationReachableSettlementAssets,
            "Queued reservations should distinguish generic from liquidation reachability"
        );
        assertEq(
            collateralView.terminalPriceCollectibleCapAssets,
            terminalNavBook.curveOf(account).effectiveCapAssetAtoms,
            "Terminal price cap should match the canonical account curve"
        );
    }

    function test_AccountCollateralView_ClipsTerminalPriceCapToReachableEndpointLoss() public {
        address account = address(0xD011A4);
        _fundTrader(account, 300_000e6);
        _open(account, CfdTypes.Side.LONG, 1000e18, 200_000e6, 1e8);

        ICfdEngineTypes.AccountCollateralView memory collateralView =
            engineAccountLens.getAccountCollateralView(account);
        uint256 bookCapAssets = terminalNavBook.curveOf(account).effectiveCapAssetAtoms;

        assertGt(clearinghouse.pnlPledgeAssets(account), bookCapAssets, "setup must contain unreachable excess pledge");
        assertEq(
            collateralView.terminalPriceCollectibleCapAssets,
            bookCapAssets,
            "Lens cap must apply the same endpoint clipping as the terminal book"
        );
    }

    function test_WithdrawableParity_UsesCanonicalAccountDomainLogic() public {
        address trader = address(0xD011A3);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 accountLensWithdrawable = engineAccountLens.getWithdrawableAssets(account);
        uint256 publicLensWithdrawable = publicLens.getTraderAccount(account).withdrawableAssets;

        assertEq(
            publicLensWithdrawable,
            accountLensWithdrawable,
            "Public/account withdrawable views should share the same canonical account-domain logic"
        );
    }

    function test_WithdrawableParity_UsesSharedFreshnessPolicyWhenPoolLimitIsTighter() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 30;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 72 hours + 1);
        pool.finalizePoolConfig();

        address trader = address(0xD011A4);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(block.timestamp + 31);

        assertEq(
            engineAccountLens.getWithdrawableAssets(account), 0, "Account lens should honor tighter pool freshness"
        );
        assertEq(
            publicLens.getTraderAccount(account).withdrawableAssets,
            0,
            "Public lens should inherit account-lens freshness"
        );

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(account, 1);
    }

}
