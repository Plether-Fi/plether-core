// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngineLens} from "./interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "./interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";

contract CfdEngineLens is ICfdEngineLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    function engine() external view returns (address) {
        return address(engineContract);
    }

    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, engineContract.pool().totalAssets());
    }

    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code) {
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
        return uint8(engineContract.planner().planOpen(snap, order, oraclePrice, publishTime).revertCode);
    }

    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category) {
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
        CfdEnginePlanTypes.OpenDelta memory delta =
            engineContract.planner().planOpen(snap, order, oraclePrice, publishTime);
        return engineContract.planner().getOpenFailurePolicyCategory(delta.revertCode);
    }

    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, poolDepthUsdc);
    }

    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, engineContract.pool().totalAssets());
    }

    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, poolDepthUsdc);
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
        snap.bullSide = _sideSnapshot(bull);
        snap.bearSide = _sideSnapshot(bear);
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
        pos.lastCarryTimestamp = engineContract.getPositionLastCarryTimestamp(account);
    }

    function _sideSnapshot(
        ICfdEngineTypes.SideState memory side
    ) internal pure returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: side.maxProfitUsdc,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin
        });
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
