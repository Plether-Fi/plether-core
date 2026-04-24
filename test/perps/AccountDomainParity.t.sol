// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "../../src/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AccountDomainParityTest is BasePerpTest {

    function test_DomainHelpers_SeparateGenericAndTerminalReachability() public pure {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 12_000e6,
            totalLockedMarginUsdc: 9000e6,
            activePositionMarginUsdc: 3000e6,
            otherLockedMarginUsdc: 6000e6,
            freeSettlementUsdc: 3000e6
        });

        assertEq(buckets.settlementBalanceUsdc, 12_000e6);
        assertEq(buckets.freeSettlementUsdc, 3000e6);
        assertEq(buckets.activePositionMarginUsdc, 3000e6);
        assertEq(buckets.otherLockedMarginUsdc, 6000e6);
        assertEq(MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets), 6000e6);
        assertEq(MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets), 12_000e6);
    }

    function test_AccountCollateralView_UsesNamedDomains() public {
        address trader = address(0xD011A1);
        address account = trader;
        address counterparty = address(0xD011A2);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 2000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        CfdEngine.AccountCollateralView memory collateralView = engineAccountLens.getAccountCollateralView(account);

        assertEq(
            collateralView.settlementBalanceUsdc,
            buckets.settlementBalanceUsdc,
            "Collateral view settlement balance should come from the named domain"
        );
        assertEq(
            collateralView.freeSettlementUsdc,
            buckets.freeSettlementUsdc,
            "Collateral view free settlement should come from the named domain"
        );
        assertEq(
            collateralView.activePositionMarginUsdc,
            buckets.activePositionMarginUsdc,
            "Collateral view position margin should come from the named domain"
        );
        assertEq(
            collateralView.otherLockedMarginUsdc,
            buckets.otherLockedMarginUsdc,
            "Collateral view queued reservations should come from the named domain"
        );
        assertEq(
            collateralView.closeReachableUsdc,
            buckets.freeSettlementUsdc,
            "Close reachability should remain free settlement only"
        );
        assertEq(
            collateralView.terminalReachableUsdc,
            MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets),
            "Terminal reachability should come from the named domain helper"
        );
        assertLt(
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets),
            collateralView.terminalReachableUsdc,
            "Queued reservations should distinguish generic from terminal reachability"
        );
    }

    function test_WithdrawableParity_UsesCanonicalAccountDomainLogic() public {
        address trader = address(0xD011A3);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 accountLensWithdrawable = engineAccountLens.getWithdrawableUsdc(account);
        uint256 publicLensWithdrawable = publicLens.getTraderAccount(account).withdrawableUsdc;

        assertEq(
            publicLensWithdrawable,
            accountLensWithdrawable,
            "Public/account withdrawable views should share the same canonical account-domain logic"
        );
    }

    function test_WithdrawableParity_UsesSharedFreshnessPolicyWhenPoolLimitIsTighter() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 30;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        address trader = address(0xD011A4);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(block.timestamp + 31);

        assertEq(engineAccountLens.getWithdrawableUsdc(account), 0, "Account lens should honor tighter pool freshness");
        assertEq(
            publicLens.getTraderAccount(account).withdrawableUsdc,
            0,
            "Public lens should inherit account-lens freshness"
        );

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(account, 1);
    }

}
