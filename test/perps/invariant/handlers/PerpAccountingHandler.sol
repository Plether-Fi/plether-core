// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineLens} from "../../../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "../../../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../../../../src/perps/OrderRouterAdmin.sol";
import {AccountLensViewTypes} from "../../../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "../../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";
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
        uint256 beforeTerminalReachableUsdc;
        uint256 afterTerminalReachableUsdc;
    }

    struct BadDebtDeferredEvent {
        bool active;
        address account;
        uint256 badDebtAfterUsdc;
        uint256 allowedDeferredAfterUsdc;
    }

    struct TerminalResidualEvent {
        bool active;
        address account;
        uint256 badDebtBeforeUsdc;
        uint256 expectedBadDebtDeltaUsdc;
        uint256 expectedFinalResidualUsdc;
        uint256 traderWalletBeforeUsdc;
        bool walletPayoutExpected;
    }

    struct OpenCommitAttempt {
        bool active;
        address account;
        bool routerOpenAllowed;
        bool prefilterActive;
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory;
        uint8 revertCode;
        bool commitSucceeded;
    }

    struct WithdrawParityAttempt {
        bool active;
        address account;
        bool checkWithdrawPasses;
        bytes4 checkWithdrawSelector;
        bool withdrawPasses;
        bytes4 withdrawSelector;
    }

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    CfdEngineAccountLens public immutable engineAccountLens;
    CfdEngineLens public immutable engineLens;
    MarginClearinghouse public immutable clearinghouse;
    OrderRouter public immutable router;
    OrderRouterAdmin public immutable routerAdmin;
    MockInvariantVault public immutable vault;
    PerpGhostLedger public immutable ghost;

    address[4] internal actors;

    uint256 public ghostTotalTraderMinted;
    uint256 public ghostTotalVaultMinted;
    uint256 public ghostSuccessfulLiquidations;

    mapping(uint64 => address) internal ghostOrderOwner;
    mapping(uint64 => uint256) internal ghostOrderCommittedMargin;
    mapping(uint64 => uint8) internal ghostOrderState;
    mapping(uint64 => uint256) internal ghostReservationOriginal;
    mapping(uint64 => uint256) internal ghostReservationConsumed;
    mapping(uint64 => uint256) internal ghostReservationReleased;
    mapping(address => ReachabilityTransition) internal reachabilityTransitions;

    BadDebtDeferredEvent internal lastBadDebtDeferredEvent;
    TerminalResidualEvent internal lastTerminalResidualEvent;
    OpenCommitAttempt internal lastOpenCommitAttempt;
    WithdrawParityAttempt internal lastWithdrawParityAttempt;

    address internal lastTerminalReservationAccountId;
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
        engineAccountLens = new CfdEngineAccountLens(address(_engine));
        engineLens = new CfdEngineLens(address(_engine));
        clearinghouse = _clearinghouse;
        router = _router;
        routerAdmin = OrderRouterAdmin(_router.admin());
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
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        AccountLensViewTypes.AccountLedgerSnapshot memory beforeSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(_account(actor));
        uint256 amount = bound(amountFuzz, 1e6, 250_000e6);
        _mintAndDepositTrader(actor, amount);
        AccountLensViewTypes.AccountLedgerSnapshot memory afterSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(_account(actor));
        _recordReachabilityTransition(_account(actor), REACHABILITY_ACTION_DEPOSIT, beforeSnapshot, afterSnapshot);
    }

    function withdrawCollateral(
        uint256 actorIndex,
        uint256 amountFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        address account = _account(actor);
        uint256 freeSettlement = _freeSettlementUsdc(account);
        if (freeSettlement == 0) {
            return;
        }

        AccountLensViewTypes.AccountLedgerSnapshot memory beforeSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 amount = bound(amountFuzz, 1e6, freeSettlement);
        WithdrawParityAttempt memory attempt;
        attempt.active = true;
        attempt.account = account;
        vm.prank(address(clearinghouse));
        try engine.checkWithdraw(account) {
            attempt.checkWithdrawPasses = true;
        } catch (bytes memory err) {
            attempt.checkWithdrawSelector = _revertSelector(err);
        }

        vm.prank(actor);
        try clearinghouse.withdraw(account, amount) {
            attempt.withdrawPasses = true;
            AccountLensViewTypes.AccountLedgerSnapshot memory afterSnapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            _recordReachabilityTransition(account, REACHABILITY_ACTION_WITHDRAW, beforeSnapshot, afterSnapshot);
        } catch (bytes memory err) {
            attempt.withdrawSelector = _revertSelector(err);
        }
        lastWithdrawParityAttempt = attempt;
    }

    function commitOpenOrder(
        uint256 actorIndex,
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginDeltaFuzz,
        uint256 targetPriceFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
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
        address account = _account(actor);
        lastOpenCommitAttempt = OpenCommitAttempt({
            active: true,
            account: account,
            routerOpenAllowed: !routerAdmin.paused() && !engine.degradedMode() && !engine.isOracleFrozen()
                && !engine.isFadWindow() && vault.canIncreaseRisk() && router.pendingOrderCounts(account) < 5,
            prefilterActive: _canUseCommitMarkForOpenPrefilter(),
            failureCategory: engineLens.previewOpenFailurePolicyCategory(
                account, side, sizeDelta, marginDelta, _commitReferencePrice(), engine.lastMarkTime()
            ),
            revertCode: engineLens.previewOpenRevertCode(
                account, side, sizeDelta, marginDelta, _commitReferencePrice(), engine.lastMarkTime()
            ),
            commitSucceeded: false
        });

        vm.prank(actor);
        try router.commitOrder(side, sizeDelta, marginDelta, targetPrice, false) {
            lastOpenCommitAttempt.commitSucceeded = true;
            _registerPendingOrder(orderId, account, marginDelta);
        } catch {}
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 7 days));
    }

    function syncMarkNow(
        uint256 priceFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        uint256 price = bound(priceFuzz, 0.5e8, 1.5e8);
        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
    }

    function commitCloseOrder(
        uint256 actorIndex,
        uint256 targetPriceFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        address account = _account(actor);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        uint256 targetPrice = bound(targetPriceFuzz, 0.5e8, 1.5e8);
        uint64 orderId = router.nextCommitId();

        vm.prank(actor);
        try router.commitOrder(side, size, 0, targetPrice, true) {
            _registerPendingOrder(orderId, account, 0);
        } catch {}
    }

    function executeNextOrderBatch(
        uint256 batchSizeFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
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
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        uint64 orderId = router.nextExecuteId();
        if (orderId >= router.nextCommitId()) {
            return;
        }

        OrderRouter.OrderRecord memory orderRecord = _orderRecord(orderId);
        address account = orderRecord.core.account;
        uint256 sizeDelta = orderRecord.core.sizeDelta;
        uint256 marginDelta = orderRecord.core.marginDelta;
        uint256 targetPrice = orderRecord.core.targetPrice;
        bool isClose = orderRecord.core.isClose;
        uint256 deferredTraderCreditUsdc;
        uint256 allowedDeferredAfterUsdc;
        uint256 expectedBadDebtDeltaUsdc;
        uint256 expectedFinalResidualUsdc;
        bool terminalClose;
        AccountLensViewTypes.AccountLedgerSnapshot memory beforeSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 traderWalletBeforeUsdc = usdc.balanceOf(account);
        if (isClose && marginDelta == 0) {
            CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, sizeDelta, targetPrice);
            if (preview.valid) {
                deferredTraderCreditUsdc = preview.deferredTraderCreditUsdc;
                allowedDeferredAfterUsdc = preview.deferredTraderCreditUsdc > preview.existingDeferredRemainingUsdc
                    ? preview.deferredTraderCreditUsdc - preview.existingDeferredRemainingUsdc
                    : 0;
                if (preview.remainingSize == 0) {
                    terminalClose = true;
                    expectedBadDebtDeltaUsdc = preview.badDebtUsdc;
                    uint256 grossResidualUsdc = beforeSnapshot.settlementBalanceUsdc + preview.immediatePayoutUsdc
                        + preview.deferredTraderCreditUsdc;
                    expectedFinalResidualUsdc = grossResidualUsdc > preview.seizedCollateralUsdc
                        ? grossResidualUsdc - preview.seizedCollateralUsdc
                        : 0;
                }
            }
        }

        uint256[4] memory committedBefore = _snapshotTrackedCommittedMargin();
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory empty;
        try router.executeOrder(orderId, empty) {
            _reconcileCommittedMarginAfterProcessedOrders(committedBefore, orderId, router.nextExecuteId());
            if (deferredTraderCreditUsdc > 0) {
                ghost.increaseDeferredTraderCredit(account, deferredTraderCreditUsdc);
            }
            _syncGhostDeferredTraderCredit(account);
            uint256 badDebtAfter = engine.accumulatedBadDebtUsdc();
            if (isClose && badDebtAfter > badDebtBefore) {
                _recordBadDebtDeferredEvent(account, badDebtAfter, allowedDeferredAfterUsdc);
            }
            if (terminalClose) {
                _recordTerminalResidualEvent(
                    account,
                    badDebtBefore,
                    expectedBadDebtDeltaUsdc,
                    expectedFinalResidualUsdc,
                    traderWalletBeforeUsdc,
                    false
                );
            }
        } catch {}
    }

    function liquidate(
        uint256 actorIndex,
        uint256 priceFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        address account = _account(actor);
        (uint256 size,,,,,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        uint256 price = bound(priceFuzz, 0.3e8, 1.8e8);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, price);
        uint256 keeperBountyUsdc = preview.keeperBountyUsdc;
        bool shouldDefer = vault.failRouterPayouts() && keeperBountyUsdc > 0;
        uint256 deferredTraderCreditUsdc = preview.deferredTraderCreditUsdc;
        uint256 allowedDeferredAfterUsdc = preview.deferredTraderCreditUsdc > preview.existingDeferredRemainingUsdc
            ? preview.deferredTraderCreditUsdc - preview.existingDeferredRemainingUsdc
            : 0;
        uint256 traderWalletBeforeUsdc = usdc.balanceOf(actor);
        uint256 expectedFinalResidualUsdc =
            preview.settlementRetainedUsdc + preview.immediatePayoutUsdc + preview.deferredTraderCreditUsdc;
        uint256 committedBefore = _trackedCommittedMargin(account);
        _recordTerminalReservationSet(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        try router.executeLiquidation(account, priceData) {
            ghost.recordLiquidation(account, usdc.balanceOf(actor), engine.accumulatedBadDebtUsdc());
            ghostSuccessfulLiquidations++;
            _reconcileCommittedMarginAfterLiquidation(account, committedBefore);
            if (deferredTraderCreditUsdc > 0) {
                ghost.increaseDeferredTraderCredit(account, deferredTraderCreditUsdc);
            }
            _syncGhostDeferredTraderCredit(account);
            if (shouldDefer) {
                ghost.increaseDeferredKeeperCredit(address(this), keeperBountyUsdc);
            }
            uint256 badDebtAfter = engine.accumulatedBadDebtUsdc();
            if (badDebtAfter > badDebtBefore) {
                _recordBadDebtDeferredEvent(account, badDebtAfter, allowedDeferredAfterUsdc);
            }
            _recordTerminalResidualEvent(
                account, badDebtBefore, preview.badDebtUsdc, expectedFinalResidualUsdc, traderWalletBeforeUsdc, true
            );
        } catch {}
    }

    function claimDeferredKeeperCredit() external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        try engine.claimDeferredKeeperCredit() {
            _syncGhostDeferredKeeperCredit(address(this));
        } catch {}
    }

    function createDeferredTraderCredit(
        uint256 actorIndex
    ) external {
        _clearLastBadDebtDeferredEvent();
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        address account = _account(actor);
        if (router.pendingOrderCounts(account) != 0) {
            return;
        }

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            _ensureFreeSettlement(actor, 25_000e6);
            uint64 openOrderId = router.nextCommitId();
            vm.prank(actor);
            try router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 20_000e6, 0, false) {
                _registerPendingOrder(openOrderId, account, 20_000e6);
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

            (size,,,, side,,) = engine.positions(account);
            if (size == 0) {
                return;
            }
        }

        vault.setAssets(0);
        uint256 closeOraclePrice = side == CfdTypes.Side.BULL ? uint256(15e7) : uint256(5e7);

        CfdEngine.ClosePreview memory closePreview = engineLens.previewClose(account, size, closeOraclePrice);
        uint256 deferredTraderCreditUsdc = closePreview.deferredTraderCreditUsdc;
        _recordTerminalReservationSet(account);

        uint64 closeOrderId = router.nextCommitId();
        vm.prank(actor);
        try router.commitOrder(side, size, 0, 0, true) {
            _registerPendingOrder(closeOrderId, account, 0);
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
            if (deferredTraderCreditUsdc > 0) {
                ghost.increaseDeferredTraderCredit(account, deferredTraderCreditUsdc);
            }
            _syncGhostDeferredTraderCredit(account);
        } catch {}
    }

    function claimDeferredTraderCredit(
        uint256 actorIndex
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        address actor = actors[actorIndex % actors.length];
        address account = _account(actor);
        uint256 ghostDeferredTraderCredit = ghost.deferredTraderCreditSnapshot(account);

        vm.prank(actor);
        try engine.claimDeferredTraderCredit(account) {
            if (ghostDeferredTraderCredit > 0) {
                ghost.decreaseDeferredTraderCredit(account, ghostDeferredTraderCredit);
            }
            _syncGhostDeferredTraderCredit(account);
        } catch {}
    }

    function fundVault(
        uint256 amountFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        uint256 amount = bound(amountFuzz, 1000e6, 250_000e6);
        vault.seedAssets(amount);
        ghostTotalVaultMinted += amount;
    }

    function setRouterPayoutFailureMode(
        uint256 modeFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        vault.setFailRouterPayouts(modeFuzz % 2 == 1);
    }

    function setVaultAssets(
        uint256 amountFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        vault.setAssets(bound(amountFuzz, 0, 1_000_000_000e6));
    }

    function drainVault(
        uint256 floorFuzz
    ) external {
        _clearLastBadDebtDeferredEvent();
        _clearTerminalReservationSet();
        vault.setAssets(bound(floorFuzz, 0, 100e6));
    }

    function lastBadDebtDeferredEventSnapshot() external view returns (BadDebtDeferredEvent memory) {
        return lastBadDebtDeferredEvent;
    }

    function lastTerminalResidualEventSnapshot() external view returns (TerminalResidualEvent memory) {
        return lastTerminalResidualEvent;
    }

    function lastOpenCommitAttemptSnapshot() external view returns (OpenCommitAttempt memory) {
        return lastOpenCommitAttempt;
    }

    function lastWithdrawParityAttemptSnapshot() external view returns (WithdrawParityAttempt memory) {
        return lastWithdrawParityAttempt;
    }

    function accountRouterEscrow(
        address account
    ) public view returns (uint256 totalEscrowUsdc) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.account != account || record.core.sizeDelta == 0) {
                continue;
            }
            totalEscrowUsdc += record.executionBountyUsdc;
        }
    }

    function accountLiveReserveCount(
        address account
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.account != account || record.core.sizeDelta == 0) {
                continue;
            }
            if (record.executionBountyUsdc > 0 || _remainingCommittedMargin(orderId) > 0) {
                count++;
            }
        }
    }

    function liquidationSnapshot(
        address account
    ) external view returns (PerpGhostLedger.LiquidationSnapshot memory) {
        return ghost.liquidationSnapshot(account);
    }

    function committedMarginSnapshot(
        address account
    ) external view returns (uint256) {
        return ghost.committedMarginSnapshot(account);
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return ghost.totalCommittedMarginSnapshot();
    }

    function deferredKeeperCreditSnapshot() external view returns (uint256) {
        return ghost.deferredKeeperCreditSnapshot(address(this));
    }

    function deferredTraderCreditSnapshot(
        address account
    ) external view returns (uint256) {
        return ghost.deferredTraderCreditSnapshot(account);
    }

    function _clearLastBadDebtDeferredEvent() internal {
        delete lastBadDebtDeferredEvent;
        delete lastTerminalResidualEvent;
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 selector) {
        if (err.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(err, 32))
        }
    }

    function _commitReferencePrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }

        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _canUseCommitMarkForOpenPrefilter() internal view returns (bool) {
        uint64 lastMarkTime = engine.lastMarkTime();
        if (lastMarkTime == 0) {
            return false;
        }

        uint256 age = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        uint256 maxStaleness = engine.isOracleFrozen() || engine.isFadWindow()
            ? router.liquidationStalenessLimit() > engine.fadMaxStaleness()
                ? router.liquidationStalenessLimit()
                : engine.fadMaxStaleness()
            : router.orderExecutionStalenessLimit();
        return age <= maxStaleness;
    }

    function _recordBadDebtDeferredEvent(
        address account,
        uint256 badDebtAfterUsdc,
        uint256 allowedDeferredAfterUsdc
    ) internal {
        lastBadDebtDeferredEvent = BadDebtDeferredEvent({
            active: true,
            account: account,
            badDebtAfterUsdc: badDebtAfterUsdc,
            allowedDeferredAfterUsdc: allowedDeferredAfterUsdc
        });
    }

    function _recordTerminalResidualEvent(
        address account,
        uint256 badDebtBeforeUsdc,
        uint256 expectedBadDebtDeltaUsdc,
        uint256 expectedFinalResidualUsdc,
        uint256 traderWalletBeforeUsdc,
        bool walletPayoutExpected
    ) internal {
        lastTerminalResidualEvent = TerminalResidualEvent({
            active: true,
            account: account,
            badDebtBeforeUsdc: badDebtBeforeUsdc,
            expectedBadDebtDeltaUsdc: expectedBadDebtDeltaUsdc,
            expectedFinalResidualUsdc: expectedFinalResidualUsdc,
            traderWalletBeforeUsdc: traderWalletBeforeUsdc,
            walletPayoutExpected: walletPayoutExpected
        });
    }

    function _syncGhostDeferredTraderCredit(
        address account
    ) internal {
        uint256 ghostDeferredTraderCredit = ghost.deferredTraderCreditSnapshot(account);
        uint256 liveDeferredTraderCredit = engine.deferredTraderCreditUsdc(account);
        if (liveDeferredTraderCredit > ghostDeferredTraderCredit) {
            ghost.increaseDeferredTraderCredit(account, liveDeferredTraderCredit - ghostDeferredTraderCredit);
        } else if (ghostDeferredTraderCredit > liveDeferredTraderCredit) {
            ghost.decreaseDeferredTraderCredit(account, ghostDeferredTraderCredit - liveDeferredTraderCredit);
        }
    }

    function _syncGhostDeferredKeeperCredit(
        address keeper
    ) internal {
        uint256 ghostDeferredBounty = ghost.deferredKeeperCreditSnapshot(keeper);
        uint256 liveDeferredBounty = engine.deferredKeeperCreditUsdc(keeper);
        if (liveDeferredBounty > ghostDeferredBounty) {
            ghost.increaseDeferredKeeperCredit(keeper, liveDeferredBounty - ghostDeferredBounty);
        } else if (ghostDeferredBounty > liveDeferredBounty) {
            ghost.decreaseDeferredKeeperCredit(keeper, ghostDeferredBounty - liveDeferredBounty);
        }
    }

    function totalDeferredTraderCreditSnapshot() external view returns (uint256) {
        return ghost.totalDeferredTraderCreditSnapshot();
    }

    function ghostOrderLifecycleState(
        uint64 orderId
    ) external view returns (uint8) {
        uint8 storedState = ghostOrderState[orderId];
        if (storedState == GHOST_ORDER_NONE) {
            return GHOST_ORDER_NONE;
        }

        OrderRouter.OrderRecord memory record = _orderRecord(orderId);
        if (uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
            return GHOST_ORDER_PENDING;
        }

        return uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Executed)
            ? GHOST_ORDER_EXECUTED
            : GHOST_ORDER_FAILED;
    }

    function ghostOrderRemainingCommittedMargin(
        uint64 orderId
    ) external view returns (uint256) {
        OrderRouter.OrderRecord memory record = _orderRecord(orderId);
        if (uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
            return _remainingCommittedMargin(orderId);
        }
        return 0;
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
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        uint256 original = ghostReservationOriginal[orderId];
        uint256 terminalizedOrConsumed =
            original > reservation.remainingAmountUsdc ? original - reservation.remainingAmountUsdc : 0;
        if (reservation.status == IMarginClearinghouse.ReservationStatus.Active) {
            return terminalizedOrConsumed;
        }

        uint256 released = ghostReservationReleased[orderId];
        if (reservation.status == IMarginClearinghouse.ReservationStatus.Consumed && terminalizedOrConsumed > released)
        {
            return terminalizedOrConsumed - released;
        }

        uint256 consumed = ghostReservationConsumed[orderId];
        return consumed > terminalizedOrConsumed ? terminalizedOrConsumed : consumed;
    }

    function reservationReleasedAmount(
        uint64 orderId
    ) external view returns (uint256) {
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        uint256 original = ghostReservationOriginal[orderId];
        uint256 terminalizedOrConsumed =
            original > reservation.remainingAmountUsdc ? original - reservation.remainingAmountUsdc : 0;
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Released) {
            return 0;
        }

        uint256 consumed = ghostReservationConsumed[orderId];
        if (terminalizedOrConsumed > consumed) {
            return terminalizedOrConsumed - consumed;
        }
        return 0;
    }

    function reservationStatus(
        uint64 orderId
    ) external view returns (uint8) {
        return uint8(clearinghouse.getOrderReservation(orderId).status);
    }

    function reservationAccount(
        uint64 orderId
    ) external view returns (address) {
        return clearinghouse.getOrderReservation(orderId).account;
    }

    function accountActiveReservationCommittedMargin(
        address account
    ) external view returns (uint256) {
        return clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginUsdc;
    }

    function accountReservationRemainingSum(
        address account
    ) external view returns (uint256 totalRemainingUsdc) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
            if (reservation.account == account && reservation.status == IMarginClearinghouse.ReservationStatus.Active) {
                totalRemainingUsdc += reservation.remainingAmountUsdc;
            }
        }
    }

    function activeCommittedReservationCount(
        address account
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
            if (
                reservation.account == account && reservation.status == IMarginClearinghouse.ReservationStatus.Active
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
        address account
    ) external view returns (ReachabilityTransition memory) {
        return reachabilityTransitions[account];
    }

    function lastTerminalReservationInfo()
        external
        view
        returns (
            address account,
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
        address account
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (
                ghostOrderOwner[orderId] == account
                    && uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)
            ) {
                count++;
            }
        }
    }

    function ghostPendingMarginOrderCount(
        address account
    ) external view returns (uint256 count) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (
                ghostOrderOwner[orderId] == account
                    && uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending) && record.inMarginQueue
                    && _remainingCommittedMargin(orderId) > 0
            ) {
                count++;
            }
        }
    }

    function totalDeferredKeeperCreditSnapshot() external view returns (uint256) {
        return ghost.totalDeferredKeeperCreditSnapshot();
    }

    function _ensureFreeSettlement(
        address actor,
        uint256 minFreeSettlementUsdc
    ) internal {
        address account = _account(actor);
        uint256 freeSettlement = _freeSettlementUsdc(account);
        if (freeSettlement >= minFreeSettlementUsdc) {
            return;
        }

        _mintAndDepositTrader(actor, minFreeSettlementUsdc - freeSettlement);
    }

    function _mintAndDepositTrader(
        address actor,
        uint256 amount
    ) internal {
        address account = _account(actor);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();

        ghostTotalTraderMinted += amount;
    }

    function _registerPendingOrder(
        uint64 orderId,
        address account,
        uint256 committedMarginUsdc
    ) internal {
        ghostOrderOwner[orderId] = account;
        ghostOrderCommittedMargin[orderId] = committedMarginUsdc;
        ghostOrderState[orderId] = GHOST_ORDER_PENDING;
        if (committedMarginUsdc > 0) {
            ghostReservationOriginal[orderId] = committedMarginUsdc;
            ghost.increaseCommittedMargin(account, committedMarginUsdc);
        }
    }

    function _recordTerminalReservationSet(
        address account
    ) internal {
        uint64[] memory ids = router.getMarginReservationIds(account);
        lastTerminalReservationAccountId = account;
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
        lastTerminalReservationAccountId = address(0);
        lastTerminalReservationCount = 0;
        lastTerminalActiveReservationCountBefore = 0;
        for (uint256 i = 0; i < 5; i++) {
            lastTerminalReservationIds[i] = 0;
            lastTerminalReservationRemainingBefore[i] = 0;
        }
    }

    function _recordReachabilityTransition(
        address account,
        uint8 action,
        AccountLensViewTypes.AccountLedgerSnapshot memory beforeSnapshot,
        AccountLensViewTypes.AccountLedgerSnapshot memory afterSnapshot
    ) internal {
        reachabilityTransitions[account] = ReachabilityTransition({
            action: action,
            beforeCloseReachableUsdc: beforeSnapshot.closeReachableUsdc,
            afterCloseReachableUsdc: afterSnapshot.closeReachableUsdc,
            beforeTerminalReachableUsdc: beforeSnapshot.terminalReachableUsdc,
            afterTerminalReachableUsdc: afterSnapshot.terminalReachableUsdc
        });
    }

    function _finalizeGhostOrder(
        uint64 orderId,
        uint8 terminalState
    ) internal {
        address account = ghostOrderOwner[orderId];
        uint256 committedMarginUsdc = ghostOrderCommittedMargin[orderId];
        if (ghostOrderState[orderId] == GHOST_ORDER_NONE) {
            return;
        }

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        if (committedMarginUsdc > 0) {
            ghost.decreaseCommittedMargin(account, committedMarginUsdc);
        }

        uint256 terminalizedAmount = ghostReservationOriginal[orderId] - ghostReservationConsumed[orderId]
            - ghostReservationReleased[orderId] - reservation.remainingAmountUsdc;
        if (terminalizedAmount > 0) {
            if (reservation.status == IMarginClearinghouse.ReservationStatus.Released) {
                ghostReservationReleased[orderId] += terminalizedAmount;
            } else if (reservation.status == IMarginClearinghouse.ReservationStatus.Consumed) {
                ghostReservationConsumed[orderId] += terminalizedAmount;
            }
        }

        ghostOrderCommittedMargin[orderId] = 0;
        ghostOrderState[orderId] = terminalState;
    }

    function _consumeCommittedMarginFromAccount(
        address account,
        uint256 amountUsdc
    ) internal {
        uint256 remainingToConsume = amountUsdc;
        for (uint64 orderId = 1; orderId < router.nextCommitId() && remainingToConsume > 0; orderId++) {
            if (ghostOrderOwner[orderId] != account || ghostOrderState[orderId] != GHOST_ORDER_PENDING) {
                continue;
            }

            uint256 ghostRemaining = ghostOrderCommittedMargin[orderId];
            if (ghostRemaining == 0) {
                continue;
            }

            uint256 consumed = ghostRemaining > remainingToConsume ? remainingToConsume : ghostRemaining;
            ghostOrderCommittedMargin[orderId] = ghostRemaining - consumed;
            ghost.decreaseCommittedMargin(account, consumed);
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
        uint64 upperBound = endExecuteId == 0 ? router.nextCommitId() : endExecuteId;
        if (upperBound > startExecuteId) {
            for (uint64 orderId = startExecuteId; orderId < upperBound; orderId++) {
                OrderRouter.OrderRecord memory record = _orderRecord(orderId);
                if (uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
                    continue;
                }

                address account = ghostOrderOwner[orderId];
                if (account != address(0)) {
                    releasedByProcessedOrders[_actorIndex(account)] += ghostOrderCommittedMargin[orderId];
                }

                uint8 terminalState = _ghostTerminalStateForOrder(orderId);
                _finalizeGhostOrder(orderId, terminalState);
            }
        }

        for (uint256 i = 0; i < actors.length; i++) {
            address account = _account(actors[i]);
            uint256 committedAfter = _trackedCommittedMargin(account);
            if (committedBefore[i] <= committedAfter) {
                continue;
            }

            uint256 observedReduction = committedBefore[i] - committedAfter;
            if (observedReduction > releasedByProcessedOrders[i]) {
                _consumeCommittedMarginFromAccount(account, observedReduction - releasedByProcessedOrders[i]);
            }
        }
    }

    function _reconcileCommittedMarginAfterLiquidation(
        address account,
        uint256 committedBefore
    ) internal {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (ghostOrderOwner[orderId] == account && ghostOrderState[orderId] == GHOST_ORDER_PENDING) {
                _finalizeGhostOrder(orderId, GHOST_ORDER_LIQUIDATED);
            }
        }

        uint256 committedAfter = _trackedCommittedMargin(account);
        if (committedBefore > committedAfter) {
            uint256 observedReduction = committedBefore - committedAfter;
            if (observedReduction > 0 && committedAfter > 0) {
                _consumeCommittedMarginFromAccount(account, observedReduction);
            }
        }
    }

    function _snapshotTrackedCommittedMargin() internal view returns (uint256[4] memory committedMarginByActor) {
        for (uint256 i = 0; i < actors.length; i++) {
            committedMarginByActor[i] = _trackedCommittedMargin(_account(actors[i]));
        }
    }

    function _trackedCommittedMargin(
        address account
    ) internal view returns (uint256) {
        return router.getAccountEscrow(account).committedMarginUsdc;
    }

    function _ghostTerminalStateForOrder(
        uint64 orderId
    ) internal view returns (uint8) {
        OrderRouter.OrderRecord memory record = _orderRecord(orderId);
        if (uint8(record.status) == uint8(IOrderRouterAccounting.OrderStatus.Executed)) {
            return GHOST_ORDER_EXECUTED;
        }
        return GHOST_ORDER_FAILED;
    }

    function _actorIndex(
        address account
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (_account(actors[i]) == account) {
                return i;
            }
        }
        revert("unknown actor");
    }

    function vaultAssetDepth() public view returns (uint256) {
        return vault.totalAssets();
    }

    function _freeSettlementUsdc(
        address account
    ) internal view returns (uint256) {
        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        uint256 protectedMargin = size > 0 ? margin : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        return buckets.freeSettlementUsdc;
    }

    function _firstPendingCloseOrderId(
        address account
    ) internal view returns (uint64 orderId) {
        for (orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.account == account && record.core.sizeDelta > 0 && record.core.isClose) {
                return orderId;
            }
        }
        return 0;
    }

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
        return OrderRouterDebugLens.loadOrderRecord(vm, router, orderId);
    }

    function _remainingCommittedMargin(
        uint64 orderId
    ) internal view returns (uint256) {
        return clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

    function _isLiquidated(
        address actor
    ) internal view returns (bool) {
        return ghost.liquidationSnapshot(_account(actor)).liquidated;
    }

}
