// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineCollateralReservationsTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_CheckWithdraw_RevertsForNonClearinghouseCaller() public {
        address account = address(uint160(0x51582));
        _fundTrader(account, 5000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 2000e6, 1e8);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotClearinghouse.selector);
        engine.checkWithdraw(account);
    }

    function test_CloseLoss_ProtectsQueuedCommittedMarginFromPriceLossAndConsumesOnlyActionCharge() public {
        address trader = address(0xABD0);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0;
        _setRiskParams(params);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 7900e6, type(uint256).max, false);

        // Make the terminal action charge large enough to exhaust spendable action reserve and free settlement. This is separate from
        // the adverse price move: only the action slice may reach the queued committed-margin bucket.
        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(account)
            .checked_write(uint256(2500e6));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000e18,
            marginDelta: 0,
            targetPrice: 103_000_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        uint256 currentPoolDepthUsdc = pool.totalAssets();
        vm.prank(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(account, currentPoolDepthUsdc);
        CfdEnginePlanTypes.CloseDelta memory delta =
            engine.planner().planClose(snap, closeOrder, 103_000_000, uint64(block.timestamp));

        uint256 committedBefore = clearinghouse.getLockedMarginBuckets(account).committedOrderMarginUsdc;
        assertTrue(delta.valid, "Terminal close plan should remain executable");
        assertGt(delta.priceLossWrittenOffUsdc, 0, "Adverse price loss must exceed the isolated PnL pledge");
        assertGt(
            delta.actionCommittedMarginConsumedUsdc,
            0,
            "Only the independently assessed terminal action charge should reach committed margin"
        );
        assertEq(
            delta.priceLossUsdc,
            delta.pricePnlClaimConsumedUsdc + delta.pricePnlPledgeConsumedUsdc + delta.priceLossWrittenOffUsdc,
            "Price loss must conserve across claim, PnL pledge, and diagnostic write-off"
        );

        _close(account, CfdTypes.Side.LONG, 100_000 * 1e18, 103_000_000);

        assertEq(
            committedBefore - clearinghouse.getLockedMarginBuckets(account).committedOrderMarginUsdc,
            delta.actionCommittedMarginConsumedUsdc,
            "Live FIFO consumption must equal the planned action-only committed-margin slice"
        );
        assertEq(
            terminalNavBook.curveHashOf(account),
            bytes32(0),
            "Terminal settlement should remove the exact account curve after diagnostic price write-off"
        );
    }

    function test_CheckWithdraw_UsesMinimumOfEngineAndPoolMarkStalenessLimits() public {
        IHousePool.PoolConfig memory poolConfig = _currentPoolConfig();
        poolConfig.markStalenessLimit = 300;
        pool.proposePoolConfig(poolConfig);
        vm.warp(pool.poolConfigActivationTime() + 1);
        pool.finalizePoolConfig();
        assertEq(pool.markStalenessLimit(), 300);

        address account = address(uint160(0x5157));
        _fundTrader(account, 5000 * 1e6);
        uint256 openedAt = vm.getBlockTimestamp();
        _open(account, CfdTypes.Side.LONG, 20_000 * 1e18, 2000 * 1e6, 1e8);
        assertEq(engine.lastMarkTime(), openedAt, "Opening must install the current mark timestamp");

        vm.warp(openedAt + 31);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), 31, "First check must use a 31-second-old mark");

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);

        vm.warp(openedAt + 301);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), 301, "Second check must use a 301-second-old mark");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);

        ICfdEngineAdminHost.EngineFreshnessConfig memory engineConfig = _engineFreshnessConfig();
        engineConfig.engineMarkStalenessLimit = 300;
        engineAdmin.proposeFreshnessConfig(engineConfig);
        uint64 refreshedAt = uint64(engineAdmin.freshnessConfigActivationTime() + 1);
        vm.warp(refreshedAt);
        engineAdmin.finalizeFreshnessConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshedAt);
        assertEq(engine.lastMarkTime(), refreshedAt, "Post-config check must use the newly refreshed mark");
        assertEq(vm.getBlockTimestamp(), refreshedAt, "Refresh must not change the intended activation time");

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_ReserveCloseOrderExecutionBounty_AllowsStaleLastMarkPriceWhenStored() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 300;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        address trader = address(0x5159);
        address account = trader;
        address counterparty = address(0x5160);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 1500e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 10_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 31);
        uint256 reserveBeforeFresh = clearinghouse.actionReserveUsdc(account);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);
        assertEq(
            clearinghouse.actionReserveUsdc(account) - reserveBeforeFresh,
            1e6,
            "fresh sidecar path must reserve the requested bounty"
        );

        vm.warp(block.timestamp + 30 days);
        uint256 reserveBeforeStale = clearinghouse.actionReserveUsdc(account);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);
        assertEq(
            clearinghouse.actionReserveUsdc(account) - reserveBeforeStale,
            1e6,
            "stale sidecar path must reserve the requested bounty"
        );
    }

    function test_ReserveCloseOrderExecutionBounty_RevertsWhenNoStoredMarkExists() public {
        address trader = address(0x51595);
        address account = trader;
        address counterparty = address(0x51596);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 1500e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 10_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);
    }

    function test_ReserveCloseOrderExecutionBounty_ExcludesQueuedReservationsFromGenericReachability() public {
        address trader = address(0x5161);
        address account = trader;
        address counterparty = address(0x5162);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        assertEq(
            buckets.otherLockedMarginUsdc,
            4000e6 + _executionBountyReserve(1) + clearinghouse.liquidationReserveUsdc(account),
            "Other locked value must include queued margin, execution bounty, and the dedicated liquidation reserve"
        );
        assertEq(
            buckets.freeSettlementUsdc + buckets.activePositionMarginUsdc,
            buckets.settlementBalanceUsdc - buckets.otherLockedMarginUsdc,
            "Generic reachability must exclude the queued reservation"
        );

        vm.prank(address(router));
        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 6000e6);
    }

    function test_CheckWithdraw_RevertsWhenOpenPositionHasZeroMarkPrice() public {
        address account = address(uint160(0x5158));
        _fundTrader(account, 5000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_CheckWithdraw_SameAccountClaimRescuesAdverseExactPriceRiskWithoutBeingSpent() public {
        address trader = address(0x51581);
        address account = trader;
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0;
        _setRiskParams(params);
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(102_000_000, uint64(block.timestamp));
        assertEq(engine.unsettledCarryUsdc(account), 0, "Fixture must isolate exact price risk from carry");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);

        uint256 claimUsdc = 3000e6;
        _seedAuthenticatedTraderClaim(account, claimUsdc);

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
        assertEq(
            engine.traderClaimBalanceUsdc(account),
            claimUsdc,
            "Withdrawal validation may count the typed price claim but must not spend it"
        );
        assertGt(
            engineAccountLens.getWithdrawableUsdc(account),
            0,
            "Claim-rescued exact price health should expose free cash"
        );
        _assertTerminalCurveMatchesEngine(account);
    }

    function test_CheckWithdraw_UsesExplicitInitMarginBps() public {
        address trader = address(0x515815);
        address account = trader;
        _fundTrader(trader, 3200e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);

        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 300;
        _setRiskParams(params);

        (,,, uint256 initMarginBps,,,,,,) = engine.riskParams();
        assertEq(initMarginBps, 300, "Setup must finalize the explicit init margin config");

        uint64 refreshedAt = uint64(vm.getBlockTimestamp());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshedAt);
        assertEq(engine.lastMarkTime(), refreshedAt, "Init-margin rejection must use a fresh post-config mark");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(account, 200e6);
    }

    function test_CheckWithdraw_UsesActiveFadMarginRequirement() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maintMarginBps = 10;
        params.initMarginBps = 15;
        params.fadMarginBps = 1000;
        params.minBountyUsdc = 1e6;
        params.bountyBps = 1000;
        _setRiskParams(params);

        address trader = address(0x515817);
        address account = trader;
        _fundTrader(trader, 20e6);
        _open(account, CfdTypes.Side.LONG, 100e18, 16e6, 1e8);

        uint64 fadTime = 1_709_971_200;
        vm.warp(fadTime);
        assertEq(vm.getBlockTimestamp(), fadTime, "The FAD scenario must preserve its exact calendar boundary");
        assertTrue(engine.isFadWindow(), "Setup must execute inside the FAD window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, fadTime);
        assertEq(engine.lastMarkTime(), fadTime, "FAD margin rejection must use a fresh FAD mark");

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        assertEq(withdrawableUsdc, 0, "Active FAD margin must remove all withdrawal headroom");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_ReserveCloseOrderExecutionBounty_AllowsFullCloseNearMaintenance() public {
        address trader = address(0x515991);
        address account = trader;
        address counterparty = address(0x515992);
        address counterpartyAccount = counterparty;
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, size, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, size, 1e6);
        assertEq(clearinghouse.actionReserveUsdc(account), 1e6);
    }

    function test_ReserveCloseOrderExecutionBounty_PartialCloseStillRevertsNearMaintenance() public {
        address trader = address(0x515993);
        address account = trader;
        address counterparty = address(0x515994);
        address counterpartyAccount = counterparty;
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, size, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        engine.reserveCloseOrderExecutionBounty(account, size / 2, 1e6);
    }

}
