// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEngineAccountLens} from "./interfaces/ICfdEngineAccountLens.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";

contract CfdEngineAccountLens is ICfdEngineAccountLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    function engine() external view returns (address) {
        return address(engineContract);
    }

    function getAccountCollateralView(
        bytes32 accountId
    ) external view returns (CfdEngine.AccountCollateralView memory viewData) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(accountId);
        viewData.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        viewData.lockedMarginUsdc = buckets.totalLockedMarginUsdc;
        viewData.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        viewData.freeSettlementUsdc = buckets.freeSettlementUsdc;
        viewData.closeReachableUsdc = engineContract.clearinghouse().getFreeSettlementBalanceUsdc(accountId);
        viewData.terminalReachableUsdc = engineContract.clearinghouse().getTerminalReachableUsdc(accountId);
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(accountId);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(accountId);
        viewData.deferredPayoutUsdc = engineContract.deferredPayoutUsdc(accountId);
    }

    function getAccountLedgerView(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerView memory viewData) {
        ICfdEngine.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(accountId);
        viewData.settlementBalanceUsdc = snapshot.settlementBalanceUsdc;
        viewData.freeSettlementUsdc = snapshot.freeSettlementUsdc;
        viewData.activePositionMarginUsdc = snapshot.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = snapshot.otherLockedMarginUsdc;
        viewData.executionEscrowUsdc = snapshot.executionEscrowUsdc;
        viewData.committedMarginUsdc = snapshot.committedMarginUsdc;
        viewData.deferredPayoutUsdc = snapshot.deferredPayoutUsdc;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    function getAccountLedgerSnapshot(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerSnapshot memory snapshot) {
        return _buildAccountLedgerSnapshot(accountId);
    }

    function _buildAccountLedgerSnapshot(
        bytes32 accountId
    ) internal view returns (ICfdEngine.AccountLedgerSnapshot memory snapshot) {
        CfdTypes.Position memory pos = _position(accountId);
        IMarginClearinghouse clearinghouse = engineContract.clearinghouse();
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        IOrderRouterAccounting.AccountEscrowView memory escrow =
            IOrderRouterAccounting(engineContract.orderRouter()).getAccountEscrow(accountId);

        snapshot.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        snapshot.freeSettlementUsdc = buckets.freeSettlementUsdc;
        snapshot.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        snapshot.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        snapshot.positionMarginBucketUsdc = lockedBuckets.positionMarginUsdc;
        snapshot.committedOrderMarginBucketUsdc = lockedBuckets.committedOrderMarginUsdc;
        snapshot.reservedSettlementBucketUsdc = lockedBuckets.reservedSettlementUsdc;
        snapshot.executionEscrowUsdc = escrow.executionBountyUsdc;
        snapshot.committedMarginUsdc = escrow.committedMarginUsdc;
        snapshot.deferredPayoutUsdc = engineContract.deferredPayoutUsdc(accountId);
        snapshot.pendingOrderCount = escrow.pendingOrderCount;
        snapshot.closeReachableUsdc = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        snapshot.terminalReachableUsdc = clearinghouse.getTerminalReachableUsdc(accountId);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(accountId);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(accountId);

        if (pos.size == 0) {
            return snapshot;
        }

        CfdTypes.RiskParams memory params = _riskParams();
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos,
            engineContract.lastMarkPrice(),
            engineContract.CAP_PRICE(),
            _getProjectedPendingFunding(accountId, pos),
            snapshot.terminalReachableUsdc,
            engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
        );

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginUsdc;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.pendingFundingUsdc = riskState.pendingFundingUsdc;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
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

    function _getProjectedPendingFunding(
        bytes32 accountId,
        CfdTypes.Position memory pos
    ) internal view returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        CfdEnginePlanTypes.RawSnapshot memory snap = CfdEnginePlanTypes.RawSnapshot({
            position: _position(accountId),
            accountId: accountId,
            currentTimestamp: block.timestamp,
            lastFundingTime: engineContract.lastFundingTime(),
            lastMarkPrice: engineContract.lastMarkPrice(),
            lastMarkTime: engineContract.lastMarkTime(),
            bullSide: _sideSnapshot(engineContract.getSideState(CfdTypes.Side.BULL)),
            bearSide: _sideSnapshot(engineContract.getSideState(CfdTypes.Side.BEAR)),
            fundingVaultDepthUsdc: engineContract.vault().totalAssets(),
            vaultAssetsUsdc: engineContract.vault().totalAssets(),
            vaultCashUsdc: engineContract.vault().totalAssets(),
            accountBuckets: engineContract.clearinghouse().getAccountUsdcBuckets(accountId),
            lockedBuckets: engineContract.clearinghouse().getLockedMarginBuckets(accountId),
            marginReservationIds: new uint64[](0),
            accumulatedFeesUsdc: engineContract.accumulatedFeesUsdc(),
            accumulatedBadDebtUsdc: engineContract.accumulatedBadDebtUsdc(),
            totalDeferredPayoutUsdc: engineContract.totalDeferredPayoutUsdc(),
            totalDeferredClearerBountyUsdc: engineContract.totalDeferredClearerBountyUsdc(),
            deferredPayoutForAccount: engineContract.deferredPayoutUsdc(accountId),
            degradedMode: engineContract.degradedMode(),
            capPrice: engineContract.CAP_PRICE(),
            riskParams: _riskParams(),
            isFadWindow: engineContract.isFadWindow(),
            liveMarkFreshForFunding: true
        });
        CfdEnginePlanTypes.GlobalFundingDelta memory fundingDelta =
            CfdEnginePlanLib.planGlobalFunding(snap, engineContract.lastMarkPrice(), 0);
        int256 postFundingIndex = pos.side == CfdTypes.Side.BULL
            ? snap.bullSide.fundingIndex + fundingDelta.bullFundingIndexDelta
            : snap.bearSide.fundingIndex + fundingDelta.bearFundingIndexDelta;
        fundingUsdc = PositionRiskAccountingLib.getPendingFunding(pos, postFundingIndex);
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

}
