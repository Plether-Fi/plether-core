// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngineLens} from "./interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "./interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "./libraries/OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Read-only planner and liquidation diagnostics for the CFD engine.
contract CfdEngineLens is ICfdEngineLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @inheritdoc ICfdEngineLens
    function engine() external view returns (address) {
        return address(engineContract);
    }

    /// @inheritdoc ICfdEngineLens
    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @inheritdoc ICfdEngineLens
    function previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (ICfdEngineTypes.OpenPreview memory preview) {
        preview = _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime);
    }

    /// @inheritdoc ICfdEngineLens
    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code) {
        return uint8(_previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime).invalidReason);
    }

    /// @inheritdoc ICfdEngineLens
    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category) {
        return _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime).failureCategory;
    }

    /// @inheritdoc ICfdEngineLens
    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, poolDepthUsdc);
    }

    /// @inheritdoc ICfdEngineLens
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @inheritdoc ICfdEngineLens
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, poolDepthUsdc);
    }

    function _previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) internal view returns (ICfdEngineTypes.OpenPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;
        preview.marginDeltaUsdc = marginDelta;

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(account, oraclePrice, engineContract.pool().totalAssets(), publishTime);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: side,
            isClose: false
        });
        ICfdEnginePlanner planner = engineContract.planner();
        CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, oraclePrice, publishTime);

        preview.valid = delta.valid;
        preview.invalidReason = delta.revertCode;
        preview.failureCategory = planner.getOpenFailurePolicyCategory(delta.revertCode);
        preview.notionalUsdc = delta.openState.notionalUsdc;
        preview.vpiUsdc = delta.openState.vpiUsdc;
        preview.executionFeeUsdc = delta.executionFeeUsdc;
        preview.tradeCostUsdc = delta.tradeCostUsdc;
        preview.poolRebatePayoutUsdc = delta.poolRebatePayoutUsdc;
        preview.pendingCarryUsdc = delta.pendingCarryUsdc;
        preview.initialMarginRequirementUsdc = delta.openState.initialMarginRequirementUsdc;
        preview.maintenanceMarginUsdc = delta.openState.maintenanceMarginUsdc;
        preview.postSize = delta.newPosSize;
        preview.postMarginUsdc = delta.positionMarginAfterOpen;
        preview.postEntryPrice = delta.newPosEntryPrice;
        preview.postVpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;

        if (!delta.valid) {
            return preview;
        }

        CfdTypes.Position memory projected = _projectOpenPosition(snap.position, delta);
        uint256 reachableCollateralUsdc =
            _postOpenReachableCollateral(snap, delta.pendingCarryUsdc, delta.tradeCostUsdc);
        uint256 maintenanceBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        PositionRiskAccountingLib.PositionRiskState memory risk =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                projected, price, snap.capPrice, 0, reachableCollateralUsdc, maintenanceBps
            );

        preview.postUnrealizedPnlUsdc = risk.unrealizedPnlUsdc;
        preview.postEquityUsdc = risk.equityUsdc;
        preview.maintenanceMarginUsdc = risk.maintenanceMarginUsdc;
        preview.postLiquidatable = risk.liquidatable;
        preview.postHealthBps = _healthBps(risk.equityUsdc, risk.maintenanceMarginUsdc);
        (preview.hasLiquidationPrice, preview.liquidationPrice) =
            _findLiquidationPrice(projected, snap.capPrice, reachableCollateralUsdc, maintenanceBps);
    }

    function _previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) internal view returns (ICfdEngineTypes.ClosePreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;
        ICfdEnginePlanner planner = engineContract.planner();

        CfdTypes.Position memory pos = _position(account);
        if (pos.size == 0) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.NoPosition;
            return preview;
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.BadSize;
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, oraclePrice, poolDepthUsdc, 0);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: pos.side,
            isClose: true
        });
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, oraclePrice, 0);

        preview.realizedPnlUsdc = delta.realizedPnlUsdc;
        preview.remainingMargin = delta.posMarginAfter;
        preview.remainingSize = pos.size - sizeDelta;
        preview.vpiDeltaUsdc = delta.closeState.vpiDeltaUsdc;
        if (delta.closeState.vpiDeltaUsdc > 0) {
            preview.vpiUsdc = uint256(delta.closeState.vpiDeltaUsdc);
        }
        preview.executionFeeUsdc = delta.executionFeeUsdc;

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.DustPosition;
            return preview;
        }

        preview.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        preview.existingTraderClaimConsumedUsdc = delta.existingTraderClaimConsumedUsdc;
        preview.existingTraderClaimRemainingUsdc = delta.existingTraderClaimRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.traderClaimBalanceUsdc =
            delta.existingTraderClaimRemainingUsdc + (delta.freshPayoutCreatesClaim ? delta.freshTraderPayoutUsdc : 0);
        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            preview.seizedCollateralUsdc = delta.lossResult.seizedUsdc;
            preview.badDebtUsdc = delta.badDebtUsdc;
        }

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.PartialCloseUnderwater;
            return preview;
        }

        preview.valid = delta.valid;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    function _projectOpenPosition(
        CfdTypes.Position memory current,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal pure returns (CfdTypes.Position memory projected) {
        projected = current;
        projected.side = delta.posSide;
        projected.size = delta.newPosSize;
        projected.margin =
            OpenAccountingLib.effectiveMarginAfterTradeCost(delta.positionMarginAfterOpen, delta.tradeCostUsdc);
        projected.entryPrice = delta.newPosEntryPrice;
        projected.maxProfitUsdc = current.maxProfitUsdc + delta.posMaxProfitIncrease;
        projected.vpiAccrued = current.vpiAccrued + delta.posVpiAccruedDelta;
    }

    function _postOpenReachableCollateral(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (uint256 reachableCollateralUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            _accountBucketsAfterOpenCarryRealization(snap, pendingCarryUsdc);
        reachableCollateralUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets);
        if (tradeCostUsdc > 0) {
            uint256 costUsdc = SafeCast.toUint256(tradeCostUsdc);
            reachableCollateralUsdc = reachableCollateralUsdc > costUsdc ? reachableCollateralUsdc - costUsdc : 0;
        } else if (tradeCostUsdc < 0) {
            reachableCollateralUsdc += SafeCast.toUint256(-tradeCostUsdc);
        }
    }

    function _accountBucketsAfterOpenCarryRealization(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = snap.accountBuckets;
        if (pendingCarryUsdc == 0 || snap.position.size == 0) {
            return buckets;
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
        if (consumption.uncoveredUsdc > 0) {
            return buckets;
        }

        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            buckets.settlementBalanceUsdc - consumption.totalConsumedUsdc,
            snap.lockedBuckets.positionMarginUsdc - consumption.activeMarginConsumedUsdc,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.lockedBuckets.reservedSettlementUsdc
        );
    }

    function _healthBps(
        int256 equityUsdc,
        uint256 maintenanceMarginUsdc
    ) internal pure returns (uint256 healthBps) {
        if (equityUsdc <= 0 || maintenanceMarginUsdc == 0) {
            return 0;
        }
        return (SafeCast.toUint256(equityUsdc) * 10_000) / maintenanceMarginUsdc;
    }

    function _findLiquidationPrice(
        CfdTypes.Position memory projected,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 maintenanceBps
    ) internal pure returns (bool hasLiquidationPrice, uint256 liquidationPrice) {
        bool liquidatableAtZero =
            _isProjectedLiquidatable(projected, 0, capPrice, reachableCollateralUsdc, maintenanceBps);
        bool liquidatableAtCap =
            _isProjectedLiquidatable(projected, capPrice, capPrice, reachableCollateralUsdc, maintenanceBps);

        if (projected.side == CfdTypes.Side.BULL) {
            if (!liquidatableAtCap) {
                return (false, 0);
            }
            if (liquidatableAtZero) {
                return (true, 0);
            }
            uint256 low;
            uint256 high = capPrice;
            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (_isProjectedLiquidatable(projected, mid, capPrice, reachableCollateralUsdc, maintenanceBps)) {
                    high = mid;
                } else {
                    low = mid + 1;
                }
            }
            return (true, high);
        }

        if (!liquidatableAtZero) {
            return (false, 0);
        }
        if (liquidatableAtCap) {
            return (true, capPrice);
        }
        uint256 lo;
        uint256 hi = capPrice;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_isProjectedLiquidatable(projected, mid, capPrice, reachableCollateralUsdc, maintenanceBps)) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return (true, lo);
    }

    function _isProjectedLiquidatable(
        CfdTypes.Position memory projected,
        uint256 price,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 maintenanceBps
    ) internal pure returns (bool) {
        return PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            projected, price, capPrice, 0, reachableCollateralUsdc, maintenanceBps
        )
        .liquidatable;
    }

    function _previewLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) internal view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.oraclePrice = price;
        ICfdEnginePlanner planner = engineContract.planner();
        if (_position(account).size == 0) {
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, oraclePrice, poolDepthUsdc, 0);
        _applyLiquidationPreviewForfeiture(account, snap);
        CfdEnginePlanTypes.LiquidationDelta memory delta = planner.planLiquidation(snap, oraclePrice, 0);

        preview.liquidatable = delta.liquidatable;
        preview.reachableCollateralUsdc = delta.liquidationReachableCollateralUsdc;
        preview.pnlUsdc = delta.riskState.unrealizedPnlUsdc;
        preview.equityUsdc = delta.liquidationState.equityUsdc;
        preview.keeperBountyUsdc = delta.keeperBountyUsdc;
        preview.seizedCollateralUsdc = delta.residualPlan.settlementSeizedUsdc;
        preview.settlementRetainedUsdc = delta.settlementRetainedUsdc;
        preview.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        preview.existingTraderClaimConsumedUsdc = delta.existingTraderClaimConsumedUsdc;
        preview.existingTraderClaimRemainingUsdc = delta.existingTraderClaimRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.traderClaimBalanceUsdc = delta.existingTraderClaimRemainingUsdc;
        if (delta.freshPayoutCreatesClaim) {
            preview.traderClaimBalanceUsdc += delta.freshTraderPayoutUsdc;
        }
        preview.badDebtUsdc = delta.badDebtUsdc;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    function _buildRawSnapshot(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineTypes.SideState memory bull;
        ICfdEngineTypes.SideState memory bear;
        (bull.maxProfitUsdc, bull.openInterest, bull.entryNotional, bull.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.BULL));
        (bear.maxProfitUsdc, bear.openInterest, bear.entryNotional, bear.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.BEAR));
        uint256 lastMarkPrice = engineContract.lastMarkPrice();
        uint64 lastMarkTime = engineContract.lastMarkTime();
        uint256 liveMarkAge = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        uint256 maxStaleness = engineContract.isOracleFrozen()
            ? engineContract.fadMaxStaleness()
            : engineContract.engineMarkStalenessLimit();

        snap.position = _position(account);
        snap.account = account;
        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        if (lastMarkPrice != 0) {
            snap.lastMarkPrice = lastMarkPrice;
        }
        snap.lastMarkTime = publishTime == 0 ? lastMarkTime : publishTime;
        (snap.positionBorrowBaseUsdc, snap.positionLastCarryIndex,) = engineContract.positionCarryState(account);
        snap.bullSide = _sideSnapshot(CfdTypes.Side.BULL, bull);
        snap.bearSide = _sideSnapshot(CfdTypes.Side.BEAR, bear);
        snap.poolAssetsUsdc = poolDepthUsdc;
        snap.poolCashUsdc = poolDepthUsdc;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engineContract.clearinghouse());
        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snap.unsettledCarryUsdc = engineContract.unsettledCarryUsdc(account);
        snap.totalTraderClaimBalanceUsdc = engineContract.totalTraderClaimBalanceUsdc();
        snap.traderClaimBalanceForAccount = engineContract.traderClaimBalanceUsdc(account);
        snap.degradedMode = engineContract.degradedMode();
        snap.capPrice = engineContract.CAP_PRICE();
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engineContract.executionFeeBps();
        snap.isFadWindow = engineContract.isFadWindow();
        snap.oracleFrozen = engineContract.isOracleFrozen();
        snap.frozenCloseVpiFactor = engineContract.frozenCloseVpiFactor();
        liveMarkAge;
        maxStaleness;
    }

    function _applyLiquidationPreviewForfeiture(
        address account,
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal view {
        address orderRouter = engineContract.orderRouter();
        if (orderRouter == address(0)) {
            return;
        }

        uint256 forfeitedUsdc = IOrderRouterAccounting(orderRouter).getAccountReservations(account).executionBountyUsdc;
        if (forfeitedUsdc == 0) {
            return;
        }
        if (forfeitedUsdc > snap.accountBuckets.settlementBalanceUsdc) {
            forfeitedUsdc = snap.accountBuckets.settlementBalanceUsdc;
        }
        snap.accountBuckets.settlementBalanceUsdc -= forfeitedUsdc;

        uint256 releasedReserveUsdc = forfeitedUsdc;
        if (releasedReserveUsdc > snap.lockedBuckets.reservedSettlementUsdc) {
            releasedReserveUsdc = snap.lockedBuckets.reservedSettlementUsdc;
        }
        snap.lockedBuckets.reservedSettlementUsdc -= releasedReserveUsdc;
        snap.lockedBuckets.totalLockedMarginUsdc -= releasedReserveUsdc;
        uint256 accountReserveReleaseUsdc = releasedReserveUsdc;
        if (accountReserveReleaseUsdc > snap.accountBuckets.otherLockedMarginUsdc) {
            accountReserveReleaseUsdc = snap.accountBuckets.otherLockedMarginUsdc;
        }
        snap.accountBuckets.otherLockedMarginUsdc -= accountReserveReleaseUsdc;
        snap.accountBuckets.totalLockedMarginUsdc -= accountReserveReleaseUsdc;
        snap.accountBuckets.freeSettlementUsdc = snap.accountBuckets.settlementBalanceUsdc
            > snap.accountBuckets.totalLockedMarginUsdc
            ? snap.accountBuckets.settlementBalanceUsdc - snap.accountBuckets.totalLockedMarginUsdc
            : 0;
    }

    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        (,, pos.lastCarryTimestamp) = engineContract.positionCarryState(account);
    }

    function _sideSnapshot(
        CfdTypes.Side sideId,
        ICfdEngineTypes.SideState memory side
    ) internal view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: side.maxProfitUsdc,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin,
            borrowBaseUsdc: engineContract.sideBorrowBaseUsdc(uint256(sideId)),
            carryIndex: _currentSideCarryIndex(sideId)
        });
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,) = engineContract.riskParams();
        return PositionRiskAccountingLib.computeCurrentCarryIndex(
            engineContract.sideCarryIndex(sideIndex),
            engineContract.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engineContract.sideBorrowBaseUsdc(sideIndex),
            engineContract.pool().totalAssets(),
            baseCarryBps
        );
    }

    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        (
            params.vpiFactor,
            params.maxSkewRatio,
            params.maintMarginBps,
            params.initMarginBps,
            params.fadMarginBps,
            params.baseCarryBps,
            params.minBountyUsdc,
            params.bountyBps
        ) = engineContract.riskParams();
    }

}
