// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";

/// @dev Engine read surface used by account-action methods externalized from the bytecode-constrained host.
interface ICfdEngineAccountActionView {

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostUsdcAtoms(
        address account
    ) external view returns (uint256);

    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    function sides(
        uint256 index
    ) external view returns (uint256 maxProfitUsdc, uint256 openInterest, uint256 entryNotional, uint256 totalMargin);

    function sideBorrowBaseUsdc(
        uint256 index
    ) external view returns (uint256);

    function sideCarryIndex(
        uint256 index
    ) external view returns (uint256);

    function sideCarryTimestamp(
        uint256 index
    ) external view returns (uint64);

    function planner() external view returns (address);

    function orderRouter() external view returns (address);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function CAP_PRICE() external view returns (uint256);

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

    function unsettledCarryUsdc(
        address account
    ) external view returns (uint256);

    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    function degradedMode() external view returns (bool);

    function isFadWindow() external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function engineMarkStalenessLimit() external view returns (uint256);

    function fadMaxStaleness() external view returns (uint256);

    function executionFeeBps() external view returns (uint256);

    function frozenCloseSpreadBps() external view returns (uint256);

    function riskParams()
        external
        view
        returns (
            uint256 vpiFactor,
            uint256 maxSkewRatio,
            uint256 maintMarginBps,
            uint256 initMarginBps,
            uint256 fadMarginBps,
            uint256 baseCarryBps,
            uint256 minBountyUsdc,
            uint256 bountyBps,
            uint256 keeperShareBps,
            uint256 protocolShareBps
        );

}

