// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

contract PerpEconomicConservationInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderModelled.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.createTraderClaim.selector;
        selectors[7] = handler.settleTraderClaim.selector;
        selectors[8] = handler.fundHousePool.selector;
        selectors[9] = handler.setPoolAssets.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_BatchSynchronizesClaimsForEveryProcessedOrderOwner() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.BULL), 20, 1000e6, 1e8);
        handler.commitOpenOrder(1, uint8(CfdTypes.Side.BULL), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();
        handler.executeNextOrderModelled();

        address firstAccount = _account(handler.actorAt(0));
        address secondAccount = _account(handler.actorAt(1));
        assertGt(_positionSize(firstAccount), 0, "First position must be live");
        assertGt(_positionSize(secondAccount), 0, "Second position must be live");

        handler.commitCloseOrder(0, 0.5e8);
        handler.createTraderClaim(1);

        uint256 firstClaimUsdc = engine.traderClaimBalanceUsdc(firstAccount);
        uint256 secondClaimUsdc = engine.traderClaimBalanceUsdc(secondAccount);
        assertGt(firstClaimUsdc, 0, "Earlier batched close must create a claim");
        assertGt(secondClaimUsdc, 0, "Requested batched close must create a claim");
        assertEq(handler.traderClaimSnapshot(firstAccount), firstClaimUsdc, "First owner claim cache mismatch");
        assertEq(handler.traderClaimSnapshot(secondAccount), secondClaimUsdc, "Second owner claim cache mismatch");
        assertEq(
            handler.totalTraderClaimSnapshot(),
            engine.totalTraderClaimBalanceUsdc(),
            "Aggregate claim cache must include every processed owner"
        );
    }

    function test_ExpiredModelledTerminalCloseDoesNotCreateExecutionGhosts() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.BULL), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();

        address account = _account(handler.actorAt(0));
        uint256 sizeBefore = _positionSize(account);
        assertGt(sizeBefore, 0, "Position must be live");

        handler.setPoolAssets(0);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, sizeBefore, 0.5e8);
        assertTrue(preview.valid, "Profitable terminal close preview must be valid");
        assertEq(preview.remainingSize, 0, "Close preview must be terminal");
        assertGt(preview.traderClaimBalanceUsdc, 0, "Close preview must project a deferred claim");

        uint64 closeOrderId = router.nextCommitId();
        handler.commitCloseOrder(0, 0.5e8);
        uint256 executedBefore = handler.ghostExecutedOrderCount();
        uint256 liveClaimBefore = engine.traderClaimBalanceUsdc(account);
        uint256 ghostClaimBefore = handler.traderClaimSnapshot(account);
        assertGt(handler.accountExecutionBountyReserve(account), 0, "Close bounty must be reserved");

        handler.warpForward(router.maxOrderAge() + 1);
        handler.executeNextOrderModelled();

        assertEq(handler.ghostOrderLifecycleState(closeOrderId), 3, "Expired close must be tracked as failed");
        assertEq(_positionSize(account), sizeBefore, "Expired close must not mutate the position");
        assertEq(handler.ghostExecutedOrderCount(), executedBefore, "Expired close must not count as executed");
        assertEq(engine.traderClaimBalanceUsdc(account), liveClaimBefore, "Expired close must not create a claim");
        assertEq(handler.traderClaimSnapshot(account), ghostClaimBefore, "Expired close must not mutate claim ghost");
        assertEq(router.pendingOrderCounts(account), 0, "Expired close must leave the pending queue");
        assertEq(handler.accountExecutionBountyReserve(account), 0, "Expired close bounty must be cleared");
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            0,
            "Expired close reserved settlement must be cleared"
        );
        assertFalse(
            handler.lastTerminalResidualEventSnapshot().active,
            "Expired close must not fabricate a terminal residual event"
        );
        assertFalse(
            handler.lastPriceLossTraderClaimEventSnapshot().active,
            "Expired close must not fabricate a price-loss event"
        );
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

    function invariant_KnownActorAndProtocolBalancesConserveUsdcSupply() public view {
        assertEq(
            _knownBalancesSum(),
            usdc.totalSupply(),
            "Known actors and protocol contracts must conserve total USDC supply"
        );
    }

    function invariant_ClearinghouseCustodyMatchesTrackedAccountBalances() public view {
        uint256 trackedBalances = clearinghouse.balanceUsdc(_account(address(handler)))
            + clearinghouse.balanceUsdc(engine.protocolTreasury());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            trackedBalances += clearinghouse.balanceUsdc(_account(handler.actorAt(i)));
        }

        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse custody must equal tracked account settlement balances"
        );
    }

    function invariant_WithdrawalReserveIncludesKnownTraderClaimLiabilities() public view {
        uint256 maxLiability = _maxLiability();
        uint256 expectedReserved = maxLiability + engine.totalTraderClaimBalanceUsdc()
            + SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps());

        assertEq(
            _withdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, trader claims, and settlement headroom"
        );
    }

    function invariant_TrackedAccountBucketsReconcileSettlementBalances() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            uint256 protectedMargin = size > 0 ? margin : 0;

            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
            IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets =
                clearinghouse.getLockedMarginBuckets(account);
            IMarginClearinghouse.PnlIsolationBuckets memory isolationBuckets =
                clearinghouse.getPnlIsolationBuckets(account);

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
                isolationBuckets.liquidationReserveUsdc + isolationBuckets.orderMarginUsdc
                    + isolationBuckets.actionReserveUsdc,
                "Tracked account other locked margin must equal canonical non-position buckets"
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
                clearinghouse.balanceUsdc(account),
                "Tracked account bucket settlement must equal clearinghouse balance"
            );
        }
    }

    function invariant_AccountLedgerViewMatchesUnderlyingBuckets() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            uint256 protectedMargin = size > 0 ? margin : 0;

            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

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
                ledgerView.executionBountyReserveUsdc,
                reservation.executionBountyUsdc,
                "Account ledger execution reservation mismatch"
            );
            assertEq(
                ledgerView.committedMarginUsdc,
                reservation.committedMarginUsdc,
                "Account ledger committed margin mismatch"
            );
            assertEq(
                ledgerView.traderClaimBalanceUsdc,
                engine.traderClaimBalanceUsdc(account),
                "Account ledger trader claim mismatch"
            );
            assertEq(
                ledgerView.pendingOrderCount,
                router.pendingOrderCounts(account),
                "Account ledger pending order count mismatch"
            );
        }
    }

    function invariant_TrackedAccountLedgerTotalsMatchProtocolCustodyAndObligations() public view {
        uint256 totalSettlementUsdc = engineAccountLens.getAccountLedgerView(_account(address(handler)))
            .settlementBalanceUsdc + clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 totalReservedSettlementUsdc =
            clearinghouse.getLockedMarginBuckets(_account(address(handler))).reservedSettlementUsdc;
        uint256 totalExecutionReservationUsdc;
        uint256 totalTraderClaimBalanceUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
            totalSettlementUsdc += ledgerView.settlementBalanceUsdc;
            totalExecutionReservationUsdc += ledgerView.executionBountyReserveUsdc;
            totalTraderClaimBalanceUsdc += ledgerView.traderClaimBalanceUsdc;
            totalReservedSettlementUsdc += clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc;
        }

        assertEq(
            totalSettlementUsdc,
            usdc.balanceOf(address(clearinghouse)),
            "Tracked settlement totals must match clearinghouse custody"
        );
        assertEq(
            totalExecutionReservationUsdc,
            totalReservedSettlementUsdc,
            "Tracked execution reservation totals must match clearinghouse reserved settlement"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "Router must not custody execution bounty reservation");
        assertEq(
            totalTraderClaimBalanceUsdc,
            engine.totalTraderClaimBalanceUsdc(),
            "Tracked trader claim totals must match engine obligations"
        );
    }

    function invariant_PriceLossEventLeavesExactlyThePreviewedTraderClaim() public view {
        PerpAccountingHandler.PriceLossTraderClaimEvent memory eventSnapshot =
            handler.lastPriceLossTraderClaimEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        assertEq(
            eventSnapshot.legacyDebtDiagnosticUsdc,
            0,
            "Terminal price tails must be diagnostic writeoffs rather than protocol debt"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(eventSnapshot.account),
            eventSnapshot.expectedTraderClaimAfterUsdc,
            "Terminal price-loss settlement must leave exactly the claim projected by the planner"
        );
    }

    function invariant_TerminalEventsMatchResidualAndPriceWriteoffAccounting() public view {
        PerpAccountingHandler.TerminalResidualEvent memory eventSnapshot = handler.lastTerminalResidualEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        address trader = eventSnapshot.account;
        uint256 actualFinalResidualUsdc =
            clearinghouse.balanceUsdc(eventSnapshot.account) + engine.traderClaimBalanceUsdc(eventSnapshot.account);
        if (eventSnapshot.walletPayoutExpected) {
            actualFinalResidualUsdc += usdc.balanceOf(trader) - eventSnapshot.traderWalletBeforeUsdc;
        }

        assertEq(
            eventSnapshot.legacyDebtDiagnosticUsdc,
            0,
            "Terminal settlement must not externalize uncollectible price tails as mutable debt"
        );
        assertEq(
            actualFinalResidualUsdc,
            eventSnapshot.expectedFinalResidualUsdc,
            "Terminal event residual should match retained settlement plus trader claim and any immediate payout"
        );
    }

    function invariant_AccountLedgerSnapshotMatchesUnderlyingViews() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
            ICfdEngineTypes.AccountCollateralView memory collateralView =
                engineAccountLens.getAccountCollateralView(account);
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView = snapshot;
            IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets =
                clearinghouse.getLockedMarginBuckets(account);
            IMarginClearinghouse.PnlIsolationBuckets memory isolationBuckets =
                clearinghouse.getPnlIsolationBuckets(account);

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
                isolationBuckets.liquidationReserveUsdc + isolationBuckets.orderMarginUsdc
                    + isolationBuckets.actionReserveUsdc,
                "Account snapshot other locked margin must equal canonical non-position buckets"
            );
            assertEq(
                snapshot.executionBountyReserveUsdc,
                ledgerView.executionBountyReserveUsdc,
                "Account snapshot execution reservation mismatch"
            );
            assertEq(
                snapshot.committedMarginUsdc,
                ledgerView.committedMarginUsdc,
                "Account snapshot committed margin mismatch"
            );
            assertEq(
                snapshot.traderClaimBalanceUsdc,
                ledgerView.traderClaimBalanceUsdc,
                "Account snapshot trader claim mismatch"
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
                snapshot.liquidationReachableSettlementUsdc,
                collateralView.liquidationReachableSettlementUsdc,
                "Account snapshot liquidation reachability mismatch"
            );
            assertEq(
                snapshot.terminalPriceCollectibleCapUsdc,
                collateralView.terminalPriceCollectibleCapUsdc,
                "Account snapshot terminal price cap mismatch"
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
            address account = _account(handler.actorAt(i));
            PerpAccountingHandler.ReachabilityTransition memory transition = handler.reachabilityTransition(account);

            if (transition.action == 1) {
                assertGe(
                    transition.afterCloseReachableUsdc,
                    transition.beforeCloseReachableUsdc,
                    "Deposits must not reduce close-reachable settlement"
                );
                assertGe(
                    transition.afterTerminalReachableUsdc,
                    transition.beforeTerminalReachableUsdc,
                    "Deposits must not reduce liquidation-reachable settlement"
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
                    "Withdrawals must not increase liquidation-reachable settlement"
                );
            }
        }
    }

    function invariant_NoOrphanedAccountStateWhenNoPositionAndNoPendingOrders() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(_account(handler.actorAt(i)));
            if (snapshot.hasPosition || snapshot.pendingOrderCount != 0) {
                continue;
            }

            assertEq(snapshot.activePositionMarginUsdc, 0, "Orphaned accounts must not keep active margin");
            assertEq(snapshot.otherLockedMarginUsdc, 0, "Orphaned accounts must not keep other locked margin");
            assertEq(snapshot.executionBountyReserveUsdc, 0, "Orphaned accounts must not keep execution reservation");
            assertEq(snapshot.committedMarginUsdc, 0, "Orphaned accounts must not keep committed margin");
            assertEq(
                snapshot.closeReachableUsdc,
                snapshot.freeSettlementUsdc,
                "Orphaned accounts close reachability must equal free settlement"
            );
            assertEq(
                snapshot.liquidationReachableSettlementUsdc,
                snapshot.settlementBalanceUsdc,
                "Orphaned accounts liquidation reachability must equal settlement balance"
            );
            assertEq(snapshot.terminalPriceCollectibleCapUsdc, 0, "Orphaned accounts must have zero terminal price cap");
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
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            AccountLensViewTypes.AccountLedgerView memory compactView = engineAccountLens.getAccountLedgerView(account);
            ICfdEngineTypes.AccountCollateralView memory collateralView =
                engineAccountLens.getAccountCollateralView(account);
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
                snapshot.executionBountyReserveUsdc,
                compactView.executionBountyReserveUsdc,
                "Snapshot must subsume compact execution reservation"
            );
            assertEq(
                snapshot.traderClaimBalanceUsdc,
                compactView.traderClaimBalanceUsdc,
                "Snapshot must subsume compact trader claim"
            );
            assertEq(
                snapshot.closeReachableUsdc,
                collateralView.closeReachableUsdc,
                "Snapshot must subsume collateral close reachability"
            );
            assertEq(
                snapshot.liquidationReachableSettlementUsdc,
                collateralView.liquidationReachableSettlementUsdc,
                "Snapshot must subsume collateral liquidation reachability"
            );
            assertEq(
                snapshot.terminalPriceCollectibleCapUsdc,
                collateralView.terminalPriceCollectibleCapUsdc,
                "Snapshot must subsume collateral terminal price cap"
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
        uint256 poolAssetsUsdc = housePool.totalAssets();
        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 settlementBufferUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engine.settlementBufferBps());
        uint256 expectedWithdrawalReservedUsdc =
            maxLiabilityUsdc + engine.totalTraderClaimBalanceUsdc() + settlementBufferUsdc;
        uint256 expectedFreeUsdc =
            poolAssetsUsdc > expectedWithdrawalReservedUsdc ? poolAssetsUsdc - expectedWithdrawalReservedUsdc : 0;

        assertEq(protocolSnapshot.poolAssetsUsdc, poolAssetsUsdc, "Protocol snapshot HousePool assets mismatch");
        assertEq(
            protocolSnapshot.protocolTreasuryBalanceUsdc,
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Protocol snapshot fees mismatch"
        );
        uint256 expectedEffectiveSolvencyAssetsUsdc = poolAssetsUsdc > engine.totalTraderClaimBalanceUsdc()
            ? poolAssetsUsdc - engine.totalTraderClaimBalanceUsdc()
            : 0;
        assertEq(
            protocolSnapshot.effectiveSolvencyAssetsUsdc,
            expectedEffectiveSolvencyAssetsUsdc,
            "Price writeoffs must not create a second subtraction from physical solvency assets"
        );
        assertEq(
            protocolSnapshot.withdrawalReservedUsdc,
            expectedWithdrawalReservedUsdc,
            "Protocol snapshot withdrawal reserve mismatch"
        );
        assertEq(protocolSnapshot.freeUsdc, expectedFreeUsdc, "Protocol snapshot free USDC mismatch");
        assertEq(
            snapshot.traderClaimBalanceUsdc,
            engine.totalTraderClaimBalanceUsdc(),
            "House-pool snapshot trader claim balance mismatch"
        );
        assertEq(snapshot.maxLiabilityUsdc, maxLiabilityUsdc, "House-pool snapshot max liability mismatch");
        assertEq(
            snapshot.supplementalReservedUsdc,
            settlementBufferUsdc,
            "House-pool snapshot supplemental reserved amount mismatch"
        );
        assertEq(
            snapshot.physicalAssetsUsdc,
            poolAssetsUsdc,
            "House-pool snapshot physical assets must match canonical HousePool assets"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            poolAssetsUsdc > protocolSnapshot.protocolTreasuryBalanceUsdc
                ? poolAssetsUsdc - protocolSnapshot.protocolTreasuryBalanceUsdc
                : 0,
            "House-pool snapshot net physical assets must exclude treasury clearinghouse fees"
        );
        assertEq(
            snapshot.physicalAssetsUsdc, poolAssetsUsdc, "House-pool snapshot physical asset decomposition mismatch"
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
            protocolSnapshot.totalTraderClaimBalanceUsdc,
            snapshot.traderClaimBalanceUsdc,
            "Protocol snapshot trader claim balance mismatch"
        );
    }

    function invariant_HousePoolStatusSnapshotMatchesEngineState() public view {
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot =
            engineProtocolLens.getHousePoolStatusSnapshot();

        assertEq(snapshot.lastMarkTime, engine.lastMarkTime(), "House-pool status last mark time mismatch");
        assertEq(snapshot.oracleFrozen, engine.isOracleFrozen(), "House-pool status oracle frozen mismatch");
        assertEq(snapshot.degradedMode, engine.degradedMode(), "House-pool status degraded mode mismatch");
    }

    function invariant_LiquidationWriteoffsNeverBecomeDebtOrPreserveExecutionBounties() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(account);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(
                snapshot.legacyDebtDiagnosticUsdc,
                0,
                "Liquidation price-loss shortfall must remain a diagnostic writeoff"
            );
            assertEq(
                handler.accountExecutionBountyReserve(account),
                0,
                "Liquidation must forfeit tracked execution bounty reserves"
            );
        }
    }

    function invariant_GhostTrackedTraderClaimsMatchEngine() public view {
        uint256 ghostTotalTraderClaims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 ghostTraderClaimUsdc = handler.traderClaimSnapshot(account);
            uint256 liveTraderClaimUsdc = engine.traderClaimBalanceUsdc(account);

            assertEq(
                ghostTraderClaimUsdc,
                liveTraderClaimUsdc,
                "Ghost tracked trader claim balance must match engine storage"
            );
            ghostTotalTraderClaims += ghostTraderClaimUsdc;
        }

        assertEq(
            handler.totalTraderClaimSnapshot(),
            ghostTotalTraderClaims,
            "Ghost trader claim balance total must match tracked account sum"
        );
        assertEq(
            engine.totalTraderClaimBalanceUsdc(),
            ghostTotalTraderClaims,
            "Engine trader claim total must match tracked ghost sum"
        );
    }

    function _knownBalancesSum() internal view returns (uint256 totalBalances) {
        totalBalances += usdc.balanceOf(address(this));
        totalBalances += usdc.balanceOf(address(handler));
        totalBalances += usdc.balanceOf(address(engine));
        totalBalances += usdc.balanceOf(address(clearinghouse));
        totalBalances += usdc.balanceOf(address(router));
        totalBalances += usdc.balanceOf(address(housePool));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            totalBalances += usdc.balanceOf(handler.actorAt(i));
        }
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

}
