// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpEconomicConservationInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.executeNextOrderModelled.selector;
        selectors[4] = handler.liquidate.selector;
        selectors[5] = handler.claimDeferredClearerBounty.selector;
        selectors[6] = handler.createDeferredTraderPayout.selector;
        selectors[7] = handler.claimDeferredPayout.selector;
        selectors[8] = handler.fundVault.selector;
        selectors[9] = handler.setRouterPayoutFailureMode.selector;
        selectors[10] = handler.setVaultAssets.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_KnownActorAndProtocolBalancesConserveUsdcSupply() public view {
        assertEq(
            _knownBalancesSum(),
            usdc.totalSupply(),
            "Known actors and protocol contracts must conserve total USDC supply"
        );
    }

    function invariant_ClearinghouseCustodyMatchesTrackedAccountBalances() public view {
        uint256 trackedBalances;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            trackedBalances += clearinghouse.balanceUsdc(_accountId(handler.actorAt(i)));
        }

        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse custody must equal tracked account settlement balances"
        );
    }

    function invariant_WithdrawalReserveIncludesKnownDeferredLiabilities() public view {
        uint256 expectedReserved = engine.getMaxLiability() + engine.accumulatedFeesUsdc()
            + engine.totalDeferredPayoutUsdc() + engine.totalDeferredClearerBountyUsdc();

        expectedReserved += engine.getLiabilityOnlyFundingPnl();

        assertEq(
            engine.getWithdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, fees, and deferred obligations"
        );
    }

    function invariant_TrackedAccountBucketsReconcileSettlementBalances() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            uint256 protectedMargin = size > 0 ? margin : 0;

            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
            IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets =
                clearinghouse.getLockedMarginBuckets(accountId);

            assertEq(
                buckets.totalLockedMarginUsdc,
                buckets.activePositionMarginUsdc + buckets.otherLockedMarginUsdc,
                "Tracked account locked margin buckets must reconcile"
            );
            assertEq(
                buckets.activePositionMarginUsdc,
                lockedBuckets.positionMarginUsdc,
                "Tracked account active margin must equal typed position margin bucket"
            );
            assertEq(
                buckets.otherLockedMarginUsdc,
                lockedBuckets.committedOrderMarginUsdc + lockedBuckets.reservedSettlementUsdc,
                "Tracked account other locked margin must equal typed non-position buckets"
            );
            assertEq(
                buckets.totalLockedMarginUsdc,
                lockedBuckets.totalLockedMarginUsdc,
                "Tracked account total locked margin must equal typed bucket total"
            );
            assertEq(
                buckets.settlementBalanceUsdc,
                buckets.totalLockedMarginUsdc + buckets.freeSettlementUsdc,
                "Tracked account settlement balance must equal locked plus free buckets"
            );
            assertEq(
                buckets.settlementBalanceUsdc,
                clearinghouse.balanceUsdc(accountId),
                "Tracked account bucket settlement must equal clearinghouse balance"
            );
        }
    }

    function invariant_AccountLedgerViewMatchesUnderlyingBuckets() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            uint256 protectedMargin = size > 0 ? margin : 0;

            ICfdEngine.AccountLedgerView memory ledgerView = engine.getAccountLedgerView(accountId);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
            IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);

            assertEq(
                ledgerView.settlementBalanceUsdc, buckets.settlementBalanceUsdc, "Account ledger settlement mismatch"
            );
            assertEq(
                ledgerView.freeSettlementUsdc, buckets.freeSettlementUsdc, "Account ledger free settlement mismatch"
            );
            assertEq(
                ledgerView.activePositionMarginUsdc,
                buckets.activePositionMarginUsdc,
                "Account ledger active margin mismatch"
            );
            assertEq(
                ledgerView.otherLockedMarginUsdc,
                buckets.otherLockedMarginUsdc,
                "Account ledger other locked margin mismatch"
            );
            assertEq(
                ledgerView.executionEscrowUsdc, escrow.executionBountyUsdc, "Account ledger execution escrow mismatch"
            );
            assertEq(
                ledgerView.committedMarginUsdc, escrow.committedMarginUsdc, "Account ledger committed margin mismatch"
            );
            assertEq(
                ledgerView.deferredPayoutUsdc,
                engine.deferredPayoutUsdc(accountId),
                "Account ledger deferred payout mismatch"
            );
            assertEq(
                ledgerView.pendingOrderCount,
                router.pendingOrderCounts(accountId),
                "Account ledger pending order count mismatch"
            );
        }
    }

    function invariant_TrackedAccountLedgerTotalsMatchProtocolCustodyAndObligations() public view {
        uint256 totalSettlementUsdc;
        uint256 totalExecutionEscrowUsdc;
        uint256 totalDeferredPayoutUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            ICfdEngine.AccountLedgerView memory ledgerView = engine.getAccountLedgerView(_accountId(handler.actorAt(i)));
            totalSettlementUsdc += ledgerView.settlementBalanceUsdc;
            totalExecutionEscrowUsdc += ledgerView.executionEscrowUsdc;
            totalDeferredPayoutUsdc += ledgerView.deferredPayoutUsdc;
        }

        assertEq(
            totalSettlementUsdc,
            usdc.balanceOf(address(clearinghouse)),
            "Tracked settlement totals must match clearinghouse custody"
        );
        assertEq(
            totalExecutionEscrowUsdc,
            usdc.balanceOf(address(router)),
            "Tracked execution escrow totals must match router custody"
        );
        assertEq(
            totalDeferredPayoutUsdc,
            engine.totalDeferredPayoutUsdc(),
            "Tracked deferred payout totals must match engine obligations"
        );
    }

    function invariant_AccountLedgerSnapshotMatchesUnderlyingViews() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);
            ICfdEngine.AccountLedgerView memory ledgerView = engine.getAccountLedgerView(accountId);
            CfdEngine.AccountCollateralView memory collateralView = engine.getAccountCollateralView(accountId);
            CfdEngine.PositionView memory positionView = engine.getPositionView(accountId);
            IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets =
                clearinghouse.getLockedMarginBuckets(accountId);

            assertEq(
                snapshot.settlementBalanceUsdc, ledgerView.settlementBalanceUsdc, "Account snapshot settlement mismatch"
            );
            assertEq(
                snapshot.freeSettlementUsdc, ledgerView.freeSettlementUsdc, "Account snapshot free settlement mismatch"
            );
            assertEq(
                snapshot.activePositionMarginUsdc,
                ledgerView.activePositionMarginUsdc,
                "Account snapshot active margin mismatch"
            );
            assertEq(
                snapshot.otherLockedMarginUsdc,
                ledgerView.otherLockedMarginUsdc,
                "Account snapshot other locked margin mismatch"
            );
            assertEq(
                snapshot.positionMarginBucketUsdc,
                lockedBuckets.positionMarginUsdc,
                "Account snapshot position bucket mismatch"
            );
            assertEq(
                snapshot.committedOrderMarginBucketUsdc,
                lockedBuckets.committedOrderMarginUsdc,
                "Account snapshot committed-order bucket mismatch"
            );
            assertEq(
                snapshot.reservedSettlementBucketUsdc,
                lockedBuckets.reservedSettlementUsdc,
                "Account snapshot reserved-settlement bucket mismatch"
            );
            assertEq(
                snapshot.activePositionMarginUsdc,
                snapshot.positionMarginBucketUsdc,
                "Account snapshot active margin must equal typed position bucket"
            );
            assertEq(
                snapshot.otherLockedMarginUsdc,
                snapshot.committedOrderMarginBucketUsdc + snapshot.reservedSettlementBucketUsdc,
                "Account snapshot other locked margin must equal typed non-position buckets"
            );
            assertEq(
                snapshot.executionEscrowUsdc,
                ledgerView.executionEscrowUsdc,
                "Account snapshot execution escrow mismatch"
            );
            assertEq(
                snapshot.committedMarginUsdc,
                ledgerView.committedMarginUsdc,
                "Account snapshot committed margin mismatch"
            );
            assertEq(
                snapshot.deferredPayoutUsdc, ledgerView.deferredPayoutUsdc, "Account snapshot deferred payout mismatch"
            );
            assertEq(
                snapshot.pendingOrderCount,
                ledgerView.pendingOrderCount,
                "Account snapshot pending order count mismatch"
            );
            assertEq(
                snapshot.closeReachableUsdc,
                collateralView.closeReachableUsdc,
                "Account snapshot close reachable mismatch"
            );
            assertEq(
                snapshot.terminalReachableUsdc,
                collateralView.terminalReachableUsdc,
                "Account snapshot terminal reachable mismatch"
            );
            assertEq(snapshot.accountEquityUsdc, collateralView.accountEquityUsdc, "Account snapshot equity mismatch");
            assertEq(
                snapshot.freeBuyingPowerUsdc,
                collateralView.freeBuyingPowerUsdc,
                "Account snapshot buying power mismatch"
            );
            assertEq(snapshot.hasPosition, positionView.exists, "Account snapshot position flag mismatch");
            assertEq(uint256(snapshot.side), uint256(positionView.side), "Account snapshot side mismatch");
            assertEq(snapshot.size, positionView.size, "Account snapshot size mismatch");
            assertEq(snapshot.margin, positionView.margin, "Account snapshot margin mismatch");
            assertEq(snapshot.entryPrice, positionView.entryPrice, "Account snapshot entry price mismatch");
            assertEq(
                snapshot.unrealizedPnlUsdc, positionView.unrealizedPnlUsdc, "Account snapshot unrealized pnl mismatch"
            );
            assertEq(
                snapshot.pendingFundingUsdc,
                positionView.pendingFundingUsdc,
                "Account snapshot pending funding mismatch"
            );
            assertEq(snapshot.netEquityUsdc, positionView.netEquityUsdc, "Account snapshot net equity mismatch");
            assertEq(snapshot.liquidatable, positionView.liquidatable, "Account snapshot liquidatable mismatch");
        }
    }

    function invariant_ReachabilityMonotonicityHoldsForDepositsAndWithdrawals() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpAccountingHandler.ReachabilityTransition memory transition = handler.reachabilityTransition(accountId);

            if (transition.action == 1) {
                assertGe(
                    transition.afterCloseReachableUsdc,
                    transition.beforeCloseReachableUsdc,
                    "Deposits must not reduce close-reachable settlement"
                );
                assertGe(
                    transition.afterTerminalReachableUsdc,
                    transition.beforeTerminalReachableUsdc,
                    "Deposits must not reduce terminal-reachable settlement"
                );
            } else if (transition.action == 2) {
                assertLe(
                    transition.afterCloseReachableUsdc,
                    transition.beforeCloseReachableUsdc,
                    "Withdrawals must not increase close-reachable settlement"
                );
                assertLe(
                    transition.afterTerminalReachableUsdc,
                    transition.beforeTerminalReachableUsdc,
                    "Withdrawals must not increase terminal-reachable settlement"
                );
            }
        }
    }

    function invariant_NoOrphanedAccountStateWhenNoPositionAndNoPendingOrders() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            ICfdEngine.AccountLedgerSnapshot memory snapshot =
                engine.getAccountLedgerSnapshot(_accountId(handler.actorAt(i)));
            if (snapshot.hasPosition || snapshot.pendingOrderCount != 0) {
                continue;
            }

            assertEq(snapshot.activePositionMarginUsdc, 0, "Orphaned accounts must not keep active margin");
            assertEq(snapshot.otherLockedMarginUsdc, 0, "Orphaned accounts must not keep other locked margin");
            assertEq(snapshot.executionEscrowUsdc, 0, "Orphaned accounts must not keep execution escrow");
            assertEq(snapshot.committedMarginUsdc, 0, "Orphaned accounts must not keep committed margin");
            assertEq(
                snapshot.closeReachableUsdc,
                snapshot.freeSettlementUsdc,
                "Orphaned accounts close reachability must equal free settlement"
            );
            assertEq(
                snapshot.terminalReachableUsdc,
                snapshot.settlementBalanceUsdc,
                "Orphaned accounts liquidation reachability must equal settlement balance"
            );
            assertEq(snapshot.size, 0, "Orphaned accounts must have zero size");
            assertEq(snapshot.margin, 0, "Orphaned accounts must have zero margin");
            assertEq(snapshot.entryPrice, 0, "Orphaned accounts must have zero entry price");
            assertEq(snapshot.unrealizedPnlUsdc, 0, "Orphaned accounts must have zero unrealized pnl");
            assertEq(snapshot.pendingFundingUsdc, 0, "Orphaned accounts must have zero pending funding");
            assertEq(snapshot.netEquityUsdc, 0, "Orphaned accounts must have zero net equity");
            assertFalse(snapshot.liquidatable, "Orphaned accounts must not be liquidatable");
        }
    }

    function invariant_AccountLedgerSnapshotFullySubsumesCompactAndLegacyViews() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);
            ICfdEngine.AccountLedgerView memory compactView = engine.getAccountLedgerView(accountId);
            CfdEngine.AccountCollateralView memory collateralView = engine.getAccountCollateralView(accountId);
            CfdEngine.PositionView memory positionView = engine.getPositionView(accountId);

            assertEq(
                snapshot.settlementBalanceUsdc,
                compactView.settlementBalanceUsdc,
                "Snapshot must subsume compact settlement"
            );
            assertEq(
                snapshot.freeSettlementUsdc,
                compactView.freeSettlementUsdc,
                "Snapshot must subsume compact free settlement"
            );
            assertEq(
                snapshot.executionEscrowUsdc,
                compactView.executionEscrowUsdc,
                "Snapshot must subsume compact execution escrow"
            );
            assertEq(
                snapshot.deferredPayoutUsdc,
                compactView.deferredPayoutUsdc,
                "Snapshot must subsume compact deferred payout"
            );
            assertEq(
                snapshot.closeReachableUsdc,
                collateralView.closeReachableUsdc,
                "Snapshot must subsume collateral close reachability"
            );
            assertEq(
                snapshot.accountEquityUsdc, collateralView.accountEquityUsdc, "Snapshot must subsume collateral equity"
            );
            assertEq(snapshot.hasPosition, positionView.exists, "Snapshot must subsume position existence");
            assertEq(snapshot.size, positionView.size, "Snapshot must subsume position size");
            assertEq(snapshot.netEquityUsdc, positionView.netEquityUsdc, "Snapshot must subsume position net equity");
            assertEq(snapshot.liquidatable, positionView.liquidatable, "Snapshot must subsume liquidatable flag");
        }
    }

    function invariant_HousePoolInputSnapshotMatchesGlobalLedgerBuckets() public view {
        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(60 seconds);
        ICfdEngine.ProtocolAccountingSnapshot memory protocolSnapshot = engine.getProtocolAccountingSnapshot();
        uint256 vaultAssetsUsdc = vault.totalAssets();
        uint256 feesUsdc = engine.accumulatedFeesUsdc();

        assertEq(protocolSnapshot.vaultAssetsUsdc, vaultAssetsUsdc, "Protocol snapshot vault assets mismatch");
        assertEq(protocolSnapshot.accumulatedFeesUsdc, feesUsdc, "Protocol snapshot fees mismatch");
        assertEq(
            protocolSnapshot.accumulatedBadDebtUsdc,
            engine.accumulatedBadDebtUsdc(),
            "Protocol snapshot bad debt mismatch"
        );
        assertEq(
            protocolSnapshot.withdrawalReservedUsdc,
            engine.getWithdrawalReservedUsdc(),
            "Protocol snapshot withdrawal reserve mismatch"
        );
        assertEq(
            protocolSnapshot.freeUsdc,
            engine.getProtocolAccountingView().freeUsdc,
            "Protocol snapshot free USDC mismatch"
        );
        assertEq(snapshot.protocolFeesUsdc, feesUsdc, "House-pool snapshot fees must match engine fees");
        assertEq(
            snapshot.deferredTraderPayoutUsdc,
            engine.totalDeferredPayoutUsdc(),
            "House-pool snapshot deferred trader payout mismatch"
        );
        assertEq(
            snapshot.deferredClearerBountyUsdc,
            engine.totalDeferredClearerBountyUsdc(),
            "House-pool snapshot deferred clearer bounty mismatch"
        );
        assertEq(snapshot.maxLiabilityUsdc, engine.getMaxLiability(), "House-pool snapshot max liability mismatch");
        assertEq(
            snapshot.withdrawalFundingLiabilityUsdc,
            engine.getLiabilityOnlyFundingPnl(),
            "House-pool snapshot withdrawal funding liability mismatch"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            vaultAssetsUsdc > feesUsdc ? vaultAssetsUsdc - feesUsdc : 0,
            "House-pool snapshot net physical assets must match vault assets net of fees"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc + snapshot.protocolFeesUsdc,
            vaultAssetsUsdc > feesUsdc ? vaultAssetsUsdc : feesUsdc,
            "House-pool snapshot physical asset decomposition mismatch"
        );
        assertEq(
            protocolSnapshot.netPhysicalAssetsUsdc,
            snapshot.netPhysicalAssetsUsdc,
            "Protocol snapshot net assets mismatch"
        );
        assertEq(
            protocolSnapshot.maxLiabilityUsdc, snapshot.maxLiabilityUsdc, "Protocol snapshot max liability mismatch"
        );
        assertEq(
            protocolSnapshot.totalDeferredPayoutUsdc,
            snapshot.deferredTraderPayoutUsdc,
            "Protocol snapshot deferred trader payout mismatch"
        );
        assertEq(
            protocolSnapshot.totalDeferredClearerBountyUsdc,
            snapshot.deferredClearerBountyUsdc,
            "Protocol snapshot deferred clearer bounty mismatch"
        );
    }

    function invariant_HousePoolStatusSnapshotMatchesEngineState() public view {
        ICfdEngine.HousePoolStatusSnapshot memory snapshot = engine.getHousePoolStatusSnapshot();

        assertEq(snapshot.lastMarkTime, engine.lastMarkTime(), "House-pool status last mark time mismatch");
        assertEq(snapshot.oracleFrozen, engine.isOracleFrozen(), "House-pool status oracle frozen mismatch");
        assertEq(snapshot.degradedMode, engine.degradedMode(), "House-pool status degraded mode mismatch");
    }

    function invariant_BadDebtOnlyRemainsAfterTrackedAccountsExhaustReachableValue() public view {
        uint256 badDebtUsdc = engine.accumulatedBadDebtUsdc();
        if (badDebtUsdc == 0) {
            return;
        }

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated || badDebtUsdc <= snapshot.badDebtUsdc) {
                continue;
            }

            assertEq(handler.accountRouterEscrow(accountId), 0, "Bad debt cannot coexist with tracked router escrow");
            assertEq(
                clearinghouse.balanceUsdc(accountId), 0, "Bad debt cannot coexist with tracked clearinghouse balance"
            );
            assertEq(
                engine.deferredPayoutUsdc(accountId), 0, "Bad debt cannot coexist with deferred trader payout claims"
            );
        }
    }

    function invariant_GhostTrackedDeferredTraderPayoutsMatchEngine() public view {
        uint256 ghostTotalDeferredTraderPayouts;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostDeferredPayoutUsdc = handler.deferredTraderPayoutSnapshot(accountId);
            uint256 liveDeferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            assertEq(
                ghostDeferredPayoutUsdc,
                liveDeferredPayoutUsdc,
                "Ghost tracked deferred trader payout must match engine storage"
            );
            ghostTotalDeferredTraderPayouts += ghostDeferredPayoutUsdc;
        }

        assertEq(
            handler.totalDeferredTraderPayoutSnapshot(),
            ghostTotalDeferredTraderPayouts,
            "Ghost deferred trader payout total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredPayoutUsdc(),
            ghostTotalDeferredTraderPayouts,
            "Engine deferred payout total must match tracked ghost sum"
        );
    }

    function _knownBalancesSum() internal view returns (uint256 totalBalances) {
        totalBalances += usdc.balanceOf(address(this));
        totalBalances += usdc.balanceOf(address(handler));
        totalBalances += usdc.balanceOf(address(engine));
        totalBalances += usdc.balanceOf(address(clearinghouse));
        totalBalances += usdc.balanceOf(address(router));
        totalBalances += usdc.balanceOf(address(vault));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            totalBalances += usdc.balanceOf(handler.actorAt(i));
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

}
