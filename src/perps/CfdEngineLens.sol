// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEngineLens} from "./interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";

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
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (CfdEngine.ClosePreview memory preview) {
        preview = _previewClose(accountId, sizeDelta, oraclePrice, engineContract.vault().totalAssets());
    }

    function simulateClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.ClosePreview memory preview) {
        preview = _previewClose(accountId, sizeDelta, oraclePrice, vaultDepthUsdc);
    }

    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice
    ) external view returns (CfdEngine.LiquidationPreview memory preview) {
        preview = _previewLiquidation(accountId, oraclePrice, engineContract.vault().totalAssets());
    }

    function simulateLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.LiquidationPreview memory preview) {
        preview = _previewLiquidation(accountId, oraclePrice, vaultDepthUsdc);
    }

    function _previewClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) internal view returns (CfdEngine.ClosePreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;
        ICfdEnginePlanner planner = engineContract.planner();

        CfdTypes.Position memory pos = _position(accountId);
        if (pos.size == 0) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.NoPosition;
            return preview;
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.BadSize;
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(accountId, oraclePrice, vaultDepthUsdc, 0);
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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

        preview.fundingUsdc = delta.funding.pendingFundingUsdc;
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
        preview.existingDeferredConsumedUsdc = delta.existingDeferredConsumedUsdc;
        preview.existingDeferredRemainingUsdc = delta.existingDeferredRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.deferredPayoutUsdc =
            delta.existingDeferredRemainingUsdc + (delta.freshPayoutIsDeferred ? delta.freshTraderPayoutUsdc : 0);
        if (delta.funding.payoutType == CfdEnginePlanTypes.FundingPayoutType.DEFERRED_PAYOUT) {
            preview.deferredPayoutUsdc += uint256(delta.funding.pendingFundingUsdc);
        }

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            preview.seizedCollateralUsdc = delta.lossResult.seizedUsdc;
            preview.badDebtUsdc = delta.badDebtUsdc;
        }

        if (
            delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER
                || delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.FUNDING_PARTIAL_CLOSE_UNDERWATER
        ) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.PartialCloseUnderwater;
            return preview;
        }

        preview.valid = delta.valid;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
        preview.solvencyFundingPnlUsdc = delta.solvency.solvencyFundingPnlUsdc;
    }

    function _previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) internal view returns (CfdEngine.LiquidationPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.oraclePrice = price;
        ICfdEnginePlanner planner = engineContract.planner();
        if (_position(accountId).size == 0) {
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(accountId, oraclePrice, vaultDepthUsdc, 0);
        _applyLiquidationPreviewForfeiture(accountId, snap);
        CfdEnginePlanTypes.LiquidationDelta memory delta = planner.planLiquidation(snap, oraclePrice, 0);

        preview.liquidatable = delta.liquidatable;
        preview.reachableCollateralUsdc = delta.liquidationReachableCollateralUsdc;
        preview.pnlUsdc = delta.riskState.unrealizedPnlUsdc;
        preview.fundingUsdc = delta.riskState.pendingFundingUsdc;
        preview.equityUsdc = delta.riskState.equityUsdc;
        preview.keeperBountyUsdc = delta.keeperBountyUsdc;
        preview.seizedCollateralUsdc = delta.residualPlan.settlementSeizedUsdc;
        preview.settlementRetainedUsdc = delta.settlementRetainedUsdc;
        preview.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        preview.existingDeferredConsumedUsdc = delta.existingDeferredConsumedUsdc;
        preview.existingDeferredRemainingUsdc = delta.existingDeferredRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.deferredPayoutUsdc = delta.existingDeferredRemainingUsdc;
        if (delta.freshPayoutIsDeferred) {
            preview.deferredPayoutUsdc += delta.freshTraderPayoutUsdc;
        }
        preview.badDebtUsdc = delta.badDebtUsdc;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
        preview.solvencyFundingPnlUsdc = delta.solvency.solvencyFundingPnlUsdc;
    }

    function _buildRawSnapshot(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngine.SideState memory bull = engineContract.getSideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bear = engineContract.getSideState(CfdTypes.Side.BEAR);
        uint256 lastMarkPrice = engineContract.lastMarkPrice();
        uint64 lastMarkTime = engineContract.lastMarkTime();
        uint256 liveMarkAge = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        uint256 maxStaleness = engineContract.isOracleFrozen()
            ? engineContract.fadMaxStaleness()
            : engineContract.engineMarkStalenessLimit();

        snap.position = _position(accountId);
        snap.accountId = accountId;
        snap.currentTimestamp = block.timestamp;
        snap.lastFundingTime = engineContract.lastFundingTime();
        snap.lastMarkPrice = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        if (lastMarkPrice != 0) {
            snap.lastMarkPrice = lastMarkPrice;
        }
        snap.lastMarkTime = publishTime == 0 ? lastMarkTime : publishTime;
        snap.bullSide = _sideSnapshot(bull);
        snap.bearSide = _sideSnapshot(bear);
        snap.fundingVaultDepthUsdc = vaultDepthUsdc;
        snap.vaultAssetsUsdc = vaultDepthUsdc;
        snap.vaultCashUsdc = vaultDepthUsdc;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engineContract.clearinghouse());
        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(accountId);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        snap.accumulatedFeesUsdc = engineContract.accumulatedFeesUsdc();
        snap.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snap.totalDeferredPayoutUsdc = engineContract.totalDeferredPayoutUsdc();
        snap.totalDeferredClearerBountyUsdc = engineContract.totalDeferredClearerBountyUsdc();
        snap.deferredPayoutForAccount = engineContract.deferredPayoutUsdc(accountId);
        snap.degradedMode = engineContract.degradedMode();
        snap.capPrice = engineContract.CAP_PRICE();
        snap.riskParams = _riskParams();
        snap.isFadWindow = engineContract.isFadWindow();
        snap.liveMarkFreshForFunding = liveMarkAge <= maxStaleness;
    }

    function _applyLiquidationPreviewForfeiture(
        bytes32 accountId,
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal view {
        address orderRouter = engineContract.orderRouter();
        if (orderRouter == address(0)) {
            return;
        }
        uint256 forfeitedUsdc = IOrderRouterAccounting(orderRouter).getAccountEscrow(accountId).executionBountyUsdc;
        if (forfeitedUsdc == 0) {
            return;
        }
        snap.fundingVaultDepthUsdc += forfeitedUsdc;
        snap.vaultAssetsUsdc += forfeitedUsdc;
        snap.vaultCashUsdc += forfeitedUsdc;
        snap.accumulatedFeesUsdc += forfeitedUsdc;
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        (
            pos.size,
            pos.margin,
            pos.entryPrice,
            pos.maxProfitUsdc,
            pos.entryFundingIndex,
            pos.side,
            pos.lastUpdateTime,
            pos.vpiAccrued
        ) = engineContract.positions(accountId);
    }

    function _sideSnapshot(
        ICfdEngine.SideState memory side
    ) internal pure returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: side.maxProfitUsdc,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin,
            fundingIndex: side.fundingIndex,
            entryFunding: side.entryFunding
        });
    }

    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        (
            params.vpiFactor,
            params.maxSkewRatio,
            params.kinkSkewRatio,
            params.baseApy,
            params.maxApy,
            params.maintMarginBps,
            params.initMarginBps,
            params.fadMarginBps,
            params.minBountyUsdc,
            params.bountyBps
        ) = engineContract.riskParams();
    }

}
