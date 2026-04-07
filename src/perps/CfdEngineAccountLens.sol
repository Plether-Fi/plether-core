// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {AccountLensViewTypes} from "./interfaces/AccountLensViewTypes.sol";
import {ICfdEngineAccountLens} from "./interfaces/ICfdEngineAccountLens.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";

contract CfdEngineAccountLens is ICfdEngineAccountLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
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
        viewData.closeReachableUsdc = buckets.freeSettlementUsdc;
        viewData.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(accountId);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(accountId);
        viewData.deferredPayoutUsdc = engineContract.deferredPayoutUsdc(accountId);
    }

    function getAccountLedgerView(
        bytes32 accountId
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(accountId);
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
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot) {
        return _buildAccountLedgerSnapshot(accountId);
    }

    function _buildAccountLedgerSnapshot(
        bytes32 accountId
    ) internal view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot) {
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
        snapshot.closeReachableUsdc = buckets.freeSettlementUsdc;
        snapshot.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
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
            snapshot.terminalReachableUsdc,
            engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
        );

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginUsdc;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.pendingFundingUsdc = 0;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc,, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(accountId);
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
