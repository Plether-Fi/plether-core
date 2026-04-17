// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {AccountLensViewTypes} from "../../../src/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "../../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {ProtocolLensViewTypes} from "../../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpEconomicConservationInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderModelled.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.claimDeferredKeeperCredit.selector;
        selectors[7] = handler.createDeferredTraderCredit.selector;
        selectors[8] = handler.claimDeferredTraderCredit.selector;
        selectors[9] = handler.fundVault.selector;
        selectors[10] = handler.setRouterPayoutFailureMode.selector;
        selectors[11] = handler.setVaultAssets.selector;

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
        uint256 trackedBalances = clearinghouse.balanceUsdc(_accountId(address(handler)));
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
        uint256 expectedReserved = _maxLiability() + engine.accumulatedFeesUsdc()
            + engine.totalDeferredTraderCreditUsdc() + engine.totalDeferredKeeperCreditUsdc();

        expectedReserved += uint256(0);

        assertEq(
            _withdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, fees, and deferred obligations"
        );
    }

    function invariant_TrackedAccountBucketsReconcileSettlementBalances() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
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
            (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
            uint256 protectedMargin = size > 0 ? margin : 0;

            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(accountId);
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
                ledgerView.deferredTraderCreditUsdc,
                engine.deferredTraderCreditUsdc(accountId),
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
        uint256 totalSettlementUsdc =
            engineAccountLens.getAccountLedgerView(_accountId(address(handler))).settlementBalanceUsdc;
        uint256 totalExecutionEscrowUsdc;
        uint256 totalDeferredTraderCreditUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            AccountLensViewTypes.AccountLedgerView memory ledgerView =
                engineAccountLens.getAccountLedgerView(_accountId(handler.actorAt(i)));
            totalSettlementUsdc += ledgerView.settlementBalanceUsdc;
            totalExecutionEscrowUsdc += ledgerView.executionEscrowUsdc;
            totalDeferredTraderCreditUsdc += ledgerView.deferredTraderCreditUsdc;
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
            totalDeferredTraderCreditUsdc,
            engine.totalDeferredTraderCreditUsdc(),
            "Tracked deferred payout totals must match engine obligations"
        );
    }

    function invariant_BadDebtEventCannotLeaveLegacyDeferredTraderCreditOnSameAccount() public view {
        PerpAccountingHandler.BadDebtDeferredEvent memory eventSnapshot = handler.lastBadDebtDeferredEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            eventSnapshot.badDebtAfterUsdc,
            "Bad debt event snapshot should describe the current bad debt-producing step"
        );
        assertLe(
            engine.deferredTraderCreditUsdc(eventSnapshot.accountId),
            eventSnapshot.allowedDeferredAfterUsdc,
            "Bad debt-producing close/liquidation may only leave newly created deferred payout on the same account"
        );
    }

    function invariant_TerminalEventsMatchResidualAndBadDebtAccounting() public view {
        PerpAccountingHandler.TerminalResidualEvent memory eventSnapshot = handler.lastTerminalResidualEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        address trader = address(uint160(uint256(eventSnapshot.accountId)));
        uint256 actualFinalResidualUsdc = clearinghouse.balanceUsdc(eventSnapshot.accountId)
            + engine.deferredTraderCreditUsdc(eventSnapshot.accountId);
        if (eventSnapshot.walletPayoutExpected) {
            actualFinalResidualUsdc += usdc.balanceOf(trader) - eventSnapshot.traderWalletBeforeUsdc;
        }

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            eventSnapshot.badDebtBeforeUsdc + eventSnapshot.expectedBadDebtDeltaUsdc,
            "Terminal event bad debt delta should match previewed accounting"
        );
        assertEq(
            actualFinalResidualUsdc,
            eventSnapshot.expectedFinalResidualUsdc,
            "Terminal event residual should match retained settlement plus deferred and any immediate payout"
        );
    }

    function invariant_AccountLedgerSnapshotMatchesUnderlyingViews() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(accountId);
            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(accountId);
            CfdEngine.AccountCollateralView memory collateralView =
                engineAccountLens.getAccountCollateralView(accountId);
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView = snapshot;
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
                snapshot.deferredTraderCreditUsdc,
                ledgerView.deferredTraderCreditUsdc,
                "Account snapshot deferred payout mismatch"
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
            assertEq(snapshot.hasPosition, positionView.hasPosition, "Account snapshot position flag mismatch");
            assertEq(uint256(snapshot.side), uint256(positionView.side), "Account snapshot side mismatch");
            assertEq(snapshot.size, positionView.size, "Account snapshot size mismatch");
            assertEq(snapshot.margin, positionView.margin, "Account snapshot margin mismatch");
            assertEq(snapshot.entryPrice, positionView.entryPrice, "Account snapshot entry price mismatch");
            assertEq(
                snapshot.unrealizedPnlUsdc, positionView.unrealizedPnlUsdc, "Account snapshot unrealized pnl mismatch"
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
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(_accountId(handler.actorAt(i)));
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
            assertEq(snapshot.netEquityUsdc, 0, "Orphaned accounts must have zero net equity");
            assertFalse(snapshot.liquidatable, "Orphaned accounts must not be liquidatable");
        }
    }

    function invariant_AccountLedgerSnapshotFullySubsumesCompactAndLegacyViews() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(accountId);
            AccountLensViewTypes.AccountLedgerView memory compactView =
                engineAccountLens.getAccountLedgerView(accountId);
            CfdEngine.AccountCollateralView memory collateralView =
                engineAccountLens.getAccountCollateralView(accountId);
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView = snapshot;

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
                snapshot.deferredTraderCreditUsdc,
                compactView.deferredTraderCreditUsdc,
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
            assertEq(snapshot.hasPosition, positionView.hasPosition, "Snapshot must subsume position existence");
            assertEq(snapshot.size, positionView.size, "Snapshot must subsume position size");
            assertEq(snapshot.netEquityUsdc, positionView.netEquityUsdc, "Snapshot must subsume position net equity");
            assertEq(snapshot.liquidatable, positionView.liquidatable, "Snapshot must subsume liquidatable flag");
        }
    }

    function invariant_HousePoolInputSnapshotMatchesGlobalLedgerBuckets() public view {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(60 seconds);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
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
            _withdrawalReservedUsdc(),
            "Protocol snapshot withdrawal reserve mismatch"
        );
        assertEq(
            protocolSnapshot.freeUsdc,
            engineProtocolLens.getProtocolAccountingSnapshot().freeUsdc,
            "Protocol snapshot free USDC mismatch"
        );
        assertEq(snapshot.protocolFeesUsdc, feesUsdc, "House-pool snapshot fees must match engine fees");
        assertEq(
            snapshot.deferredTraderCreditUsdc,
            engine.totalDeferredTraderCreditUsdc(),
            "House-pool snapshot deferred trader credit mismatch"
        );
        assertEq(
            snapshot.deferredKeeperCreditUsdc,
            engine.totalDeferredKeeperCreditUsdc(),
            "House-pool snapshot deferred keeper credit mismatch"
        );
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability(), "House-pool snapshot max liability mismatch");
        assertEq(
            snapshot.supplementalReservedUsdc, uint256(0), "House-pool snapshot supplemental reserved amount mismatch"
        );
        assertEq(
            snapshot.physicalAssetsUsdc,
            vaultAssetsUsdc,
            "House-pool snapshot physical assets must match canonical vault assets"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            vaultAssetsUsdc > feesUsdc ? vaultAssetsUsdc - feesUsdc : 0,
            "House-pool snapshot net physical assets must match vault assets net of fees"
        );
        assertEq(
            snapshot.physicalAssetsUsdc, vaultAssetsUsdc, "House-pool snapshot physical asset decomposition mismatch"
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
            protocolSnapshot.totalDeferredTraderCreditUsdc,
            snapshot.deferredTraderCreditUsdc,
            "Protocol snapshot deferred trader credit mismatch"
        );
        assertEq(
            protocolSnapshot.totalDeferredKeeperCreditUsdc,
            snapshot.deferredKeeperCreditUsdc,
            "Protocol snapshot deferred keeper credit mismatch"
        );
    }

    function invariant_HousePoolStatusSnapshotMatchesEngineState() public view {
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot =
            engineProtocolLens.getHousePoolStatusSnapshot();

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
                engine.deferredTraderCreditUsdc(accountId),
                0,
                "Bad debt cannot coexist with deferred trader credit claims"
            );
        }
    }

    function invariant_GhostTrackedDeferredTraderCreditsMatchEngine() public view {
        uint256 ghostTotalDeferredTraderCredits;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostDeferredTraderCreditUsdc = handler.deferredTraderCreditSnapshot(accountId);
            uint256 liveDeferredTraderCreditUsdc = engine.deferredTraderCreditUsdc(accountId);

            assertEq(
                ghostDeferredTraderCreditUsdc,
                liveDeferredTraderCreditUsdc,
                "Ghost tracked deferred trader credit must match engine storage"
            );
            ghostTotalDeferredTraderCredits += ghostDeferredTraderCreditUsdc;
        }

        assertEq(
            handler.totalDeferredTraderCreditSnapshot(),
            ghostTotalDeferredTraderCredits,
            "Ghost deferred trader credit total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredTraderCreditUsdc(),
            ghostTotalDeferredTraderCredits,
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