/// @title CfdEngineSettlementSidecar
/// @notice Externalized settlement executor for `CfdEngine` open, close, and liquidation flows.
/// @dev `CfdEngine` remains the storage owner and grants this sidecar access only through narrow
///      settlement-host hooks. The sidecar does not own independent protocol state and does not validate planner deltas;
///      the bound engine must supply a valid delta derived from matching live state. Unless stated otherwise, USDC
///      amounts use 6 decimals, prices use 8 decimals, sizes use 18 decimals, and timestamps are Unix seconds.
contract CfdEngineSettlementSidecar is ICfdEngineSettlementSidecar {

    /// @notice Sole engine address authorized to call settlement entrypoints.
    address public immutable ENGINE;

    /// @notice Thrown when the caller is not exactly `ENGINE`.
    error CfdEngineSettlementSidecar__Unauthorized();
    /// @notice Live isolated-bucket settlement diverged from the planner's exact mutation.
    error CfdEngineSettlementSidecar__SettlementMismatch();

    /// @notice Binds the stateless sidecar to one engine settlement host.
    /// @dev Performs no zero-address, code-size, or interface validation. Binding to an invalid address can deploy but
    ///      leaves settlement unusable or causes later host calls to revert.
    /// @param engine_ Engine host authorized to call this sidecar.
    constructor(
        address engine_
    ) {
        ENGINE = engine_;
    }

    /// @notice Restricts every sidecar entrypoint to its immutable Engine host.
    modifier onlyEngine() {
        if (msg.sender != ENGINE) {
            revert CfdEngineSettlementSidecar__Unauthorized();
        }
        _;
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function buildRawSnapshot(
        address account,
        uint256 poolDepthUsdc
    ) external view onlyEngine returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(ENGINE);
        (
            snap.position.size,
            snap.position.margin,
            snap.position.entryPrice,
            snap.position.maxProfitUsdc,
            snap.position.side,
            snap.position.lastUpdateTime,
            snap.position.vpiAccrued
        ) = engine.positions(account);
        snap.positionEntryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);
        (snap.positionBorrowBaseUsdc, snap.positionLastCarryIndex, snap.position.lastCarryTimestamp) =
            engine.positionCarryState(account);
        snap.account = account;
        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = engine.lastMarkPrice();
        snap.lastMarkTime = engine.lastMarkTime();
        (
            snap.riskParams.vpiFactor,
            snap.riskParams.maxSkewRatio,
            snap.riskParams.maintMarginBps,
            snap.riskParams.initMarginBps,
            snap.riskParams.fadMarginBps,
            snap.riskParams.baseCarryBps,
            snap.riskParams.minBountyUsdc,
            snap.riskParams.bountyBps,
            snap.riskParams.keeperShareBps,
            snap.riskParams.protocolShareBps
        ) = engine.riskParams();

        snap.bullSide = _sideSnapshot(engine, CfdTypes.Side.BULL, poolDepthUsdc, snap.riskParams.baseCarryBps);
        snap.bearSide = _sideSnapshot(engine, CfdTypes.Side.BEAR, poolDepthUsdc, snap.riskParams.baseCarryBps);
        snap.poolAssetsUsdc = poolDepthUsdc;
        snap.poolCashUsdc = IHousePool(host.pool()).totalAssets();

        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.liquidationReserveUsdc = clearinghouse.liquidationReserveUsdc(account);
        snap.actionReserveUsdc = clearinghouse.actionReserveUsdc(account);
        snap.vpiRebateReserveUsdc = clearinghouse.vpiRebateReserveUsdc(account);
        address orderRouter = engine.orderRouter();
        if (orderRouter != address(0)) {
            snap.protectedExecutionBountyUsdc =
            IOrderRouterAccounting(orderRouter).getAccountReservations(account).executionBountyUsdc;
        }
        snap.position.margin = snap.lockedBuckets.positionMarginUsdc;

        snap.unsettledCarryUsdc = engine.unsettledCarryUsdc(account);
        snap.totalTraderClaimBalanceUsdc = engine.totalTraderClaimBalanceUsdc();
        snap.traderClaimBalanceForAccount = engine.traderClaimBalanceUsdc(account);
        snap.degradedMode = engine.degradedMode();
        snap.capPrice = engine.CAP_PRICE();
        snap.executionFeeBps = engine.executionFeeBps();
        snap.isFadWindow = engine.isFadWindow();
        snap.oracleFrozen = engine.isOracleFrozen();
        snap.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
    }

    function _sideSnapshot(
        ICfdEngineAccountActionView engine,
        CfdTypes.Side side,
        uint256 poolDepthUsdc,
        uint256 baseCarryBps
    ) private view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        uint256 index = uint256(side);
        (snap.maxProfitUsdc, snap.openInterest, snap.entryNotional, snap.totalMargin) = engine.sides(index);
        snap.borrowBaseUsdc = engine.sideBorrowBaseUsdc(index);
        snap.carryIndex = ICfdEnginePlanner(engine.planner())
            .computeCurrentCarryIndex(
                engine.sideCarryIndex(index),
                engine.sideCarryTimestamp(index),
                block.timestamp,
                snap.borrowBaseUsdc,
                poolDepthUsdc,
                baseCarryBps
            );
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function validateWithdraw(
        address account
    ) external onlyEngine {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(ENGINE);
        CfdTypes.Position memory pos = _loadPosition(engine, account);
        if (pos.size == 0) {
            return;
        }
        if (engine.degradedMode()) {
            revert ICfdEngineTypes.CfdEngine__DegradedMode();
        }

        (bool priceFresh, uint256 price) = _liveMark(engine, host);
        if (!priceFresh) {
            revert ICfdEngineTypes.CfdEngine__MarkPriceStale();
        }

        host.settlementRealizeCarry(account);
        pos = _loadPosition(engine, account);
        if (engine.unsettledCarryUsdc(account) != 0) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        if (clearinghouse.vpiRebateReserveUsdc(account) < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
        uint256 reachableUsdc = clearinghouse.pnlPledgeUsdc(account) + engine.traderClaimBalanceUsdc(account);
        (,, uint256 maintMarginBps, uint256 initMarginBps, uint256 fadMarginBps,,,,,) = engine.riskParams();
        uint256 currentMarginBps = engine.isFadWindow() ? fadMarginBps : maintMarginBps;
        uint256 effectiveMarginBps = initMarginBps > currentMarginBps ? initMarginBps : currentMarginBps;
        bool liquidatable = ICfdEnginePlanner(engine.planner())
            .isExactPriceRiskLiquidatable(
                pos,
                engine.positionEntryCostUsdcAtoms(account),
                price,
                engine.CAP_PRICE(),
                reachableUsdc,
                effectiveMarginBps
            );
        if (liquidatable) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external onlyEngine {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        if (amountUsdc == 0) {
            return;
        }

        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(ENGINE);
        CfdTypes.Position memory pos = _loadPosition(engine, account);
        if (pos.size == 0 || sizeDelta == 0 || sizeDelta > pos.size || sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        bool isFullClose = sizeDelta == pos.size;
        (bool priceFresh, uint256 price) = _liveMark(engine, host);
        if (price == 0) {
            revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking();
        }
        OracleFreshnessPolicyLib.Policy memory closePolicy =
            _markPolicy(engine, host, OracleFreshnessPolicyLib.Mode.CloseCommitFallback);
        if (closePolicy.requireStoredMark && engine.lastMarkTime() == 0) {
            revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        host.settlementRealizeCarry(account);
        pos = _loadPosition(engine, account);
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        uint256 positionMarginUsdc = clearinghouse.pnlPledgeUsdc(account);
        if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < amountUsdc) {
            revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        if (!isFullClose) {
            pos.margin = positionMarginUsdc;
            (,, uint256 maintMarginBps,, uint256 fadMarginBps,,,,,) = engine.riskParams();
            uint256 requiredBps = engine.isFadWindow() ? fadMarginBps : maintMarginBps;
            bool liquidatable = ICfdEnginePlanner(engine.planner())
                .isExactPriceRiskLiquidatable(
                    pos,
                    engine.positionEntryCostUsdcAtoms(account),
                    price,
                    engine.CAP_PRICE(),
                    positionMarginUsdc + engine.traderClaimBalanceUsdc(account),
                    requiredBps
                );
            if (liquidatable) {
                revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking();
            }
        }

        if (priceFresh) {
            clearinghouse.reserveCloseExecutionBountyFromSettlement(account, amountUsdc);
        } else {
            clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(account, amountUsdc);
        }
    }

    function _loadPosition(
        ICfdEngineAccountActionView engine,
        address account
    ) private view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(account);
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedUsdc
    ) private pure returns (uint256 targetUsdc) {
        if (vpiAccruedUsdc < 0) {
            targetUsdc = uint256(-(vpiAccruedUsdc + 1)) + 1;
        }
    }

    function _liveMark(
        ICfdEngineAccountActionView engine,
        ICfdEngineSettlementHost host
    ) private view returns (bool fresh, uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            return (false, 0);
        }
        uint64 markTime = engine.lastMarkTime();
        uint256 age = block.timestamp > markTime ? block.timestamp - markTime : 0;
        fresh = age <= _markPolicy(engine, host, OracleFreshnessPolicyLib.Mode.PoolReconcile).maxStaleness;
    }

    function _markPolicy(
        ICfdEngineAccountActionView engine,
        ICfdEngineSettlementHost host,
        OracleFreshnessPolicyLib.Mode mode
    ) private view returns (OracleFreshnessPolicyLib.Policy memory policy) {
        return OracleFreshnessPolicyLib.getPolicy(
            mode,
            engine.isOracleFrozen(),
            engine.isFadWindow(),
            engine.engineMarkStalenessLimit(),
            host.pool() == address(0) ? 0 : IHousePool(host.pool()).markStalenessLimit(),
            0,
            0,
            engine.fadMaxStaleness()
        );
    }

    /// @notice Applies the live open/increase settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`. The host is responsible for supplying a valid
    ///      delta consistent with `currentPosition`; this function does not inspect `delta.valid` or recompute the plan.
    ///      It advances global carry/mark state when the publish time is newer, pays any negative VPI trade cost from
    ///      the pool, applies clearinghouse open costs and margin changes, and locks the gross negative lifetime-VPI
    ///      target in its dedicated action-reserve sub-ledger. It records collected LP revenue, updates aggregate side
    ///      margin/open interest/entry notional/max-profit state, funds collectible protocol fees from unreserved pool
    ///      cash, and writes the position with `block.timestamp` as its update/carry time. Existing-position carry is
    ///      realized by the engine before invoking the sidecar.
    /// @param delta Valid planned open/increase delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param currentPosition Position loaded by the engine immediately before settlement.
    /// @param publishTime Oracle publish timestamp proposed for the execution mark.
    function executeOpen(
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngine {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        CfdTypes.Side marginSide = currentPosition.size > 0 ? currentPosition.side : delta.posSide;
        uint256 marginBefore =
            IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.account).positionMarginUsdc;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());

        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveBeforeUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        if (delta.vpiRebateReserveBeforeUsdc > delta.vpiRebateReserveAfterUsdc) {
            clearinghouse.releaseVpiRebateReserve(
                delta.account, delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc
            );
        }

        if (delta.poolRebatePayoutUsdc > 0) {
            IHousePool(host.pool()).payOut(host.clearinghouse(), delta.poolRebatePayoutUsdc);
        }

        (int256 netMarginChange, uint256 protocolFeeCreditedUsdc) = clearinghouse.applyOpenCost(
            delta.account,
            delta.marginDeltaUsdc,
            delta.tradeCostUsdc,
            host.pool(),
            host.protocolTreasury(),
            delta.executionFeeUsdc
        );
        if (delta.tradeCostUsdc > 0) {
            uint256 poolCashInflowUsdc = uint256(delta.tradeCostUsdc) - protocolFeeCreditedUsdc;
            if (poolCashInflowUsdc > 0) {
                IHousePool(host.pool())
                    .recordClaimantInflow(
                        poolCashInflowUsdc,
                        IHousePool.ClaimantInflowKind.Revenue,
                        IHousePool.ClaimantInflowCashMode.CashArrived
                    );
            }
        }

        if (delta.vpiRebateReserveAfterUsdc > delta.vpiRebateReserveBeforeUsdc) {
            uint256 reserveIncreaseUsdc = delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveBeforeUsdc;
            uint256 reserveFromFreeUsdc = reserveIncreaseUsdc - delta.vpiRebateReserveFromPledgeUsdc;
            if (reserveFromFreeUsdc > 0) {
                clearinghouse.lockVpiRebateReserve(delta.account, reserveFromFreeUsdc);
            }
            if (delta.vpiRebateReserveFromPledgeUsdc > 0) {
                clearinghouse.reclassifyPnlPledgeToVpiRebateReserve(delta.account, delta.vpiRebateReserveFromPledgeUsdc);
            }
        }
        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveAfterUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }

        if (delta.liquidationReserveAfterUsdc > delta.liquidationReserveBeforeUsdc) {
            clearinghouse.reclassifyPnlPledgeToLiquidationReserve(
                delta.account, delta.liquidationReserveAfterUsdc - delta.liquidationReserveBeforeUsdc
            );
        }

        netMarginChange;
        uint256 marginAfterOpen = IMarginClearinghouse(host.clearinghouse()).pnlPledgeUsdc(delta.account);
        if (marginAfterOpen != delta.positionMarginAfterOpen) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementSyncTotalSideMargin(marginSide, marginBefore, marginAfterOpen);
        host.settlementApplySideDelta(
            delta.posSide,
            int256(delta.sideMaxProfitIncrease),
            int256(delta.sideOiIncrease),
            delta.sideEntryNotionalDelta
        );
        _settleProtocolFeeTopUp(host, delta.executionFeeUsdc, protocolFeeCreditedUsdc);
        host.settlementWritePosition(
            delta.account,
            CfdEngineSettlementTypes.PositionState({
                deletePosition: false,
                size: delta.newPosSize,
                entryCostUsdcAtoms: delta.newPosEntryCostUsdcAtoms,
                maxProfitUsdc: currentPosition.maxProfitUsdc + delta.posMaxProfitIncrease,
                lastUpdateTime: uint64(block.timestamp),
                lastCarryTimestamp: uint64(block.timestamp),
                vpiAccrued: currentPosition.vpiAccrued + delta.posVpiAccruedDelta,
                side: currentPosition.size == 0 ? delta.posSide : currentPosition.side
            })
        );
    }

    /// @notice Applies the live close/decrease settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`. The host must supply a valid delta consistent
    ///      with `currentPosition`; this function does not inspect `delta.valid` or recompute it. It advances carry/mark
    ///      state, updates aggregate side accounting, unlocks proportional margin, pays or records trader gains,
    ///      consumes eligible collateral and claims for collectible losses, and consumes or releases negative-VPI
    ///      reserve while preserving the residual target. It records LP revenue, funds collectible protocol fees from
    ///      unreserved pool cash, and writes or deletes the position. When a frozen spread was assessed it emits
    ///      `FrozenCloseSpreadSettled` with assessed, recovered, and waived USDC.
    /// @param delta Valid planned close/decrease delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param currentPosition Position loaded by the engine immediately before settlement.
    /// @param publishTime Oracle publish timestamp proposed for the execution mark.
    function executeClose(
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngine {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        uint256 marginBefore = clearinghouse.pnlPledgeUsdc(delta.account);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitReduction),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        if (delta.pricePnlClaimConsumedUsdc > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.pricePnlClaimConsumedUsdc);
        }
        if (delta.pricePnlPledgeConsumedUsdc > 0) {
            (uint256 consumedUsdc, uint256 shortfallUsdc) =
                clearinghouse.consumePnlPledgeLoss(delta.account, delta.pricePnlPledgeConsumedUsdc, host.pool());
            if (consumedUsdc != delta.pricePnlPledgeConsumedUsdc || shortfallUsdc != 0) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
        }

        uint256 protocolFeeCreditedUsdc;
        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveBeforeUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        if (delta.vpiRebateReserveConsumedUsdc > 0) {
            clearinghouse.consumeVpiRebateReserve(delta.account, host.pool(), delta.vpiRebateReserveConsumedUsdc);
        }
        uint256 vpiReserveReleaseUsdc =
            delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveConsumedUsdc;
        if (vpiReserveReleaseUsdc > 0) {
            clearinghouse.releaseVpiRebateReserve(delta.account, vpiReserveReleaseUsdc);
        }
        uint256 genericActionChargeToCollectUsdc = delta.actionChargeToCollectUsdc - delta.vpiRebateReserveConsumedUsdc;
        if (genericActionChargeToCollectUsdc > 0) {
            (uint256 collectedUsdc, uint256 creditedUsdc) = clearinghouse.consumeActionCharge(
                delta.account,
                genericActionChargeToCollectUsdc,
                delta.actionReserveConsumedUsdc,
                delta.actionCommittedMarginConsumedUsdc,
                host.pool(),
                host.protocolTreasury(),
                delta.actionProtocolFeeCreditedUsdc
            );
            if (
                collectedUsdc != delta.actionChargeCollectedUsdc - delta.vpiRebateReserveConsumedUsdc
                    || creditedUsdc != delta.actionProtocolFeeCreditedUsdc
            ) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
            protocolFeeCreditedUsdc = creditedUsdc;
        }
        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveAfterUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }

        uint256 cashArrivedRevenueUsdc =
            delta.pricePnlPledgeConsumedUsdc + delta.actionChargeCollectedUsdc - protocolFeeCreditedUsdc;
        if (cashArrivedRevenueUsdc > 0) {
            IHousePool(host.pool())
                .recordClaimantInflow(
                    cashArrivedRevenueUsdc,
                    IHousePool.ClaimantInflowKind.Revenue,
                    IHousePool.ClaimantInflowCashMode.CashArrived
                );
        }

        uint256 feeWithheldUsdc = delta.executionFeeUsdc - protocolFeeCreditedUsdc;
        _recordRetainedCloseRevenue(host, delta.actionChargeWithheldUsdc - feeWithheldUsdc);

        if (delta.unlockMarginUsdc > 0) {
            // Keep the collectible pledge required by the remaining terminal curve locked; only its excess is free.
            clearinghouse.unlockPositionMargin(delta.account, delta.unlockMarginUsdc);
        }
        if (delta.pricePayoutUsdc > 0) {
            host.settlementRecordTraderClaim(delta.account, delta.pricePayoutUsdc, !delta.deletePosition);
        }
        if (delta.actionRebatePaidUsdc > 0) {
            IHousePool(host.pool()).payOut(address(clearinghouse), delta.actionRebatePaidUsdc);
            clearinghouse.settleUsdc(delta.account, int256(delta.actionRebatePaidUsdc));
        }

        _settleProtocolFeeTopUp(host, protocolFeeCreditedUsdc + delta.protocolFeeTopUpUsdc, protocolFeeCreditedUsdc);

        uint256 marginAfter = clearinghouse.pnlPledgeUsdc(delta.account);
        if (marginAfter != delta.posMarginAfter) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementSyncTotalSideMargin(delta.side, marginBefore, marginAfter);

        if (delta.deletePosition) {
            host.settlementDeletePosition(delta.account);
        } else {
            host.settlementWritePosition(
                delta.account,
                CfdEngineSettlementTypes.PositionState({
                    deletePosition: false,
                    size: delta.closeState.remainingSize,
                    entryCostUsdcAtoms: delta.posEntryCostAfterUsdcAtoms,
                    maxProfitUsdc: currentPosition.maxProfitUsdc - delta.posMaxProfitReduction,
                    lastUpdateTime: uint64(block.timestamp),
                    lastCarryTimestamp: uint64(block.timestamp),
                    vpiAccrued: currentPosition.vpiAccrued - delta.posVpiAccruedReduction,
                    side: currentPosition.side
                })
            );
        }
        if (delta.liquidationReserveReleaseUsdc > 0) {
            clearinghouse.releaseLiquidationReserve(delta.account, delta.liquidationReserveReleaseUsdc);
        }

        if (delta.closeState.frozenSpreadUsdc > 0) {
            uint256 frozenSpreadPaidUsdc = _recoveredFrozenSpreadUsdc(delta);
            emit FrozenCloseSpreadSettled(
                delta.account,
                delta.closeState.frozenSpreadUsdc,
                frozenSpreadPaidUsdc,
                delta.closeState.frozenSpreadUsdc - frozenSpreadPaidUsdc
            );
        }
        if (delta.priceLossWrittenOffUsdc > 0) {
            emit PriceLossWrittenOff(delta.account, delta.priceLossWrittenOffUsdc);
        }
        if (delta.actionRebateUsdc > 0) {
            emit ActionRebateSettled(
                delta.account, delta.actionRebateUsdc, delta.actionRebatePaidUsdc, delta.actionRebateWaivedUsdc
            );
        }
        if (delta.actionChargeAssessedUsdc > 0) {
            emit ActionChargeSettled(
                delta.account,
                delta.actionChargeAssessedUsdc,
                delta.actionChargeWithheldUsdc + delta.actionChargeCollectedUsdc,
                delta.actionChargeWaivedUsdc
            );
        }
    }

    /// @notice Attributes recovered action charges to frozen spread after fee, carry, and positive VPI priority.
    function _recoveredFrozenSpreadUsdc(
        CfdEnginePlanTypes.CloseDelta calldata delta
    ) private pure returns (uint256 recoveredUsdc) {
        uint256 priorChargesUsdc = delta.closeState.executionFeeUsdc + delta.pendingCarryUsdc;
        if (delta.closeState.vpiDeltaUsdc > 0) {
            priorChargesUsdc += uint256(delta.closeState.vpiDeltaUsdc);
        }

        uint256 effectiveSpreadUsdc;
        if (delta.actionChargeAssessedUsdc > priorChargesUsdc) {
            effectiveSpreadUsdc = delta.actionChargeAssessedUsdc - priorChargesUsdc;
            if (effectiveSpreadUsdc > delta.closeState.frozenSpreadUsdc) {
                effectiveSpreadUsdc = delta.closeState.frozenSpreadUsdc;
            }
        }

        uint256 totalRecoveredUsdc = delta.actionChargeWithheldUsdc + delta.actionChargeCollectedUsdc;
        if (totalRecoveredUsdc > priorChargesUsdc) {
            recoveredUsdc = totalRecoveredUsdc - priorChargesUsdc;
            if (recoveredUsdc > effectiveSpreadUsdc) {
                recoveredUsdc = effectiveSpreadUsdc;
            }
        }
    }

    /// @notice Records nonzero LP revenue whose cash is already retained in pool accounting.
    /// @param host Bound engine settlement host.
    /// @param amountUsdc Revenue to record, in 6-decimal USDC units.
    function _recordRetainedCloseRevenue(
        ICfdEngineSettlementHost host,
        uint256 amountUsdc
    ) private {
        if (amountUsdc == 0) {
            return;
        }
        IHousePool(host.pool())
            .recordClaimantInflow(
                amountUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.AlreadyRetained
            );
    }

    /// @notice Applies the live liquidation settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`. The host must supply a liquidatable delta
    ///      consistent with live state; this function neither checks `delta.liquidatable` nor recomputes the plan. It
    ///      advances carry/mark state, removes all side exposure and margin, applies the clearinghouse terminal-settlement
    ///      plan, credits the configured keeper and protocol shares, transfers the LP remainder to the pool, records
    ///      seized pool inflow, synchronizes consumed order reservations, nets existing claims, settles the gross
    ///      negative lifetime-VPI clawback from its dedicated reserve or equivalent withheld gain, pays or records
    ///      fresh trader value, records applicable carry revenue, and deletes the position.
    /// @param delta Valid planned full-liquidation delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param publishTime Oracle publish timestamp proposed for the liquidation mark.
    /// @param keeper Clearinghouse account credited with the planned bounty.
    /// @return keeperBountyUsdc Planned bounty forwarded to clearinghouse settlement, in 6-decimal USDC units.
    function executeLiquidation(
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external onlyEngine returns (uint256 keeperBountyUsdc) {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        uint256 marginBefore = clearinghouse.pnlPledgeUsdc(delta.account);
        if (marginBefore != delta.posMargin) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitDecrease),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        if (delta.pricePnlClaimConsumedUsdc > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.pricePnlClaimConsumedUsdc);
        }

        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveBeforeUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        if (delta.vpiRebateReserveConsumedUsdc > 0) {
            clearinghouse.consumeVpiRebateReserve(delta.account, host.pool(), delta.vpiRebateReserveConsumedUsdc);
        }
        uint256 vpiReserveReleaseUsdc =
            delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveConsumedUsdc;
        if (vpiReserveReleaseUsdc > 0) {
            clearinghouse.releaseVpiRebateReserve(delta.account, vpiReserveReleaseUsdc);
        }
        uint256 genericActionChargeToCollectUsdc = delta.actionChargeToCollectUsdc - delta.vpiRebateReserveConsumedUsdc;
        if (genericActionChargeToCollectUsdc > 0) {
            (uint256 collectedUsdc, uint256 protocolCreditedUsdc) = clearinghouse.consumeActionCharge(
                delta.account,
                genericActionChargeToCollectUsdc,
                delta.actionReserveConsumedUsdc,
                delta.actionCommittedMarginConsumedUsdc,
                host.pool(),
                address(0),
                0
            );
            if (
                collectedUsdc != delta.actionChargeCollectedUsdc - delta.vpiRebateReserveConsumedUsdc
                    || protocolCreditedUsdc != 0
            ) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
        }
        if (clearinghouse.vpiRebateReserveUsdc(delta.account) != delta.vpiRebateReserveAfterUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }

        keeperBountyUsdc = delta.keeperBountyUsdc;
        uint256 seizedUsdc = _applyLiquidationSettlementPlan(host, delta, keeper);
        if (seizedUsdc != delta.settlementSeizedUsdc) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        uint256 cashArrivedRevenueUsdc = seizedUsdc + delta.actionChargeCollectedUsdc;
        if (cashArrivedRevenueUsdc > 0) {
            IHousePool(host.pool())
                .recordClaimantInflow(
                    cashArrivedRevenueUsdc,
                    IHousePool.ClaimantInflowKind.Revenue,
                    IHousePool.ClaimantInflowCashMode.CashArrived
                );
        }
        _recordRetainedCloseRevenue(host, delta.actionChargeWithheldUsdc);

        if (delta.freshTraderPayoutUsdc > 0) {
            host.settlementRecordTraderClaim(delta.account, delta.freshTraderPayoutUsdc, false);
        }
        uint256 marginAfter = clearinghouse.pnlPledgeUsdc(delta.account);
        if (marginAfter != 0) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementSyncTotalSideMargin(delta.side, marginBefore, 0);
        host.settlementDeletePosition(delta.account);

        if (delta.priceLossWrittenOffUsdc > 0) {
            emit PriceLossWrittenOff(delta.account, delta.priceLossWrittenOffUsdc);
        }
        if (delta.actionChargeAssessedUsdc > 0) {
            emit ActionChargeSettled(
                delta.account,
                delta.actionChargeAssessedUsdc,
                delta.actionChargeWithheldUsdc + delta.actionChargeCollectedUsdc,
                delta.actionChargeWaivedUsdc
            );
        }
    }

    /// @notice Applies the clearinghouse mutation for a planned liquidation.
    /// @param host Bound engine settlement host.
    /// @param delta Valid planned full-liquidation delta.
    /// @param keeper Clearinghouse account credited with the planned bounty.
    /// @return seizedUsdc Amount transferred to the pool by the clearinghouse, in 6-decimal USDC units.
    function _applyLiquidationSettlementPlan(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        address keeper
    ) private returns (uint256 seizedUsdc) {
        uint64[] memory reservationOrderIds =
            IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.account);
        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan =
            IMarginClearinghouse.LiquidationSettlementPlan({
                settlementRetainedUsdc: delta.settlementRetainedUsdc,
                settlementSeizedUsdc: delta.settlementSeizedUsdc,
                freshTraderPayoutUsdc: delta.freshTraderPayoutUsdc,
                badDebtUsdc: delta.badDebtUsdc,
                positionMarginUnlockedUsdc: delta.residualPlan.mutation.positionMarginUnlockedUsdc,
                otherLockedMarginUnlockedUsdc: delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc
            });
        seizedUsdc = IMarginClearinghouse(host.clearinghouse())
            .applyLiquidationSettlementPlan(
                delta.account,
                reservationOrderIds,
                settlementPlan,
                host.pool(),
                keeper,
                delta.keeperBountyUsdc,
                host.protocolTreasury(),
                delta.protocolLiquidationFeeUsdc,
                delta.lpLiquidationFeeUsdc
            );
    }

    /// @notice Funds an uncredited protocol fee from pool cash not reserved for outstanding trader claims.
    /// @dev The top-up is capped by both the requested shortfall and current free pool cash, then paid to the clearinghouse
    ///      and credited to the host's protocol-treasury account.
    /// @param host Bound engine settlement host.
    /// @param amountUsdc Total protocol-fee amount intended to be credited.
    /// @param clearinghouseCreditedUsdc Portion already credited from clearinghouse cash collection.
    function _settleProtocolFeeTopUp(
        ICfdEngineSettlementHost host,
        uint256 amountUsdc,
        uint256 clearinghouseCreditedUsdc
    ) private {
        if (clearinghouseCreditedUsdc > amountUsdc) {
            clearinghouseCreditedUsdc = amountUsdc;
        }
        uint256 poolFundedUsdc = amountUsdc - clearinghouseCreditedUsdc;
        if (poolFundedUsdc == 0) {
            return;
        }

        IHousePool pool = IHousePool(host.pool());
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveFreshPayouts(pool.totalAssets(), host.totalTraderClaimBalanceUsdc());
        uint256 topUpUsdc = poolFundedUsdc < reservation.freeCashUsdc ? poolFundedUsdc : reservation.freeCashUsdc;
        if (topUpUsdc == 0) {
            return;
        }
        pool.payOut(host.clearinghouse(), topUpUsdc);
        IMarginClearinghouse(host.clearinghouse()).settleUsdc(host.protocolTreasury(), int256(topUpUsdc));
    }

}
