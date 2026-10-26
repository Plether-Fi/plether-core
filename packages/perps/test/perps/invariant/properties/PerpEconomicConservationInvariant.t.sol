// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "../handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

contract PerpEconomicConservationInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(settlementToken, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](11);
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
        selectors[10] = handler.depositCollateralFor.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_RepeatedThirdPartyFundingDefersCarryUntilWithdrawalAndConservesAssets() public {
        handler.setPoolAssets(100_000e6);
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();

        address account = handler.actorAt(0);
        assertGt(_positionSize(account), 0, "Position must be live before funding");
        (uint256 borrowBaseBefore, uint256 indexBefore, uint64 timestampBefore) = engine.positionCarryState(account);
        uint256 marginBefore = clearinghouse.pnlPledgeAssets(account);
        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        uint256 poolBefore = housePool.totalAssets();
        uint256 mintedBefore = handler.ghostTotalTraderMinted();

        for (uint256 i; i < 3; ++i) {
            handler.warpForward(1 hours);
            handler.depositCollateralFor(0, i, 100e6);
            (uint256 borrowBaseAfter, uint256 indexAfter, uint64 timestampAfter) = engine.positionCarryState(account);
            assertEq(borrowBaseAfter, borrowBaseBefore, "Funding must preserve the position's carry basis");
            assertEq(indexAfter, indexBefore, "Funding must not advance the position carry checkpoint");
            assertEq(timestampAfter, timestampBefore, "Repeated funding must not reset the carry interval");
            assertEq(
                clearinghouse.pnlPledgeAssets(account), marginBefore, "Funding must not allocate or consume pledge"
            );
            assertEq(housePool.totalAssets(), poolBefore, "Funding must not collect carry into the pool");
            _assertAllInvariants();
        }

        assertEq(handler.ghostTotalTraderMinted() - mintedBefore, 300e6, "Each payer mint must be counted once");
        assertEq(clearinghouse.balanceAssets(account), settlementBefore + 300e6, "Every credit must remain in custody");
        handler.syncMarkNow(1e8);
        // At the unchanged entry mark with no claims, the lens's equity reduction is the deferred carry debit.
        AccountLensViewTypes.AccountLedgerSnapshot memory projected =
            engineAccountLens.getAccountLedgerSnapshot(account);
        assertEq(projected.unrealizedPnlAssets, 0, "Carry comparison needs unchanged price PnL");
        assertGt(projected.netEquityAssets, 0, "The funded position must remain healthy");
        uint256 projectedCarry = marginBefore - uint256(projected.netEquityAssets);
        assertGt(projectedCarry, 0, "The sequence must accrue collectible carry");

        handler.withdrawCollateral(0, 100e6);
        assertTrue(handler.lastWithdrawParityAttemptSnapshot().withdrawPasses, "Funded withdrawal must succeed");
        assertEq(
            clearinghouse.balanceAssets(account),
            settlementBefore + 200e6 - projectedCarry,
            "Withdrawal must collect the full deferred carry exactly once"
        );
        assertEq(housePool.totalAssets(), poolBefore + projectedCarry, "Collected carry must reach the pool");
        assertEq(clearinghouse.pnlPledgeAssets(account), marginBefore - projectedCarry, "Carry remains margin-first");
        assertEq(engine.unsettledCarryAssets(account), 0, "Fully funded carry must leave no arrears");
        _assertAllInvariants();
    }

    function test_ThirdPartyCreditsFundTradingAndWithdrawalWithoutChangingClaimGhosts() public {
        address account = handler.actorAt(0);
        handler.withdrawCollateral(0, clearinghouse.balanceAssets(account));
        assertEq(clearinghouse.balanceAssets(account), 0, "Remove seeded collateral before third-party funding");
        uint256 mintedBefore = handler.ghostTotalTraderMinted();
        for (uint256 i; i < 3; ++i) {
            handler.depositCollateralFor(0, i, 1000e6);
            _assertAllInvariants();
        }
        assertEq(handler.ghostTotalTraderMinted() - mintedBefore, 3000e6, "Track third-party funding exactly once");
        assertEq(handler.traderClaimSnapshot(account), 0, "Free funding must not create a claim ghost");
        assertEq(handler.committedMarginSnapshot(account), 0, "Free funding must not create an order reservation");

        uint256 executedBefore = handler.ghostExecutedOrderCount();
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();
        assertGt(_positionSize(account), 0, "Third-party credit must fund a real open");
        assertEq(handler.ghostTotalTraderMinted() - mintedBefore, 3000e6, "Opening must not need self-deposit top-up");
        _assertAllInvariants();

        handler.commitCloseOrder(0, 1e8);
        handler.executeNextOrderModelled();
        assertEq(_positionSize(account), 0, "Funded position must close through the existing order path");
        assertEq(handler.ghostExecutedOrderCount(), executedBefore + 2, "Both trade actions must actually execute");
        _assertAllInvariants();

        uint256 freeSettlement = clearinghouse.getAccountAssetBuckets(account).freeSettlementAssets;
        assertGt(freeSettlement, 1e6, "Terminal settlement must leave withdrawable funding");
        handler.withdrawCollateral(0, freeSettlement);
        assertTrue(
            handler.lastWithdrawParityAttemptSnapshot().withdrawPasses, "Recipient must withdraw remaining credit"
        );
        assertEq(clearinghouse.balanceAssets(account), 0, "All unspent terminal credit must leave custody");
        _assertAllInvariants();
    }

    function test_BatchSynchronizesClaimsForEveryProcessedOrderOwner() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.commitOpenOrder(1, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();
        handler.executeNextOrderModelled();

        address firstAccount = _account(handler.actorAt(0));
        address secondAccount = _account(handler.actorAt(1));
        assertGt(_positionSize(firstAccount), 0, "First position must be live");
        assertGt(_positionSize(secondAccount), 0, "Second position must be live");

        handler.commitCloseOrder(0, 0.5e8);
        handler.createTraderClaim(1);

        uint256 firstClaimAssets = engine.traderClaimBalanceAssets(firstAccount);
        uint256 secondClaimAssets = engine.traderClaimBalanceAssets(secondAccount);
        assertGt(firstClaimAssets, 0, "Earlier batched close must create a claim");
        assertGt(secondClaimAssets, 0, "Requested batched close must create a claim");
        assertEq(handler.traderClaimSnapshot(firstAccount), firstClaimAssets, "First owner claim cache mismatch");
        assertEq(handler.traderClaimSnapshot(secondAccount), secondClaimAssets, "Second owner claim cache mismatch");
        assertEq(
            handler.totalTraderClaimSnapshot(),
            engine.totalTraderClaimBalanceAssets(),
            "Aggregate claim cache must include every processed owner"
        );
    }

    function test_ExpiredModelledTerminalCloseDoesNotCreateExecutionGhosts() public {
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 1e8);
        handler.executeNextOrderModelled();

        address account = _account(handler.actorAt(0));
        uint256 sizeBefore = _positionSize(account);
        assertGt(sizeBefore, 0, "Position must be live");

        handler.setPoolAssets(0);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, sizeBefore, 0.5e8);
        assertTrue(preview.valid, "Profitable terminal close preview must be valid");
        assertEq(preview.remainingSize, 0, "Close preview must be terminal");
        assertGt(preview.traderClaimBalanceAssets, 0, "Close preview must project a deferred claim");

        uint64 closeOrderId = router.nextCommitId();
        handler.commitCloseOrder(0, 0.5e8);
        uint256 executedBefore = handler.ghostExecutedOrderCount();
        uint256 liveClaimBefore = engine.traderClaimBalanceAssets(account);
        uint256 observedClaimBefore = handler.traderClaimSnapshot(account);
        assertEq(handler.accountExecutionBountyReserve(account), 0, "Close does not reserve bounty cash");

        handler.warpForward(router.maxExecutionWindowSeconds() + 1);
        handler.executeNextOrderModelled();

        assertEq(handler.ghostOrderLifecycleState(closeOrderId), 3, "Expired close must be tracked as failed");
        assertEq(_positionSize(account), sizeBefore, "Expired close must not mutate the position");
        assertEq(handler.ghostExecutedOrderCount(), executedBefore, "Expired close must not count as executed");
        assertEq(engine.traderClaimBalanceAssets(account), liveClaimBefore, "Expired close must not create a claim");
        assertEq(
            handler.traderClaimSnapshot(account), observedClaimBefore, "Expired close must not mutate claim mirror"
        );
        assertEq(router.pendingOrderCounts(account), 0, "Expired close must leave the pending queue");
        assertEq(handler.accountExecutionBountyReserve(account), 0, "Expired close bounty must be cleared");
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets,
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

    function _assertInvariant_KnownActorAndProtocolBalancesConserveAssetsSupply() internal view {
        assertEq(
            _knownBalancesSum(),
            settlementToken.totalSupply(),
            "Known actors and protocol contracts must conserve total settlementToken supply"
        );
    }

    function _assertInvariant_ClearinghouseCustodyMatchesTrackedAccountBalances() internal view {
        uint256 trackedBalances = clearinghouse.balanceAssets(_account(address(handler)))
            + clearinghouse.balanceAssets(engine.protocolTreasury());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            trackedBalances += clearinghouse.balanceAssets(_account(handler.actorAt(i)));
        }

        assertEq(
            settlementToken.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse custody must equal tracked account settlement balances"
        );
    }

    function _assertInvariant_WithdrawalReserveIncludesKnownTraderClaimLiabilities() internal view {
        uint256 maxLiability = _enumeratedLiability();
        uint256 expectedReserved = maxLiability + engine.totalTraderClaimBalanceAssets()
            + _independentBuffer(maxLiability, engine.settlementBufferBps());

        assertEq(
            _withdrawalReservedAssets(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, trader claims, and settlement headroom"
        );
    }

    /// @dev Reconstructs endpoint payouts from canonical positions, not the Engine's cached side liabilities.
    ///      This is independent aggregation over observed positions, not an independent trade-history model.
    function _enumeratedLiability() internal view returns (uint256) {
        uint256 longLiability;
        uint256 shortLiability;
        uint256 longSize;
        uint256 shortSize;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address account = handler.actorAt(i);
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }
            uint256 basis = engine.positionEntryCostAssetAtoms(account);
            if (side == CfdTypes.Side.LONG) {
                longLiability += basis;
                longSize += size;
            } else {
                shortLiability += (size / CfdTypes.SIZE_QUANTUM) * CAP_PRICE - basis;
                shortSize += size;
            }
        }
        (, uint256 actualLongSize,,) = engine.sides(uint8(CfdTypes.Side.LONG));
        (, uint256 actualShortSize,,) = engine.sides(uint8(CfdTypes.Side.SHORT));
        assertEq(longSize, actualLongSize, "reserve actor domain must include every long");
        assertEq(shortSize, actualShortSize, "reserve actor domain must include every short");
        return longLiability > shortLiability ? longLiability : shortLiability;
    }

    function _independentBuffer(
        uint256 liability,
        uint256 bps
    ) internal pure returns (uint256) {
        // Handler values are bounded well below multiplication overflow; reserves round upward by one atom.
        uint256 product = liability * bps;
        return product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
    }

    function _assertInvariant_TrackedAccountBucketsReconcileSettlementBalances() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            uint256 protectedMargin = size > 0 ? margin : 0;

            IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(account);
            IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets =
                clearinghouse.getLockedMarginBuckets(account);
            IMarginClearinghouse.PnlIsolationBuckets memory isolationBuckets =
                clearinghouse.getPnlIsolationBuckets(account);

            assertEq(
                buckets.totalLockedMarginAssets,
                buckets.activePositionMarginAssets + buckets.otherLockedMarginAssets,
                "Tracked account locked margin buckets must reconcile"
            );
            assertEq(
                buckets.activePositionMarginAssets,
                lockedBuckets.positionMarginAssets,
                "Tracked account active margin must equal typed position margin bucket"
            );
            assertEq(
                buckets.otherLockedMarginAssets,
                isolationBuckets.liquidationReserveAssets + isolationBuckets.orderMarginAssets
                    + isolationBuckets.actionReserveAssets,
                "Tracked account other locked margin must equal canonical non-position buckets"
            );
            assertEq(
                buckets.totalLockedMarginAssets,
                lockedBuckets.totalLockedMarginAssets,
                "Tracked account total locked margin must equal typed bucket total"
            );
            assertEq(
                buckets.settlementBalanceAssets,
                buckets.totalLockedMarginAssets + buckets.freeSettlementAssets,
                "Tracked account settlement balance must equal locked plus free buckets"
            );
            assertEq(
                buckets.settlementBalanceAssets,
                clearinghouse.balanceAssets(account),
                "Tracked account bucket settlement must equal clearinghouse balance"
            );
        }
    }

    function _assertInvariant_AccountLedgerViewMatchesUnderlyingBuckets() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            uint256 protectedMargin = size > 0 ? margin : 0;

            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
            IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(account);
            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

            assertEq(
                ledgerView.settlementBalanceAssets,
                buckets.settlementBalanceAssets,
                "Account ledger settlement mismatch"
            );
            assertEq(
                ledgerView.freeSettlementAssets, buckets.freeSettlementAssets, "Account ledger free settlement mismatch"
            );
            assertEq(
                ledgerView.activePositionMarginAssets,
                buckets.activePositionMarginAssets,
                "Account ledger active margin mismatch"
            );
            assertEq(
                ledgerView.otherLockedMarginAssets,
                buckets.otherLockedMarginAssets,
                "Account ledger other locked margin mismatch"
            );
            assertEq(
                ledgerView.executionBountyReserveAssets,
                reservation.executionBountyAssets,
                "Account ledger execution reservation mismatch"
            );
            assertEq(
                ledgerView.committedMarginAssets,
                reservation.committedMarginAssets,
                "Account ledger committed margin mismatch"
            );
            assertEq(
                ledgerView.traderClaimBalanceAssets,
                engine.traderClaimBalanceAssets(account),
                "Account ledger trader claim mismatch"
            );
            assertEq(
                ledgerView.pendingOrderCount,
                router.pendingOrderCounts(account),
                "Account ledger pending order count mismatch"
            );
        }
    }

    function _assertInvariant_TrackedAccountLedgerTotalsMatchProtocolCustodyAndObligations() internal view {
        uint256 totalSettlementAssets = engineAccountLens.getAccountLedgerView(_account(address(handler)))
            .settlementBalanceAssets + clearinghouse.balanceAssets(engine.protocolTreasury());
        uint256 totalReservedSettlementAssets =
            clearinghouse.getLockedMarginBuckets(_account(address(handler))).reservedSettlementAssets;
        uint256 totalExecutionReservationAssets;
        uint256 totalTraderClaimBalanceAssets;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
            totalSettlementAssets += ledgerView.settlementBalanceAssets;
            totalExecutionReservationAssets += ledgerView.executionBountyReserveAssets;
            totalTraderClaimBalanceAssets += ledgerView.traderClaimBalanceAssets;
            totalReservedSettlementAssets += clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets;
        }

        assertEq(
            totalSettlementAssets,
            settlementToken.balanceOf(address(clearinghouse)),
            "Tracked settlement totals must match clearinghouse custody"
        );
        assertEq(
            totalExecutionReservationAssets,
            totalReservedSettlementAssets,
            "Tracked execution reservation totals must match clearinghouse reserved settlement"
        );
        assertEq(settlementToken.balanceOf(address(router)), 0, "Router must not custody execution bounty reservation");
        assertEq(
            totalTraderClaimBalanceAssets,
            engine.totalTraderClaimBalanceAssets(),
            "Tracked trader claim totals must match engine obligations"
        );
    }

    function _assertInvariant_PriceLossEventLeavesExactlyThePreviewedTraderClaim() internal view {
        PerpAccountingHandler.PriceLossTraderClaimEvent memory eventSnapshot =
            handler.lastPriceLossTraderClaimEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        assertEq(
            engine.traderClaimBalanceAssets(eventSnapshot.account),
            eventSnapshot.expectedTraderClaimAfterAssets,
            "Terminal price-loss settlement must leave exactly the claim projected by the planner"
        );
    }

    function _assertInvariant_TerminalEventsMatchResidualAndPriceWriteoffAccounting() internal view {
        PerpAccountingHandler.TerminalResidualEvent memory eventSnapshot = handler.lastTerminalResidualEventSnapshot();
        if (!eventSnapshot.active) {
            return;
        }

        address trader = eventSnapshot.account;
        uint256 actualFinalResidualAssets =
            clearinghouse.balanceAssets(eventSnapshot.account) + engine.traderClaimBalanceAssets(eventSnapshot.account);
        if (eventSnapshot.walletPayoutExpected) {
            actualFinalResidualAssets += settlementToken.balanceOf(trader) - eventSnapshot.traderWalletBeforeAssets;
        }

        assertEq(
            actualFinalResidualAssets,
            eventSnapshot.expectedFinalResidualAssets,
            "Terminal event residual should match retained settlement plus trader claim and any immediate payout"
        );
    }

    function _assertInvariant_AccountLedgerSnapshotMatchesUnderlyingViews() internal view {
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
                snapshot.settlementBalanceAssets,
                ledgerView.settlementBalanceAssets,
                "Account snapshot settlement mismatch"
            );
            assertEq(
                snapshot.freeSettlementAssets,
                ledgerView.freeSettlementAssets,
                "Account snapshot free settlement mismatch"
            );
            assertEq(
                snapshot.activePositionMarginAssets,
                ledgerView.activePositionMarginAssets,
                "Account snapshot active margin mismatch"
            );
            assertEq(
                snapshot.otherLockedMarginAssets,
                ledgerView.otherLockedMarginAssets,
                "Account snapshot other locked margin mismatch"
            );
            assertEq(
                snapshot.positionMarginBucketAssets,
                lockedBuckets.positionMarginAssets,
                "Account snapshot position bucket mismatch"
            );
            assertEq(
                snapshot.committedOrderMarginBucketAssets,
                lockedBuckets.committedOrderMarginAssets,
                "Account snapshot committed-order bucket mismatch"
            );
            assertEq(
                snapshot.reservedSettlementBucketAssets,
                lockedBuckets.reservedSettlementAssets,
                "Account snapshot reserved-settlement bucket mismatch"
            );
            assertEq(
                snapshot.activePositionMarginAssets,
                snapshot.positionMarginBucketAssets,
                "Account snapshot active margin must equal typed position bucket"
            );
            assertEq(
                snapshot.otherLockedMarginAssets,
                isolationBuckets.liquidationReserveAssets + isolationBuckets.orderMarginAssets
                    + isolationBuckets.actionReserveAssets,
                "Account snapshot other locked margin must equal canonical non-position buckets"
            );
            assertEq(
                snapshot.executionBountyReserveAssets,
                ledgerView.executionBountyReserveAssets,
                "Account snapshot execution reservation mismatch"
            );
            assertEq(
                snapshot.committedMarginAssets,
                ledgerView.committedMarginAssets,
                "Account snapshot committed margin mismatch"
            );
            assertEq(
                snapshot.traderClaimBalanceAssets,
                ledgerView.traderClaimBalanceAssets,
                "Account snapshot trader claim mismatch"
            );
            assertEq(
                snapshot.pendingOrderCount,
                ledgerView.pendingOrderCount,
                "Account snapshot pending order count mismatch"
            );
            assertEq(
                snapshot.closeReachableAssets,
                collateralView.closeReachableAssets,
                "Account snapshot close reachable mismatch"
            );
            assertEq(
                snapshot.liquidationReachableSettlementAssets,
                collateralView.liquidationReachableSettlementAssets,
                "Account snapshot liquidation reachability mismatch"
            );
            assertEq(
                snapshot.terminalPriceCollectibleCapAssets,
                collateralView.terminalPriceCollectibleCapAssets,
                "Account snapshot terminal price cap mismatch"
            );
            assertEq(
                snapshot.accountEquityAssets, collateralView.accountEquityAssets, "Account snapshot equity mismatch"
            );
            assertEq(
                snapshot.freeBuyingPowerAssets,
                collateralView.freeBuyingPowerAssets,
                "Account snapshot buying power mismatch"
            );
            assertEq(snapshot.hasPosition, positionView.hasPosition, "Account snapshot position flag mismatch");
            assertEq(uint256(snapshot.side), uint256(positionView.side), "Account snapshot side mismatch");
            assertEq(snapshot.size, positionView.size, "Account snapshot size mismatch");
            assertEq(snapshot.margin, positionView.margin, "Account snapshot margin mismatch");
            assertEq(snapshot.entryPrice, positionView.entryPrice, "Account snapshot entry price mismatch");
            assertEq(
                snapshot.unrealizedPnlAssets,
                positionView.unrealizedPnlAssets,
                "Account snapshot unrealized pnl mismatch"
            );
            assertEq(snapshot.netEquityAssets, positionView.netEquityAssets, "Account snapshot net equity mismatch");
            assertEq(snapshot.liquidatable, positionView.liquidatable, "Account snapshot liquidatable mismatch");
        }
    }

    function _assertInvariant_ReachabilityMonotonicityHoldsForDepositsAndWithdrawals() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            PerpAccountingHandler.ReachabilityTransition memory transition = handler.reachabilityTransition(account);

            if (transition.action == 1) {
                assertGe(
                    transition.afterCloseReachableAssets,
                    transition.beforeCloseReachableAssets,
                    "Deposits must not reduce close-reachable settlement"
                );
                assertGe(
                    transition.afterTerminalReachableAssets,
                    transition.beforeTerminalReachableAssets,
                    "Deposits must not reduce liquidation-reachable settlement"
                );
            } else if (transition.action == 2) {
                assertLe(
                    transition.afterCloseReachableAssets,
                    transition.beforeCloseReachableAssets,
                    "Withdrawals must not increase close-reachable settlement"
                );
                assertLe(
                    transition.afterTerminalReachableAssets,
                    transition.beforeTerminalReachableAssets,
                    "Withdrawals must not increase liquidation-reachable settlement"
                );
            }
        }
    }

    function _assertInvariant_NoOrphanedAccountStateWhenNoPositionAndNoPendingOrders() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(_account(handler.actorAt(i)));
            if (snapshot.hasPosition || snapshot.pendingOrderCount != 0) {
                continue;
            }

            assertEq(snapshot.activePositionMarginAssets, 0, "Orphaned accounts must not keep active margin");
            assertEq(snapshot.otherLockedMarginAssets, 0, "Orphaned accounts must not keep other locked margin");
            assertEq(snapshot.executionBountyReserveAssets, 0, "Orphaned accounts must not keep execution reservation");
            assertEq(snapshot.committedMarginAssets, 0, "Orphaned accounts must not keep committed margin");
            assertEq(
                snapshot.closeReachableAssets,
                snapshot.freeSettlementAssets,
                "Orphaned accounts close reachability must equal free settlement"
            );
            assertEq(
                snapshot.liquidationReachableSettlementAssets,
                snapshot.settlementBalanceAssets,
                "Orphaned accounts liquidation reachability must equal settlement balance"
            );
            assertEq(
                snapshot.terminalPriceCollectibleCapAssets, 0, "Orphaned accounts must have zero terminal price cap"
            );
            assertEq(snapshot.size, 0, "Orphaned accounts must have zero size");
            assertEq(snapshot.margin, 0, "Orphaned accounts must have zero margin");
            assertEq(snapshot.entryPrice, 0, "Orphaned accounts must have zero entry price");
            assertEq(snapshot.unrealizedPnlAssets, 0, "Orphaned accounts must have zero unrealized pnl");
            assertEq(snapshot.netEquityAssets, 0, "Orphaned accounts must have zero net equity");
            assertFalse(snapshot.liquidatable, "Orphaned accounts must not be liquidatable");
        }
    }

    function _assertInvariant_AccountLedgerSnapshotFullySubsumesCompactAndLegacyViews() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            AccountLensViewTypes.AccountLedgerView memory compactView = engineAccountLens.getAccountLedgerView(account);
            ICfdEngineTypes.AccountCollateralView memory collateralView =
                engineAccountLens.getAccountCollateralView(account);
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView = snapshot;

            assertEq(
                snapshot.settlementBalanceAssets,
                compactView.settlementBalanceAssets,
                "Snapshot must subsume compact settlement"
            );
            assertEq(
                snapshot.freeSettlementAssets,
                compactView.freeSettlementAssets,
                "Snapshot must subsume compact free settlement"
            );
            assertEq(
                snapshot.executionBountyReserveAssets,
                compactView.executionBountyReserveAssets,
                "Snapshot must subsume compact execution reservation"
            );
            assertEq(
                snapshot.traderClaimBalanceAssets,
                compactView.traderClaimBalanceAssets,
                "Snapshot must subsume compact trader claim"
            );
            assertEq(
                snapshot.closeReachableAssets,
                collateralView.closeReachableAssets,
                "Snapshot must subsume collateral close reachability"
            );
            assertEq(
                snapshot.liquidationReachableSettlementAssets,
                collateralView.liquidationReachableSettlementAssets,
                "Snapshot must subsume collateral liquidation reachability"
            );
            assertEq(
                snapshot.terminalPriceCollectibleCapAssets,
                collateralView.terminalPriceCollectibleCapAssets,
                "Snapshot must subsume collateral terminal price cap"
            );
            assertEq(
                snapshot.accountEquityAssets,
                collateralView.accountEquityAssets,
                "Snapshot must subsume collateral equity"
            );
            assertEq(snapshot.hasPosition, positionView.hasPosition, "Snapshot must subsume position existence");
            assertEq(snapshot.size, positionView.size, "Snapshot must subsume position size");
            assertEq(
                snapshot.netEquityAssets, positionView.netEquityAssets, "Snapshot must subsume position net equity"
            );
            assertEq(snapshot.liquidatable, positionView.liquidatable, "Snapshot must subsume liquidatable flag");
        }
    }

    function _assertInvariant_HousePoolInputSnapshotMatchesGlobalLedgerBuckets() internal view {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(60 seconds);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        uint256 poolAssets = housePool.totalAssets();
        uint256 maxLiabilityAssets = _enumeratedLiability();
        uint256 settlementBufferAssets = _independentBuffer(maxLiabilityAssets, engine.settlementBufferBps());
        uint256 expectedWithdrawalReservedAssets =
            maxLiabilityAssets + engine.totalTraderClaimBalanceAssets() + settlementBufferAssets;
        uint256 expectedFreeAssets =
            poolAssets > expectedWithdrawalReservedAssets ? poolAssets - expectedWithdrawalReservedAssets : 0;

        assertEq(protocolSnapshot.poolAssets, poolAssets, "Protocol snapshot HousePool assets mismatch");
        assertEq(
            protocolSnapshot.protocolTreasuryBalanceAssets,
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            "Protocol snapshot fees mismatch"
        );
        uint256 expectedEffectiveSolvencyAssets = poolAssets > engine.totalTraderClaimBalanceAssets()
            ? poolAssets - engine.totalTraderClaimBalanceAssets()
            : 0;
        assertEq(
            protocolSnapshot.effectiveSolvencyAssets,
            expectedEffectiveSolvencyAssets,
            "Price writeoffs must not create a second subtraction from physical solvency assets"
        );
        assertEq(
            protocolSnapshot.withdrawalReservedAssets,
            expectedWithdrawalReservedAssets,
            "Protocol snapshot withdrawal reserve mismatch"
        );
        assertEq(protocolSnapshot.freeAssets, expectedFreeAssets, "Protocol snapshot free settlementToken mismatch");
        assertEq(
            snapshot.traderClaimBalanceAssets,
            engine.totalTraderClaimBalanceAssets(),
            "House-pool snapshot trader claim balance mismatch"
        );
        assertEq(snapshot.maxLiabilityAssets, maxLiabilityAssets, "House-pool snapshot max liability mismatch");
        assertEq(
            snapshot.supplementalReservedAssets,
            settlementBufferAssets,
            "House-pool snapshot supplemental reserved amount mismatch"
        );
        assertEq(
            snapshot.physicalAssets,
            poolAssets,
            "House-pool snapshot physical assets must match canonical HousePool assets"
        );
        assertEq(
            snapshot.netPhysicalAssets,
            settlementToken.balanceOf(address(housePool)),
            "Mock pool backing is its actual token custody, independent of treasury settlement"
        );
        assertEq(snapshot.physicalAssets, poolAssets, "House-pool snapshot physical asset decomposition mismatch");
        assertEq(
            protocolSnapshot.netPhysicalAssets,
            settlementToken.balanceOf(address(housePool)),
            "Protocol backing must match actual mock pool custody, not another lens field"
        );
        assertEq(
            protocolSnapshot.maxLiabilityAssets, snapshot.maxLiabilityAssets, "Protocol snapshot max liability mismatch"
        );
        assertEq(
            protocolSnapshot.totalTraderClaimBalanceAssets,
            snapshot.traderClaimBalanceAssets,
            "Protocol snapshot trader claim balance mismatch"
        );
    }

    function _assertInvariant_HousePoolStatusSnapshotMatchesEngineState() internal view {
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot =
            engineProtocolLens.getHousePoolStatusSnapshot();

        assertEq(snapshot.lastMarkTime, engine.lastMarkTime(), "House-pool status last mark time mismatch");
        assertEq(snapshot.oracleFrozen, engine.isOracleFrozen(), "House-pool status oracle frozen mismatch");
        assertEq(snapshot.degradedMode, engine.degradedMode(), "House-pool status degraded mode mismatch");
    }

    function _assertInvariant_LiquidationClearsExecutionBounties() internal view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address account = _account(handler.actorAt(i));
            (, uint256 liveReserves, uint256 reserved) = handler.liquidatedGenerationExposure(account);
            assertEq(liveReserves, 0, "Liquidated generations must forfeit all reservations");
            assertEq(reserved, 0, "Liquidation must forfeit old-generation bounty and margin reserves");
            assertEq(
                settlementToken.balanceOf(account),
                handler.ghost().expectedWalletFromSubmittedFlows(account),
                "Wallet credits must equal submitted withdrawal flows"
            );
        }
    }

    function _assertInvariant_ObservedClaimsReconcileWithEngine() internal view {
        uint256 observedTotalTraderClaims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 observedTraderClaimAssets = handler.traderClaimSnapshot(account);
            uint256 liveTraderClaimAssets = engine.traderClaimBalanceAssets(account);

            assertEq(
                observedTraderClaimAssets,
                liveTraderClaimAssets,
                "Observed trader claim balance must match engine storage"
            );
            observedTotalTraderClaims += observedTraderClaimAssets;
        }

        assertEq(
            handler.totalTraderClaimSnapshot(),
            observedTotalTraderClaims,
            "Observed trader claim balance total must match tracked account sum"
        );
        assertEq(
            engine.totalTraderClaimBalanceAssets(),
            observedTotalTraderClaims,
            "Engine trader claim total must match tracked ghost sum"
        );
    }

    function _knownBalancesSum() internal view returns (uint256 totalBalances) {
        totalBalances += settlementToken.balanceOf(address(this));
        totalBalances += settlementToken.balanceOf(address(handler));
        totalBalances += settlementToken.balanceOf(address(engine));
        totalBalances += settlementToken.balanceOf(address(clearinghouse));
        totalBalances += settlementToken.balanceOf(address(router));
        totalBalances += settlementToken.balanceOf(address(housePool));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            totalBalances += settlementToken.balanceOf(handler.actorAt(i));
        }
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_TrackedCustodyClaimsAndWithdrawalReservesReconcile() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_KnownActorAndProtocolBalancesConserveAssetsSupply();
        _assertInvariant_ClearinghouseCustodyMatchesTrackedAccountBalances();
        _assertInvariant_WithdrawalReserveIncludesKnownTraderClaimLiabilities();
        _assertInvariant_TrackedAccountBucketsReconcileSettlementBalances();
        _assertInvariant_AccountLedgerViewMatchesUnderlyingBuckets();
        _assertInvariant_TrackedAccountLedgerTotalsMatchProtocolCustodyAndObligations();
        _assertInvariant_PriceLossEventLeavesExactlyThePreviewedTraderClaim();
        _assertInvariant_TerminalEventsMatchResidualAndPriceWriteoffAccounting();
        _assertInvariant_AccountLedgerSnapshotMatchesUnderlyingViews();
        _assertInvariant_ReachabilityMonotonicityHoldsForDepositsAndWithdrawals();
        _assertInvariant_NoOrphanedAccountStateWhenNoPositionAndNoPendingOrders();
        _assertInvariant_AccountLedgerSnapshotFullySubsumesCompactAndLegacyViews();
        _assertInvariant_HousePoolInputSnapshotMatchesGlobalLedgerBuckets();
        _assertInvariant_HousePoolStatusSnapshotMatchesEngineState();
        _assertInvariant_LiquidationClearsExecutionBounties();
        _assertInvariant_ObservedClaimsReconcileWithEngine();
    }

}
