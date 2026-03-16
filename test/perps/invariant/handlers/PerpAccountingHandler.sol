// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../../src/perps/OrderRouter.sol";
import {ICfdEngine} from "../../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {PerpGhostLedger} from "../ghost/PerpGhostLedger.sol";
import {MockInvariantVault} from "../mocks/MockInvariantVault.sol";
import {Test} from "forge-std/Test.sol";

contract PerpAccountingHandler is Test {

    uint8 internal constant GHOST_ORDER_NONE = 0;
    uint8 internal constant GHOST_ORDER_PENDING = 1;
    uint8 internal constant GHOST_ORDER_EXECUTED = 2;
    uint8 internal constant GHOST_ORDER_FAILED = 3;
    uint8 internal constant GHOST_ORDER_LIQUIDATED = 4;
    uint8 internal constant REACHABILITY_ACTION_NONE = 0;
    uint8 internal constant REACHABILITY_ACTION_DEPOSIT = 1;
    uint8 internal constant REACHABILITY_ACTION_WITHDRAW = 2;

    struct ReachabilityTransition {
        uint8 action;
        uint256 beforeCloseReachableUsdc;
        uint256 afterCloseReachableUsdc;
        uint256 beforeLiquidationReachableUsdc;
        uint256 afterLiquidationReachableUsdc;
    }

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    OrderRouter public immutable router;
    MockInvariantVault public immutable vault;
    PerpGhostLedger public immutable ghost;

    address[4] internal actors;

    uint256 public ghostTotalTraderMinted;
    uint256 public ghostTotalVaultMinted;
    uint256 public ghostSuccessfulLiquidations;

    mapping(uint64 => bytes32) internal ghostOrderOwner;
    mapping(uint64 => uint256) internal ghostOrderCommittedMargin;
    mapping(uint64 => uint8) internal ghostOrderState;
    mapping(uint64 => uint256) internal ghostReservationOriginal;
    mapping(uint64 => uint256) internal ghostReservationConsumed;
    mapping(uint64 => uint256) internal ghostReservationReleased;
    mapping(bytes32 => ReachabilityTransition) internal reachabilityTransitions;

    bytes32 internal lastTerminalReservationAccountId;
    uint256 internal lastTerminalReservationCount;
    uint256 internal lastTerminalActiveReservationCountBefore;
    uint64[5] internal lastTerminalReservationIds;
    uint256[5] internal lastTerminalReservationRemainingBefore;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        MarginClearinghouse _clearinghouse,
        OrderRouter _router,
        MockInvariantVault _vault
    ) {
        usdc = _usdc;
        engine = _engine;
        clearinghouse = _clearinghouse;
        router = _router;
        vault = _vault;

        actors[0] = address(0x5101);
        actors[1] = address(0x5102);
        actors[2] = address(0x5103);
        actors[3] = address(0x5104);

        ghost = new PerpGhostLedger(address(this));
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function seedActors(
        uint256 traderDepositUsdc,
        uint256 vaultSeedUsdc
    ) external {
        for (uint256 i = 0; i < actors.length; i++) {
            _mintAndDepositTrader(actors[i], traderDepositUsdc);
        }

        vault.seedAssets(vaultSeedUsdc);
        ghostTotalVaultMinted += vaultSeedUsdc;
    }

    function depositCollateral(
        uint256 actorIndex,
        uint256 amountFuzz
    ) external {
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        ICfdEngine.AccountLedgerSnapshot memory beforeSnapshot = engine.getAccountLedgerSnapshot(_accountId(actor));
        uint256 amount = bound(amountFuzz, 1e6, 250_000e6);
        _mintAndDepositTrader(actor, amount);
        ICfdEngine.AccountLedgerSnapshot memory afterSnapshot = engine.getAccountLedgerSnapshot(_accountId(actor));
        _recordReachabilityTransition(_accountId(actor), REACHABILITY_ACTION_DEPOSIT, beforeSnapshot, afterSnapshot);
    }

    function withdrawCollateral(
        uint256 actorIndex,
        uint256 amountFuzz
    ) external {
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        if (freeSettlement == 0) {
            return;
        }

        ICfdEngine.AccountLedgerSnapshot memory beforeSnapshot = engine.getAccountLedgerSnapshot(accountId);
        uint256 amount = bound(amountFuzz, 1e6, freeSettlement);
        vm.prank(actor);
        clearinghouse.withdraw(accountId, amount);
        ICfdEngine.AccountLedgerSnapshot memory afterSnapshot = engine.getAccountLedgerSnapshot(accountId);
        _recordReachabilityTransition(accountId, REACHABILITY_ACTION_WITHDRAW, beforeSnapshot, afterSnapshot);
    }

    function commitOpenOrder(
        uint256 actorIndex,
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginDeltaFuzz,
        uint256 targetPriceFuzz
    ) external {
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        uint256 targetPrice = bound(targetPriceFuzz, 0.5e8, 1.5e8);
        uint256 sizeDelta = bound(sizeFuzz, 1000e18, 100_000e18);
        uint256 marginDelta = bound(marginDeltaFuzz, 0, 50_000e6);
        uint256 neededUsdc = marginDelta + 2e6;
        _ensureFreeSettlement(actor, neededUsdc);

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
        uint64 orderId = router.nextCommitId();
        bytes32 accountId = _accountId(actor);

        vm.prank(actor);
        try router.commitOrder(side, sizeDelta, marginDelta, targetPrice, false) {
            _registerPendingOrder(orderId, accountId, marginDelta);
        } catch {}
    }

    function commitCloseOrder(
        uint256 actorIndex,
        uint256 targetPriceFuzz
    ) external {
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 targetPrice = bound(targetPriceFuzz, 0.5e8, 1.5e8);
        uint64 orderId = router.nextCommitId();

        vm.prank(actor);
        try router.commitOrder(side, size, 0, targetPrice, true) {
            _registerPendingOrder(orderId, accountId, 0);
        } catch {}
    }

    function executeNextOrderBatch(
        uint256 batchSizeFuzz
    ) external {
        _clearTerminalReservationSet();
        uint64 nextExecuteId = router.nextExecuteId();
        if (nextExecuteId >= router.nextCommitId()) {
            return;
        }

        uint64 batchSize = uint64(bound(batchSizeFuzz, 1, 4));
        bytes[] memory empty;
        uint64 startExecuteId = nextExecuteId;
        uint256[4] memory committedBefore = _snapshotTrackedCommittedMargin();
        try router.executeOrderBatch(batchSize, empty) {
            _reconcileCommittedMarginAfterProcessedOrders(committedBefore, startExecuteId, router.nextExecuteId());
        } catch {}
    }

    function executeNextOrderModelled() external {
        _clearTerminalReservationSet();
        uint64 orderId = router.nextExecuteId();
        if (orderId >= router.nextCommitId()) {
            return;
        }

        (bytes32 accountId, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice,,,,, bool isClose) =
            router.orders(orderId);
        uint256 deferredTraderPayoutUsdc;
        if (isClose && marginDelta == 0) {
            CfdEngine.ClosePreview memory preview =
                engine.previewClose(accountId, sizeDelta, targetPrice, vaultAssetDepth());
            if (preview.valid) {
                deferredTraderPayoutUsdc = preview.deferredPayoutUsdc;
            }
        }

        uint256[4] memory committedBefore = _snapshotTrackedCommittedMargin();
        bytes[] memory empty;
        try router.executeOrder(orderId, empty) {
            _reconcileCommittedMarginAfterProcessedOrders(committedBefore, orderId, router.nextExecuteId());
            if (deferredTraderPayoutUsdc > 0) {
                ghost.increaseDeferredTraderPayout(accountId, deferredTraderPayoutUsdc);
            }
        } catch {}
    }

    function liquidate(
        uint256 actorIndex,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 price = bound(priceFuzz, 0.3e8, 1.8e8);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, price, vaultAssetDepth());
        uint256 keeperBountyUsdc = preview.keeperBountyUsdc;
        bool shouldDefer = vault.failRouterPayouts() && keeperBountyUsdc > 0;
        uint256 deferredTraderPayoutUsdc = preview.deferredPayoutUsdc;
        uint256 committedBefore = _trackedCommittedMargin(accountId);
        _recordTerminalReservationSet(accountId);

        try router.executeLiquidation(accountId, priceData) {
            ghost.recordLiquidation(accountId, usdc.balanceOf(actor), engine.accumulatedBadDebtUsdc());
            ghostSuccessfulLiquidations++;
            _reconcileCommittedMarginAfterLiquidation(accountId, committedBefore);
            if (deferredTraderPayoutUsdc > 0) {
                ghost.increaseDeferredTraderPayout(accountId, deferredTraderPayoutUsdc);
            }
            if (shouldDefer) {
                ghost.increaseDeferredClearerBounty(address(this), keeperBountyUsdc);
            }
        } catch {}
    }

    function claimDeferredClearerBounty() external {
        _clearTerminalReservationSet();
        uint256 ghostDeferredBounty = ghost.deferredClearerBountySnapshot(address(this));
        try engine.claimDeferredClearerBounty() {
            if (ghostDeferredBounty > 0) {
                ghost.decreaseDeferredClearerBounty(address(this), ghostDeferredBounty);
            }
        } catch {}
    }

    function createDeferredTraderPayout(
        uint256 actorIndex
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        if (router.pendingOrderCounts(accountId) != 0) {
            return;
        }

        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            _ensureFreeSettlement(actor, 25_000e6);
            uint64 openOrderId = router.nextCommitId();
            vm.prank(actor);
            try router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 20_000e6, 0, false) {
                _registerPendingOrder(openOrderId, accountId, 20_000e6);
            } catch {
                return;
            }

            bytes[] memory openPriceData = new bytes[](1);
            openPriceData[0] = abi.encode(uint256(1e8));
            uint64 startExecuteId = router.nextExecuteId();
            uint256[4] memory openCommittedBefore = _snapshotTrackedCommittedMargin();
            try router.executeOrderBatch(openOrderId, openPriceData) {
                _reconcileCommittedMarginAfterProcessedOrders(
                    openCommittedBefore, startExecuteId, router.nextExecuteId()
                );
            } catch {
                return;
            }

            (size,,,,, side,,) = engine.positions(accountId);
            if (size == 0) {
                return;
            }
        }

        vault.setAssets(0);
        uint256 closeOraclePrice = side == CfdTypes.Side.BULL ? uint256(15e7) : uint256(5e7);

        CfdEngine.ClosePreview memory closePreview =
            engine.previewClose(accountId, size, closeOraclePrice, vault.totalAssets());
        uint256 deferredTraderPayoutUsdc = closePreview.deferredPayoutUsdc;
        _recordTerminalReservationSet(accountId);

        uint64 closeOrderId = router.nextCommitId();
        vm.prank(actor);
        try router.commitOrder(side, size, 0, 0, true) {
            _registerPendingOrder(closeOrderId, accountId, 0);
        } catch {
            return;
        }

        bytes[] memory closePriceData = new bytes[](1);
        closePriceData[0] = abi.encode(closeOraclePrice);
        uint64 closeStartExecuteId = router.nextExecuteId();
        uint256[4] memory closeCommittedBefore = _snapshotTrackedCommittedMargin();
        try router.executeOrderBatch(closeOrderId, closePriceData) {
            _reconcileCommittedMarginAfterProcessedOrders(
                closeCommittedBefore, closeStartExecuteId, router.nextExecuteId()
            );
            if (deferredTraderPayoutUsdc > 0) {
                ghost.increaseDeferredTraderPayout(accountId, deferredTraderPayoutUsdc);
            }
        } catch {}
    }

    function claimDeferredPayout(
        uint256 actorIndex
    ) external {
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        bytes32 accountId = _accountId(actor);
        uint256 ghostDeferredPayout = ghost.deferredTraderPayoutSnapshot(accountId);

        vm.prank(actor);
        try engine.claimDeferredPayout(accountId) {
            if (ghostDeferredPayout > 0) {
                ghost.decreaseDeferredTraderPayout(accountId, ghostDeferredPayout);
            }
        } catch {}
    }

    function fundVault(
        uint256 amountFuzz
    ) external {
        _clearTerminalReservationSet();
        uint256 amount = bound(amountFuzz, 1000e6, 250_000e6);
        vault.seedAssets(amount);
        ghostTotalVaultMinted += amount;
    }

    function setRouterPayoutFailureMode(
        uint256 modeFuzz
    ) external {
        _clearTerminalReservationSet();
        vault.setFailRouterPayouts(modeFuzz % 2 == 1);
    }

    function setVaultAssets(
        uint256 amountFuzz
    ) external {
        _clearTerminalReservationSet();
        vault.setAssets(bound(amountFuzz, 0, 1_000_000_000e6));
    }

    function accountRouterEscrow(
        bytes32 accountId
    ) public view returns (uint256 totalEscrowUsdc) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (queuedAccountId != accountId || sizeDelta == 0) {
                continue;
            }
            totalEscrowUsdc += router.executionBountyReserves(orderId);
        }
    }

    function accountLiveReserveCount(
        bytes32 accountId
    ) external view returns (uint256 count) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (queuedAccountId != accountId || sizeDelta == 0) {
                continue;
            }
            if (router.executionBountyReserves(orderId) > 0 || router.committedMargins(orderId) > 0) {
                count++;
            }
        }
    }

    function liquidationSnapshot(
        bytes32 accountId
    ) external view returns (PerpGhostLedger.LiquidationSnapshot memory) {
        return ghost.liquidationSnapshot(accountId);
    }

    function committedMarginSnapshot(
        bytes32 accountId
    ) external view returns (uint256) {
        return ghost.committedMarginSnapshot(accountId);
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return ghost.totalCommittedMarginSnapshot();
    }

    function deferredClearerBountySnapshot() external view returns (uint256) {
        return ghost.deferredClearerBountySnapshot(address(this));
    }

    function deferredTraderPayoutSnapshot(
        bytes32 accountId
    ) external view returns (uint256) {
        return ghost.deferredTraderPayoutSnapshot(accountId);
    }

    function totalDeferredTraderPayoutSnapshot() external view returns (uint256) {
        return ghost.totalDeferredTraderPayoutSnapshot();
    }

    function ghostOrderLifecycleState(
        uint64 orderId
    ) external view returns (uint8) {
        return ghostOrderState[orderId];
    }

    function ghostOrderRemainingCommittedMargin(
        uint64 orderId
    ) external view returns (uint256) {
        return ghostOrderCommittedMargin[orderId];
    }

    function reservationRemainingCommittedMargin(
        uint64 orderId
    ) external view returns (uint256) {
        return clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
    }

    function reservationOriginalAmount(
        uint64 orderId
    ) external view returns (uint256) {
        return ghostReservationOriginal[orderId];
    }

    function reservationConsumedAmount(
        uint64 orderId
    ) external view returns (uint256) {
        return ghostReservationConsumed[orderId];
    }

    function reservationReleasedAmount(
        uint64 orderId
    ) external view returns (uint256) {
        return ghostReservationReleased[orderId];
    }

    function reservationStatus(
        uint64 orderId
    ) external view returns (uint8) {
        return uint8(clearinghouse.getOrderReservation(orderId).status);
    }

    function reservationAccount(
        uint64 orderId
    ) external view returns (bytes32) {
        return clearinghouse.getOrderReservation(orderId).accountId;
    }

    function accountActiveReservationCommittedMargin(
        bytes32 accountId
    ) external view returns (uint256) {
        return clearinghouse.getAccountReservationSummary(accountId).activeCommittedOrderMarginUsdc;
    }

    function accountReservationRemainingSum(
        bytes32 accountId
    ) external view returns (uint256 totalRemainingUsdc) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
            if (
                reservation.accountId == accountId
                    && reservation.status == IMarginClearinghouse.ReservationStatus.Active
            ) {
                totalRemainingUsdc += reservation.remainingAmountUsdc;
            }
        }
    }

    function activeCommittedReservationCount(
        bytes32 accountId
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
            if (
                reservation.accountId == accountId
                    && reservation.status == IMarginClearinghouse.ReservationStatus.Active
                    && reservation.bucket == IMarginClearinghouse.ReservationBucket.CommittedOrder
            ) {
                count++;
            }
        }
    }

    function lastKnownOrderId() external view returns (uint64) {
        return router.nextCommitId() > 0 ? router.nextCommitId() - 1 : 0;
    }

    function reachabilityTransition(
        bytes32 accountId
    ) external view returns (ReachabilityTransition memory) {
        return reachabilityTransitions[accountId];
    }

    function lastTerminalReservationInfo()
        external
        view
        returns (
            bytes32 accountId,
            uint256 count,
            uint256 activeCountBefore,
            uint64[5] memory ids,
            uint256[5] memory remainingBefore
        )
    {
        return (
            lastTerminalReservationAccountId,
            lastTerminalReservationCount,
            lastTerminalActiveReservationCountBefore,
            lastTerminalReservationIds,
            lastTerminalReservationRemainingBefore
        );
    }

    function ghostPendingOrderCount(
        bytes32 accountId
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (ghostOrderOwner[orderId] == accountId && ghostOrderState[orderId] == GHOST_ORDER_PENDING) {
                count++;
            }
        }
    }

    function ghostPendingMarginOrderCount(
        bytes32 accountId
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (
                ghostOrderOwner[orderId] == accountId && ghostOrderState[orderId] == GHOST_ORDER_PENDING
                    && ghostOrderCommittedMargin[orderId] > 0
            ) {
                count++;
            }
        }
    }

    function totalDeferredClearerBountySnapshot() external view returns (uint256) {
        return ghost.totalDeferredClearerBountySnapshot();
    }

    function _ensureFreeSettlement(
        address actor,
        uint256 minFreeSettlementUsdc
    ) internal {
        bytes32 accountId = _accountId(actor);
        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        if (freeSettlement >= minFreeSettlementUsdc) {
            return;
        }

        _mintAndDepositTrader(actor, minFreeSettlementUsdc - freeSettlement);
    }

    function _mintAndDepositTrader(
        address actor,
        uint256 amount
    ) internal {
        bytes32 accountId = _accountId(actor);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();

        ghostTotalTraderMinted += amount;
    }

    function _registerPendingOrder(
        uint64 orderId,
        bytes32 accountId,
        uint256 committedMarginUsdc
    ) internal {
        ghostOrderOwner[orderId] = accountId;
        ghostOrderCommittedMargin[orderId] = committedMarginUsdc;
        ghostOrderState[orderId] = GHOST_ORDER_PENDING;
        if (committedMarginUsdc > 0) {
            ghostReservationOriginal[orderId] = committedMarginUsdc;
            ghost.increaseCommittedMargin(accountId, committedMarginUsdc);
        }
    }

    function _recordTerminalReservationSet(
        bytes32 accountId
    ) internal {
        uint64[] memory ids = router.getMarginReservationIds(accountId);
        lastTerminalReservationAccountId = accountId;
        lastTerminalReservationCount = ids.length;
        lastTerminalActiveReservationCountBefore = 0;
        for (uint256 i = 0; i < 5; i++) {
            lastTerminalReservationIds[i] = 0;
            lastTerminalReservationRemainingBefore[i] = 0;
        }
        for (uint256 i = 0; i < ids.length; i++) {
            lastTerminalReservationIds[i] = ids[i];
            lastTerminalReservationRemainingBefore[i] = clearinghouse.getOrderReservation(ids[i]).remainingAmountUsdc;
            if (lastTerminalReservationRemainingBefore[i] > 0) {
                lastTerminalActiveReservationCountBefore++;
            }
        }
    }

    function _clearTerminalReservationSet() internal {
        lastTerminalReservationAccountId = bytes32(0);
        lastTerminalReservationCount = 0;
        lastTerminalActiveReservationCountBefore = 0;
        for (uint256 i = 0; i < 5; i++) {
            lastTerminalReservationIds[i] = 0;
            lastTerminalReservationRemainingBefore[i] = 0;
        }
    }

    function _recordReachabilityTransition(
        bytes32 accountId,
        uint8 action,
        ICfdEngine.AccountLedgerSnapshot memory beforeSnapshot,
        ICfdEngine.AccountLedgerSnapshot memory afterSnapshot
    ) internal {
        reachabilityTransitions[accountId] = ReachabilityTransition({
            action: action,
            beforeCloseReachableUsdc: beforeSnapshot.closeReachableUsdc,
            afterCloseReachableUsdc: afterSnapshot.closeReachableUsdc,
            beforeLiquidationReachableUsdc: beforeSnapshot.liquidationReachableUsdc,
            afterLiquidationReachableUsdc: afterSnapshot.liquidationReachableUsdc
        });
    }

    function _finalizeGhostOrder(
        uint64 orderId,
        uint8 terminalState
    ) internal {
        bytes32 accountId = ghostOrderOwner[orderId];
        uint256 committedMarginUsdc = ghostOrderCommittedMargin[orderId];
        if (ghostOrderState[orderId] == GHOST_ORDER_NONE) {
            return;
        }

        if (committedMarginUsdc > 0) {
            ghost.decreaseCommittedMargin(accountId, committedMarginUsdc);
            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
            if (reservation.status == IMarginClearinghouse.ReservationStatus.Released) {
                ghostReservationReleased[orderId] += committedMarginUsdc;
            } else if (reservation.status == IMarginClearinghouse.ReservationStatus.Consumed) {
                ghostReservationConsumed[orderId] += committedMarginUsdc;
            }
        }

        ghostOrderCommittedMargin[orderId] = 0;
        ghostOrderState[orderId] = terminalState;
    }

    function _consumeCommittedMarginFromAccount(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        uint256 remainingToConsume = amountUsdc;
        for (uint64 orderId = 1; orderId < router.nextCommitId() && remainingToConsume > 0; orderId++) {
            if (ghostOrderOwner[orderId] != accountId || ghostOrderState[orderId] != GHOST_ORDER_PENDING) {
                continue;
            }

            uint256 ghostRemaining = ghostOrderCommittedMargin[orderId];
            if (ghostRemaining == 0) {
                continue;
            }

            uint256 consumed = ghostRemaining > remainingToConsume ? remainingToConsume : ghostRemaining;
            ghostOrderCommittedMargin[orderId] = ghostRemaining - consumed;
            ghost.decreaseCommittedMargin(accountId, consumed);
            ghostReservationConsumed[orderId] += consumed;
            remainingToConsume -= consumed;
        }

        assertEq(remainingToConsume, 0, "Committed margin consumption exceeded tracked pending margin");
    }

    function _reconcileCommittedMarginAfterProcessedOrders(
        uint256[4] memory committedBefore,
        uint64 startExecuteId,
        uint64 endExecuteId
    ) internal {
        uint256[4] memory releasedByProcessedOrders;
        if (endExecuteId > startExecuteId) {
            for (uint64 orderId = startExecuteId; orderId < endExecuteId; orderId++) {
                bytes32 accountId = ghostOrderOwner[orderId];
                if (accountId != bytes32(0)) {
                    releasedByProcessedOrders[_actorIndex(accountId)] += ghostOrderCommittedMargin[orderId];
                }

                uint8 terminalState = _ghostTerminalStateForOrder(orderId);
                _finalizeGhostOrder(orderId, terminalState);
            }
        }

        for (uint256 i = 0; i < actors.length; i++) {
            bytes32 accountId = _accountId(actors[i]);
            uint256 committedAfter = _trackedCommittedMargin(accountId);
            if (committedBefore[i] <= committedAfter) {
                continue;
            }

            uint256 observedReduction = committedBefore[i] - committedAfter;
            if (observedReduction > releasedByProcessedOrders[i]) {
                _consumeCommittedMarginFromAccount(accountId, observedReduction - releasedByProcessedOrders[i]);
            }
        }
    }

    function _reconcileCommittedMarginAfterLiquidation(
        bytes32 accountId,
        uint256 committedBefore
    ) internal {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (ghostOrderOwner[orderId] == accountId && ghostOrderState[orderId] == GHOST_ORDER_PENDING) {
                _finalizeGhostOrder(orderId, GHOST_ORDER_LIQUIDATED);
            }
        }

        uint256 committedAfter = _trackedCommittedMargin(accountId);
        if (committedBefore > committedAfter) {
            uint256 observedReduction = committedBefore - committedAfter;
            if (observedReduction > 0 && committedAfter > 0) {
                _consumeCommittedMarginFromAccount(accountId, observedReduction);
            }
        }
    }

    function _snapshotTrackedCommittedMargin() internal view returns (uint256[4] memory committedMarginByActor) {
        for (uint256 i = 0; i < actors.length; i++) {
            committedMarginByActor[i] = _trackedCommittedMargin(_accountId(actors[i]));
        }
    }

    function _trackedCommittedMargin(
        bytes32 accountId
    ) internal view returns (uint256) {
        return router.getAccountEscrow(accountId).committedMarginUsdc;
    }

    function _ghostTerminalStateForOrder(
        uint64 orderId
    ) internal view returns (uint8) {
        OrderRouter.OrderRecord memory record = router.getOrderRecord(orderId);
        if (record.status == OrderRouter.OrderStatus.Executed) {
            return GHOST_ORDER_EXECUTED;
        }
        return GHOST_ORDER_FAILED;
    }

    function _actorIndex(
        bytes32 accountId
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (_accountId(actors[i]) == accountId) {
                return i;
            }
        }
        revert("unknown actor");
    }

    function vaultAssetDepth() public view returns (uint256) {
        return vault.totalAssets();
    }

    function _freeSettlementUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
        uint256 protectedMargin = size > 0 ? margin : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        return buckets.freeSettlementUsdc;
    }

    function _firstPendingCloseOrderId(
        bytes32 accountId
    ) internal view returns (uint64 orderId) {
        for (orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,, bool isClose) = router.orders(orderId);
            if (queuedAccountId == accountId && sizeDelta > 0 && isClose) {
                return orderId;
            }
        }
        return 0;
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _isLiquidated(
        address actor
    ) internal view returns (bool) {
        return ghost.liquidationSnapshot(_accountId(actor)).liquidated;
    }

}
