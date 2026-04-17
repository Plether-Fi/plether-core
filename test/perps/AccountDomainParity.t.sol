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

        assertEq(MarginClearinghouseAccountingLib.getSettlementBalanceUsdc(buckets), 12_000e6);
        assertEq(MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets), 3000e6);
        assertEq(MarginClearinghouseAccountingLib.getPositionMarginUsdc(buckets), 3000e6);
        assertEq(MarginClearinghouseAccountingLib.getQueuedReservedUsdc(buckets), 6000e6);
        assertEq(MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets), 6000e6);
        assertEq(MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets), 12_000e6);
    }

    function test_AccountCollateralView_UsesNamedDomains() public {
        address trader = address(0xD011A1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0xD011A2);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 2000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        CfdEngine.AccountCollateralView memory collateralView = engineAccountLens.getAccountCollateralView(accountId);

        assertEq(
            collateralView.settlementBalanceUsdc,
            MarginClearinghouseAccountingLib.getSettlementBalanceUsdc(buckets),
            "Collateral view settlement balance should come from the named domain helper"
        );
        assertEq(
            collateralView.freeSettlementUsdc,
            MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets),
            "Collateral view free settlement should come from the named domain helper"
        );
        assertEq(
            collateralView.activePositionMarginUsdc,
            MarginClearinghouseAccountingLib.getPositionMarginUsdc(buckets),
            "Collateral view position margin should come from the named domain helper"
        );
        assertEq(
            collateralView.otherLockedMarginUsdc,
            MarginClearinghouseAccountingLib.getQueuedReservedUsdc(buckets),
            "Collateral view queued reservations should come from the named domain helper"
        );
        assertEq(
            collateralView.closeReachableUsdc,
            MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets),
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 accountLensWithdrawable = engineAccountLens.getWithdrawableUsdc(accountId);
        uint256 publicLensWithdrawable = publicLens.getTraderAccount(accountId).withdrawableUsdc;

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
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(block.timestamp + 31);

        assertEq(
            engineAccountLens.getWithdrawableUsdc(accountId), 0, "Account lens should honor tighter pool freshness"
        );
        assertEq(
            publicLens.getTraderAccount(accountId).withdrawableUsdc,
            0,
            "Public lens should inherit account-lens freshness"
        );

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(accountId, 1);
    }

}
