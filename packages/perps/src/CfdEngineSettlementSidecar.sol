// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanningReader} from "@plether/perps/CfdEnginePlanningReader.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineAccountActionView} from "@plether/perps/interfaces/ICfdEngineAccountActionView.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {OrderSettlementFloorLib} from "@plether/perps/libraries/OrderSettlementFloorLib.sol";

/// @title CfdEngineSettlementSidecar
/// @notice Externalized settlement executor for `CfdEngine` open, close, and liquidation flows.
/// @dev `CfdEngine` remains the storage owner and grants this sidecar access only through narrow
///      settlement-host hooks. The sidecar does not own independent protocol state and does not validate planner deltas;
///      the bound engine must supply a valid delta derived from matching live state. Unless stated otherwise, settlement token
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

    /// @notice Restricts settlement mutations to the immutable Engine host.
    modifier onlyEngine() {
        if (msg.sender != ENGINE) {
            revert CfdEngineSettlementSidecar__Unauthorized();
        }
        _;
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function buildRawSnapshot(
        address account,
        uint256 poolDepthAssets
    ) public view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        if (msg.sender != ENGINE && msg.sender != ICfdEngineAccountActionView(ENGINE).planningReader()) {
            revert CfdEngineSettlementSidecar__Unauthorized();
        }
        return _buildRawSnapshot(account, poolDepthAssets, false);
    }

    /// @dev Resolves the constructor-bound reader lazily so sidecar deployment has no host-call dependency.
    function _buildRawSnapshot(
        address account,
        uint256 poolDepthAssets,
        bool closeCommit
    ) private view returns (CfdEnginePlanTypes.RawSnapshot memory) {
        return CfdEnginePlanningReader(ICfdEngineAccountActionView(ENGINE).planningReader())
            .buildRawSnapshot(account, poolDepthAssets, closeCommit);
    }

    function _loadRiskParams(
        ICfdEngineAccountActionView engine
    ) private view returns (CfdTypes.RiskParams memory params) {
        params = ICfdEngineRiskParamsView(address(engine)).riskParams();
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function validateWithdraw(
        address account
    ) external onlyEngine {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(ENGINE);
        CfdTypes.Position memory pos = _loadPosition(engine, account);
        if (pos.size == 0) {
            (uint64 orderId, uint256 minimum, uint256 maxDebit) =
                OrderSettlementFloorLib.load(engine.orderRouter(), account);
            if (minimum != 0) {
                uint256 balance = IMarginClearinghouse(host.clearinghouse()).balanceAssets(account);
                if (balance < minimum || balance - minimum < maxDebit) {
                    revert IOrderRouterErrors.OrderRouter__SettlementFloorWithdrawal(
                        orderId, balance, minimum, maxDebit
                    );
                }
            }
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
        _requireWithdrawPositionHealthy(engine, host, account, price);
    }

    function _requireWithdrawPositionHealthy(
        ICfdEngineAccountActionView engine,
        ICfdEngineSettlementHost host,
        address account,
        uint256 price
    ) private view {
        CfdTypes.Position memory pos = _loadPosition(engine, account);
        if (engine.unsettledCarryAssets(account) != 0) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        if (clearinghouse.vpiRebateReserveAssets(account) < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
        uint256 reachableAssets = clearinghouse.pnlPledgeAssets(account) + engine.traderClaimBalanceAssets(account);
        if (_withdrawPositionLiquidatable(engine, pos, account, price, reachableAssets)) {
            revert ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    function _withdrawPositionLiquidatable(
        ICfdEngineAccountActionView engine,
        CfdTypes.Position memory pos,
        address account,
        uint256 price,
        uint256 reachableAssets
    ) private view returns (bool) {
        uint256 effectiveMarginBps = _withdrawEffectiveMarginBps(engine);
        return ICfdEnginePlanner(engine.planner())
            .isExactPriceRiskLiquidatable(
                pos,
                engine.positionEntryCostAssetAtoms(account),
                price,
                engine.CAP_PRICE(),
                reachableAssets,
                effectiveMarginBps
            );
    }

    function _withdrawEffectiveMarginBps(
        ICfdEngineAccountActionView engine
    ) private view returns (uint256) {
        CfdTypes.RiskParams memory params = _loadRiskParams(engine);
        uint256 currentMarginBps = engine.isFadWindow() ? params.fadMarginBps : params.maintMarginBps;
        return params.initMarginBps > currentMarginBps ? params.initMarginBps : currentMarginBps;
    }

    /// @inheritdoc ICfdEngineSettlementSidecar
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta
    ) external onlyEngine returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(ENGINE);
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, 0, true);
        effects = ICfdEnginePlanner(engine.planner()).planCloseCommit(snap, sizeDelta);
        host.settlementRealizeCarry(account);
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        IMarginClearinghouse.AccountAssetBuckets memory afterBuckets = clearinghouse.getAccountAssetBuckets(account);
        if (
            afterBuckets.settlementBalanceAssets != effects.settlementAfterAssets
                || afterBuckets.freeSettlementAssets != effects.freeSettlementAfterAssets
        ) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
    }

    function _loadPosition(
        ICfdEngineAccountActionView engine,
        address account
    ) private view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitAssets, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(account);
    }

    /// @dev Shared by open, close and liquidation settlement; each planned reserve is checked at its original boundary.
    function _requireVpiReserve(
        IMarginClearinghouse clearinghouse,
        address account,
        uint256 expectedAssets
    ) private view {
        if (clearinghouse.vpiRebateReserveAssets(account) != expectedAssets) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedAssets
    ) private pure returns (uint256 targetAssets) {
        if (vpiAccruedAssets < 0) {
            targetAssets = uint256(-(vpiAccruedAssets + 1)) + 1;
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
    /// @param delta Valid planned open/increase delta; prices are 8 decimals, size 18, and settlement token fields 6.
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
            IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.account).positionMarginAssets;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());

        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveBeforeAssets);
        if (delta.vpiRebateReserveBeforeAssets > delta.vpiRebateReserveAfterAssets) {
            clearinghouse.releaseVpiRebateReserve(
                delta.account, delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
            );
        }

        if (delta.poolRebatePayoutAssets > 0) {
            IHousePool(host.pool()).payOut(host.clearinghouse(), delta.poolRebatePayoutAssets);
        }

        (int256 netMarginChange, uint256 protocolFeeCreditedAssets) = clearinghouse.applyOpenCost(
            delta.account,
            delta.marginDeltaAssets,
            delta.tradeCostAssets,
            host.pool(),
            host.protocolTreasury(),
            delta.executionFeeAssets
        );
        if (delta.tradeCostAssets > 0) {
            uint256 poolCashInflowAssets = uint256(delta.tradeCostAssets) - protocolFeeCreditedAssets;
            uint256 deferredVpiAssets = delta.posVpiAccruedDelta > 0 ? uint256(delta.posVpiAccruedDelta) : 0;
            _recordCashInflow(host, poolCashInflowAssets, deferredVpiAssets);
        }

        if (delta.vpiRebateReserveAfterAssets > delta.vpiRebateReserveBeforeAssets) {
            uint256 reserveIncreaseAssets = delta.vpiRebateReserveAfterAssets - delta.vpiRebateReserveBeforeAssets;
            uint256 reserveFromFreeAssets = reserveIncreaseAssets - delta.vpiRebateReserveFromPledgeAssets;
            if (reserveFromFreeAssets > 0) {
                clearinghouse.lockVpiRebateReserve(delta.account, reserveFromFreeAssets);
            }
            if (delta.vpiRebateReserveFromPledgeAssets > 0) {
                clearinghouse.reclassifyPnlPledgeToVpiRebateReserve(
                    delta.account, delta.vpiRebateReserveFromPledgeAssets
                );
            }
        }
        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveAfterAssets);

        if (delta.liquidationReserveAfterAssets > delta.liquidationReserveBeforeAssets) {
            clearinghouse.reclassifyPnlPledgeToLiquidationReserve(
                delta.account, delta.liquidationReserveAfterAssets - delta.liquidationReserveBeforeAssets
            );
        }

        netMarginChange;
        uint256 marginAfterOpen = IMarginClearinghouse(host.clearinghouse()).pnlPledgeAssets(delta.account);
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
        _writeOpenPosition(host, delta, currentPosition);
        _settleProtocolFeeTopUp(host, delta.executionFeeAssets, protocolFeeCreditedAssets);
        _assertRequiredEffectiveAssets(host, delta.requiredEffectiveAssetsAfterAssets);
    }

    /// @dev Isolates position-write ABI encoding from the settlement frame for minimum-IR coverage compilation.
    function _writeOpenPosition(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition
    ) private {
        host.settlementWritePosition(
            delta.account,
            CfdEngineSettlementTypes.PositionState({
                size: delta.newPosSize,
                entryCostAssetAtoms: delta.newPosEntryCostAssetAtoms,
                maxProfitAssets: currentPosition.maxProfitAssets + delta.posMaxProfitIncrease,
                lastUpdateTime: uint64(block.timestamp),
                lastCarryTimestamp: uint64(block.timestamp),
                vpiAccrued: currentPosition.vpiAccrued + delta.posVpiAccruedDelta,
                side: currentPosition.size == 0 ? delta.posSide : currentPosition.side
            })
        );
    }

    /// @notice Verifies the planner's protected-solvency target against canonical post-open cash and claims.
    function _assertRequiredEffectiveAssets(
        ICfdEngineSettlementHost host,
        uint256 requiredEffectiveAssets
    ) private view {
        uint256 physicalAssets = IHousePool(host.pool()).totalAssets();
        uint256 traderClaimsAssets = host.totalTraderClaimBalanceAssets();
        uint256 effectiveAssets = physicalAssets > traderClaimsAssets ? physicalAssets - traderClaimsAssets : 0;
        if (effectiveAssets < requiredEffectiveAssets) {
            revert ICfdEngineTypes.CfdEngine__PostOpSolvencyBreach();
        }
    }

    /// @notice Applies the live close/decrease settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`. The host must supply a valid delta consistent
    ///      with `currentPosition`; this function does not inspect `delta.valid` or recompute it. It advances carry/mark
    ///      state, updates aggregate side accounting, unlocks only terminal-cap-preserving excess pledge, pays or records
    ///      net price gains, pays affordable action rebates without creating claims,
    ///      consumes eligible collateral and claims for collectible losses, and consumes or releases negative-VPI
    ///      reserve while preserving the residual target. It records LP revenue, funds collectible protocol fees from
    ///      unreserved pool cash, and writes or deletes the position. When a frozen spread was assessed it emits
    ///      `FrozenCloseSpreadSettled` with assessed, recovered, and waived settlement token.
    /// @param delta Valid planned close/decrease delta; prices are 8 decimals, size 18, and settlement token fields 6.
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
        // Close commitments reserve no bounty; settle price and action value from their separate planned sources.
        _executeClose(delta, currentPosition, clearinghouse);
    }

    /// @dev Keep publish-time processing outside the settlement frame's stack budget.
    function _executeClose(
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        IMarginClearinghouse clearinghouse
    ) private {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        uint256 marginBefore = clearinghouse.pnlPledgeAssets(delta.account);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitReduction),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        if (delta.pricePnlClaimConsumedAssets > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.pricePnlClaimConsumedAssets);
        }
        if (delta.pricePnlPledgeConsumedAssets > 0) {
            (uint256 consumedAssets, uint256 shortfallAssets) =
                clearinghouse.consumePnlPledgeLoss(delta.account, delta.pricePnlPledgeConsumedAssets, host.pool());
            if (consumedAssets != delta.pricePnlPledgeConsumedAssets || shortfallAssets != 0) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
        }

        if (delta.safeMarginReleaseAssets != delta.unlockMarginAssets) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        if (delta.deletePosition) {
            // Make terminal reserve surplus free before validating how much charge needs released pledge.
            clearinghouse.releaseLiquidationReserve(delta.account, delta.liquidationReserveReleaseAssets);
        }
        clearinghouse.unlockCloseMargin(
            delta.account,
            delta.safeMarginReleaseAssets,
            delta.actionChargeFromReleasedMarginAssets,
            delta.netReleasedMarginAssets,
            delta.actionChargeToCollectAssets - delta.vpiRebateReserveConsumedAssets,
            delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
                - delta.vpiRebateReserveConsumedAssets
        );
        uint256 protocolFeeCreditedAssets = _settleCloseActionCharge(host, clearinghouse, delta);

        _recordCloseInflows(host, delta, currentPosition.vpiAccrued, protocolFeeCreditedAssets);

        if (delta.pricePayoutAssets > 0) {
            host.settlementRecordTraderClaim(delta.account, delta.pricePayoutAssets, !delta.deletePosition);
        }
        if (delta.actionRebatePaidAssets > 0) {
            IHousePool(host.pool()).payOut(address(clearinghouse), delta.actionRebatePaidAssets);
            clearinghouse.settleAssets(delta.account, int256(delta.actionRebatePaidAssets));
        }

        uint256 marginAfter = clearinghouse.pnlPledgeAssets(delta.account);
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
                    size: delta.closeState.remainingSize,
                    entryCostAssetAtoms: delta.posEntryCostAfterAssetAtoms,
                    maxProfitAssets: currentPosition.maxProfitAssets - delta.posMaxProfitReduction,
                    lastUpdateTime: uint64(block.timestamp),
                    lastCarryTimestamp: uint64(block.timestamp),
                    vpiAccrued: currentPosition.vpiAccrued - delta.posVpiAccruedReduction,
                    side: currentPosition.side
                })
            );
        }
        if (!delta.deletePosition && delta.liquidationReserveReleaseAssets > 0) {
            clearinghouse.releaseLiquidationReserve(delta.account, delta.liquidationReserveReleaseAssets);
        }
        _settleProtocolFeeTopUp(
            host, protocolFeeCreditedAssets + delta.protocolFeeTopUpAssets, protocolFeeCreditedAssets
        );

        if (delta.closeState.frozenSpreadAssets > 0) {
            uint256 frozenSpreadPaidAssets = _recoveredFrozenSpreadAssets(delta);
            emit FrozenCloseSpreadSettled(
                delta.account,
                delta.closeState.frozenSpreadAssets,
                frozenSpreadPaidAssets,
                delta.closeState.frozenSpreadAssets - frozenSpreadPaidAssets
            );
        }
        if (delta.priceLossWrittenOffAssets > 0) {
            emit PriceLossWrittenOff(delta.account, delta.priceLossWrittenOffAssets);
        }
        if (delta.actionRebateAssets > 0) {
            emit ActionRebateSettled(
                delta.account, delta.actionRebateAssets, delta.actionRebatePaidAssets, delta.actionRebateWaivedAssets
            );
        }
        if (delta.actionChargeAssessedAssets > 0) {
            emit ActionChargeSettled(
                delta.account,
                delta.actionChargeAssessedAssets,
                delta.actionChargeWithheldAssets + delta.actionChargeCollectedAssets,
                delta.actionChargeWaivedAssets
            );
        }
    }

    /// @notice Consumes close charges and synchronizes the account's negative-VPI reserve.
    /// @dev Kept separate from `executeClose` so non-IR coverage builds do not exceed the EVM stack limit.
    function _settleCloseActionCharge(
        ICfdEngineSettlementHost host,
        IMarginClearinghouse clearinghouse,
        CfdEnginePlanTypes.CloseDelta calldata delta
    ) private returns (uint256 protocolFeeCreditedAssets) {
        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveBeforeAssets);
        if (delta.vpiRebateReserveConsumedAssets > 0) {
            clearinghouse.consumeVpiRebateReserve(delta.account, host.pool(), delta.vpiRebateReserveConsumedAssets);
        }
        uint256 vpiReserveReleaseAssets = delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
            - delta.vpiRebateReserveConsumedAssets;
        if (vpiReserveReleaseAssets > 0) {
            clearinghouse.releaseVpiRebateReserve(delta.account, vpiReserveReleaseAssets);
        }

        uint256 genericActionChargeToCollectAssets =
            delta.actionChargeToCollectAssets - delta.vpiRebateReserveConsumedAssets;
        if (genericActionChargeToCollectAssets > 0) {
            (uint256 collectedAssets, uint256 creditedAssets) = clearinghouse.consumeActionCharge(
                delta.account,
                genericActionChargeToCollectAssets,
                delta.actionReserveConsumedAssets,
                delta.actionCommittedMarginConsumedAssets,
                host.pool(),
                host.protocolTreasury(),
                delta.actionProtocolFeeCreditedAssets
            );
            if (
                collectedAssets != delta.actionChargeCollectedAssets - delta.vpiRebateReserveConsumedAssets
                    || creditedAssets != delta.actionProtocolFeeCreditedAssets
            ) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
            protocolFeeCreditedAssets = creditedAssets;
        }
        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveAfterAssets);
    }

    /// @notice Attributes recovered action charges to frozen spread after fee, carry, and positive VPI priority.
    function _recoveredFrozenSpreadAssets(
        CfdEnginePlanTypes.CloseDelta calldata delta
    ) private pure returns (uint256 recoveredAssets) {
        uint256 priorChargesAssets =
            delta.closeState.executionFeeAssets + delta.pendingCarryAssets - delta.realizedCarryAssets;
        if (delta.closeState.vpiDeltaAssets > 0) {
            priorChargesAssets += uint256(delta.closeState.vpiDeltaAssets);
        }

        uint256 effectiveSpreadAssets;
        if (delta.actionChargeAssessedAssets > priorChargesAssets) {
            effectiveSpreadAssets = delta.actionChargeAssessedAssets - priorChargesAssets;
            if (effectiveSpreadAssets > delta.closeState.frozenSpreadAssets) {
                effectiveSpreadAssets = delta.closeState.frozenSpreadAssets;
            }
        }

        uint256 totalRecoveredAssets = delta.actionChargeWithheldAssets + delta.actionChargeCollectedAssets;
        if (totalRecoveredAssets > priorChargesAssets) {
            recoveredAssets = totalRecoveredAssets - priorChargesAssets;
            if (recoveredAssets > effectiveSpreadAssets) {
                recoveredAssets = effectiveSpreadAssets;
            }
        }
    }

    /// @notice Records nonzero LP revenue whose cash is already retained in pool accounting.
    /// @param host Bound engine settlement host.
    /// @param amountAssets Revenue to record, in 6-decimal settlement token units.
    function _recordRetainedCloseRevenue(
        ICfdEngineSettlementHost host,
        uint256 amountAssets
    ) private {
        if (amountAssets == 0) {
            return;
        }
        IHousePool(host.pool())
            .recordClaimantInflow(
                amountAssets, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.AlreadyRetained
            );
    }

    /// @dev Deferred VPI cash and collection of an existing VPI receivable are balance changes, not earned intents.
    function _recordCashInflow(
        ICfdEngineSettlementHost host,
        uint256 totalCashAssets,
        uint256 balanceOnlyAssets
    ) private {
        IHousePool pool = IHousePool(host.pool());
        if (balanceOnlyAssets > 0) {
            pool.recordClaimantInflow(
                balanceOnlyAssets,
                IHousePool.ClaimantInflowKind.BalanceOnly,
                IHousePool.ClaimantInflowCashMode.CashArrived
            );
        }
        uint256 revenueAssets = totalCashAssets - balanceOnlyAssets;
        if (revenueAssets > 0) {
            pool.recordClaimantInflow(
                revenueAssets, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
            );
        }
    }

    function _recordCloseInflows(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        int256 previousAccruedVpiAssets,
        uint256 protocolFeeCreditedAssets
    ) private {
        uint256 clawbackAssets = _negativeVpiReserveTarget(previousAccruedVpiAssets)
            - _negativeVpiReserveTarget(previousAccruedVpiAssets - delta.posVpiAccruedReduction);
        _recordCashInflow(
            host,
            delta.pricePnlPledgeConsumedAssets + delta.actionChargeCollectedAssets - protocolFeeCreditedAssets,
            delta.vpiRebateReserveConsumedAssets
        );
        uint256 withheldClawbackAssets = clawbackAssets - delta.vpiRebateReserveConsumedAssets;
        uint256 feeWithheldAssets = delta.executionFeeAssets - protocolFeeCreditedAssets;
        _recordRetainedCloseRevenue(host, delta.actionChargeWithheldAssets - feeWithheldAssets - withheldClawbackAssets);
    }

    function _recordLiquidationInflows(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint256 seizedAssets
    ) private {
        (,,,,,, int256 accruedVpiAssets) = ICfdEngineAccountActionView(address(host)).positions(delta.account);
        uint256 withheldClawbackAssets =
            _negativeVpiReserveTarget(accruedVpiAssets) - delta.vpiRebateReserveConsumedAssets;
        _recordCashInflow(host, seizedAssets + delta.actionChargeCollectedAssets, delta.vpiRebateReserveConsumedAssets);
        _recordRetainedCloseRevenue(host, delta.actionChargeWithheldAssets - withheldClawbackAssets);
    }

    /// @notice Applies the live liquidation settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`. The host must supply a liquidatable delta
    ///      consistent with live state; this function neither checks `delta.liquidatable` nor recomputes the plan. It
    ///      advances carry/mark state, removes all side exposure and margin, applies the clearinghouse terminal-settlement
    ///      plan, credits the configured keeper and protocol shares, transfers the LP remainder to the pool, records
    ///      seized pool inflow, synchronizes consumed order reservations, nets existing claims, settles the gross
    ///      negative lifetime-VPI clawback from its dedicated reserve or equivalent withheld gain, pays or records
    ///      fresh trader value, records applicable carry revenue, and deletes the position.
    /// @param delta Valid planned full-liquidation delta; prices are 8 decimals, size 18, and settlement token fields 6.
    /// @param publishTime Oracle publish timestamp proposed for the liquidation mark.
    /// @param keeper Clearinghouse account credited with the planned bounty.
    /// @return keeperBountyAssets Planned bounty forwarded to clearinghouse settlement, in 6-decimal settlement token units.
    function executeLiquidation(
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external onlyEngine returns (uint256 keeperBountyAssets) {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(msg.sender);
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        uint256 marginBefore = clearinghouse.pnlPledgeAssets(delta.account);
        if (marginBefore != delta.posMargin) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitDecrease),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        if (delta.pricePnlClaimConsumedAssets > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.pricePnlClaimConsumedAssets);
        }

        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveBeforeAssets);
        if (delta.vpiRebateReserveConsumedAssets > 0) {
            clearinghouse.consumeVpiRebateReserve(delta.account, host.pool(), delta.vpiRebateReserveConsumedAssets);
        }
        uint256 vpiReserveReleaseAssets = delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
            - delta.vpiRebateReserveConsumedAssets;
        if (vpiReserveReleaseAssets > 0) {
            clearinghouse.releaseVpiRebateReserve(delta.account, vpiReserveReleaseAssets);
        }
        uint256 genericActionChargeToCollectAssets =
            delta.actionChargeToCollectAssets - delta.vpiRebateReserveConsumedAssets;
        if (genericActionChargeToCollectAssets > 0) {
            (uint256 collectedAssets, uint256 protocolCreditedAssets) = clearinghouse.consumeActionCharge(
                delta.account,
                genericActionChargeToCollectAssets,
                delta.actionReserveConsumedAssets,
                delta.actionCommittedMarginConsumedAssets,
                host.pool(),
                address(0),
                0
            );
            if (
                collectedAssets != delta.actionChargeCollectedAssets - delta.vpiRebateReserveConsumedAssets
                    || protocolCreditedAssets != 0
            ) {
                revert CfdEngineSettlementSidecar__SettlementMismatch();
            }
        }
        _requireVpiReserve(clearinghouse, delta.account, delta.vpiRebateReserveAfterAssets);

        keeperBountyAssets = delta.keeperBountyAssets;
        uint256 seizedAssets = _applyLiquidationSettlementPlan(host, delta, keeper);
        if (seizedAssets != delta.settlementSeizedAssets) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        _recordLiquidationInflows(host, delta, seizedAssets);

        if (delta.freshTraderPayoutAssets > 0) {
            host.settlementRecordTraderClaim(delta.account, delta.freshTraderPayoutAssets, false);
        }
        uint256 marginAfter = clearinghouse.pnlPledgeAssets(delta.account);
        if (marginAfter != 0) {
            revert CfdEngineSettlementSidecar__SettlementMismatch();
        }
        host.settlementSyncTotalSideMargin(delta.side, marginBefore, 0);
        host.settlementDeletePosition(delta.account);

        if (delta.priceLossWrittenOffAssets > 0) {
            emit PriceLossWrittenOff(delta.account, delta.priceLossWrittenOffAssets);
        }
        if (delta.actionChargeAssessedAssets > 0) {
            emit ActionChargeSettled(
                delta.account,
                delta.actionChargeAssessedAssets,
                delta.actionChargeWithheldAssets + delta.actionChargeCollectedAssets,
                delta.actionChargeWaivedAssets
            );
        }
    }

    /// @notice Applies the clearinghouse mutation for a planned liquidation.
    /// @param host Bound engine settlement host.
    /// @param delta Valid planned full-liquidation delta.
    /// @param keeper Clearinghouse account credited with the planned bounty.
    /// @return seizedAssets Amount transferred to the pool by the clearinghouse, in 6-decimal settlement token units.
    function _applyLiquidationSettlementPlan(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        address keeper
    ) private returns (uint256 seizedAssets) {
        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan =
            IMarginClearinghouse.LiquidationSettlementPlan({
                settlementSeizedAssets: delta.settlementSeizedAssets,
                positionMarginUnlockedAssets: delta.residualPlan.mutation.positionMarginUnlockedAssets,
                otherLockedMarginUnlockedAssets: delta.residualPlan.mutation.otherLockedMarginUnlockedAssets
            });
        seizedAssets = IMarginClearinghouse(host.clearinghouse())
            .applyLiquidationSettlementPlan(
                delta.account,
                settlementPlan,
                host.pool(),
                keeper,
                delta.keeperBountyAssets,
                host.protocolTreasury(),
                delta.protocolLiquidationFeeAssets,
                delta.lpLiquidationFeeAssets
            );
    }

    /// @notice Funds an uncredited protocol fee from cash above all current pool and engine reserves.
    /// @dev The top-up is capped by both the requested shortfall and current free pool cash, then paid to the clearinghouse
    ///      and credited to the host's protocol-treasury account.
    /// @param host Bound engine settlement host.
    /// @param amountAssets Total protocol-fee amount intended to be credited.
    /// @param clearinghouseCreditedAssets Portion already credited from clearinghouse cash collection.
    function _settleProtocolFeeTopUp(
        ICfdEngineSettlementHost host,
        uint256 amountAssets,
        uint256 clearinghouseCreditedAssets
    ) private {
        if (clearinghouseCreditedAssets > amountAssets) {
            clearinghouseCreditedAssets = amountAssets;
        }
        uint256 poolFundedAssets = amountAssets - clearinghouseCreditedAssets;
        if (poolFundedAssets == 0) {
            return;
        }

        IHousePool pool = IHousePool(host.pool());
        uint256 freeCashAssets = pool.getSettlementFreeAssets();
        uint256 topUpAssets = poolFundedAssets < freeCashAssets ? poolFundedAssets : freeCashAssets;
        if (topUpAssets == 0) {
            return;
        }
        pool.payOut(host.clearinghouse(), topUpAssets);
        IMarginClearinghouse(host.clearinghouse()).settleAssets(host.protocolTreasury(), int256(topUpAssets));
    }

}
