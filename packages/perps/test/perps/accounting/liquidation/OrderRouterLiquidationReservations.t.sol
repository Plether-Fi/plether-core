// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract OrderRouterLiquidationReservationTest is BasePerpTest {

    address trader = address(0xC10A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 9,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        uint256 keeperSettlementBefore = clearinghouse.balanceAssets(address(this));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, address(this));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            clearinghouse.balanceAssets(address(this)) - keeperSettlementBefore,
            preview.keeperBountyAssets,
            "Immediate liquidation bounty should credit the keeper clearinghouse balance"
        );
    }

    function test_ExecuteLiquidation_CreditsKeeperBountyEvenWhenPoolPayoutFails() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, address(this));

        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(pool.payOut.selector, address(clearinghouse), preview.keeperBountyAssets),
            abi.encodeWithSignature("Error(string)", "pool illiquid")
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            observed.keeperSettlementAssets,
            preview.keeperBountyAssets,
            "Keeper bounty should settle directly inside the clearinghouse"
        );
    }

    function test_ExecuteLiquidation_ForfeitsReservedOpenBountiesWithoutCreditingTraderSettlement() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        assertEq(
            settlementToken.balanceOf(address(router)), 0, "Router should not custody open-order bounty reservation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets,
            _executionBountyReserve(1) * queuedOrderCount,
            "Clearinghouse should reserve the shielded open-order bounty reservation"
        );
        assertEq(
            router.pendingOrderCounts(account),
            queuedOrderCount,
            "Queued open orders should remain pending before liquidation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still clear the underwater position");
        assertEq(router.getAccountReservations(account).executionBountyAssets, 0);
        assertEq(
            preview.reachableCollateralAssets,
            snapshotBefore.activePositionMarginAssets + snapshotBefore.traderClaimBalanceAssets,
            "Price-loss reachability should include only PnL pledge and same-account claims"
        );
        assertGt(
            snapshotBefore.liquidationReachableSettlementAssets,
            preview.reachableCollateralAssets,
            "Setup should retain non-price-risk settlement outside liquidation reachability"
        );
        assertEq(
            router.nextExecuteId(),
            0,
            "Liquidation should clear the global queue head when only liquidated-account orders remain"
        );
        assertEq(
            clearinghouse.balanceAssets(account),
            snapshotBefore.settlementBalanceAssets - snapshotBefore.executionBountyReserveAssets
                - preview.seizedCollateralAssets - preview.keeperBountyAssets - preview.protocolLiquidationFeeAssets,
            "Trader settlement should retain isolated value without recovering forfeited execution bounties"
        );
    }

    function test_ExecuteLiquidation_ForfeitedReservationFeedsTreasuryMarginWithoutChangingPoolDepth() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        ICfdEngineAdminHost.EngineFreshnessConfig memory freshnessConfig = _engineFreshnessConfig();
        freshnessConfig.engineMarkStalenessLimit = 90 days;
        engineAdmin.proposeFreshnessConfig(freshnessConfig);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 25e6);

        vm.warp(block.timestamp + 60 days);
        while (engine.isOracleFrozen()) {
            vm.warp(block.timestamp + 1 days);
        }
        uint256 canonicalDepthBefore = pool.totalAssets();

        ICfdEngineTypes.LiquidationPreview memory expectedPreview =
            engineLens.simulateLiquidation(account, 195_000_000, canonicalDepthBefore);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));

        uint256 keeperBefore = clearinghouse.balanceAssets(address(this));
        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(
            clearinghouse.balanceAssets(address(this)) - keeperBefore,
            expectedPreview.keeperBountyAssets,
            "Liquidation bounty should use post-forfeiture clearinghouse reachability"
        );
    }

    function test_ExecuteLiquidation_ForfeitsReservedCloseBountiesBeforeClearingOrders() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 350e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, 0, true);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, 0, true);
        clearinghouse.withdraw(account, 68e6);
        vm.stopPrank();

        assertEq(
            settlementToken.balanceOf(address(router)),
            0,
            "Router should not custody prefunded close-order bounty reservation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets,
            0,
            "Clearinghouse should reserve prefunded close-order bounty reservation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 poolAssetsBefore = pool.totalAssets();
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(102_500_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(snapshotBefore.executionBountyReserveAssets, 0, "Unpaid close orders do not reserve settlement");
        assertEq(router.pendingOrderCounts(account), 0, "Liquidation should clear queued close orders");
        assertEq(_executionBountyReserve(1), 0, "Liquidation should forfeit the first close-order bounty reservation");
        assertEq(_executionBountyReserve(2), 0, "Liquidation should forfeit the second close-order bounty reservation");
        assertEq(
            settlementToken.balanceOf(address(router)),
            0,
            "Router should not retain close-order bounty reservation after liquidation"
        );
        assertEq(
            pool.excessAssets(), 0, "Forfeited close-order bounty reservation should not remain quarantined as excess"
        );
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            0,
            "Forfeited close-order bounty reservation should transfer into treasury margin"
        );
        assertGe(
            pool.totalAssets(),
            poolAssetsBefore,
            "Liquidation settlement should not quarantine forfeited bounty as pool excess"
        );
    }

    function test_ExecuteLiquidation_PreventsPostLiquidationReservationRecovery() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        uint256 traderAssetsBefore = settlementToken.balanceOf(trader);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(
            router.nextExecuteId(),
            0,
            "Liquidation should consume the liquidated account's queued orders and clear the queue to the zero sentinel"
        );

        vm.prank(trader);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrderBatch(uint64(queuedOrderCount), priceData);

        assertEq(
            settlementToken.balanceOf(trader),
            traderAssetsBefore,
            "Liquidated trader should not recover reservation after liquidation"
        );
        assertEq(
            settlementToken.balanceOf(address(router)),
            0,
            "Router should hold no reservation for post-liquidation recovery"
        );
    }

    function test_ExecuteLiquidation_ClearsOnlyLiquidatedAccountsPendingOrders() public {
        _startRecordingLogs();
        address traderAccount = trader;
        address otherTrader = address(0xC10B);
        address otherAccount = otherTrader;

        _fundTrader(trader, 900e6);
        _fundTrader(otherTrader, 2000e6);

        _open(traderAccount, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        clearinghouse.withdraw(traderAccount, 70e6);
        vm.stopPrank();

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, type(uint256).max, false);
        vm.stopPrank();

        assertEq(router.pendingOrderCounts(traderAccount), 2, "Liquidated account should start with two queued orders");
        assertEq(
            router.pendingOrderCounts(otherAccount), 2, "Unrelated account should start with its own queued orders"
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(traderAccount, priceData);

        assertEq(
            router.pendingOrderCounts(traderAccount), 0, "Liquidation should clear only the liquidated account queue"
        );
        assertEq(router.pendingOrderCounts(otherAccount), 2, "Unrelated account queue should remain intact");

        IOrderRouterAccounting.PendingOrderView[] memory otherPending = _pendingOrders(otherAccount);
        assertEq(otherPending.length, 2, "Per-account traversal should still expose unrelated pending orders");
        assertEq(otherPending[0].orderId, 3, "Unrelated account should retain FIFO order ids after cleanup");
        assertEq(otherPending[1].orderId, 4, "Unrelated account queue should preserve its tail order");
    }

    function test_CommitClose_UsesOnlyAccountLocalQueuedPositionProjection() public {
        _startRecordingLogs();
        address traderAccount = trader;
        address otherTrader = address(0xC10C);

        _fundTrader(trader, 2000e6);
        _fundTrader(otherTrader, 2000e6);
        _open(traderAccount, CfdTypes.Side.LONG, 20_000e18, 500e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, type(uint256).max, true);

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, type(uint256).max, false);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 15_000e18, 0, type(uint256).max, true);

        IOrderRouterAccounting.PendingOrderView[] memory traderPending = _pendingOrders(traderAccount);
        assertEq(traderPending.length, 2, "Trader should be able to queue closes using only its own pending orders");
        assertEq(traderPending[0].sizeDelta, 5000e18, "First close should remain queued");
        assertEq(traderPending[1].sizeDelta, 15_000e18, "Second close should consume only the trader's residual size");
    }

}
