// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {AccountLensViewTypes} from "./interfaces/AccountLensViewTypes.sol";
import {ICfdEngineAccountLens} from "./interfaces/ICfdEngineAccountLens.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";

/// @title CfdEngineAccountLens
/// @notice Rich per-account diagnostic lens for audits, tests, and operator tooling.
/// @dev This is intentionally wider than the product-facing `PerpsPublicLens` surface.
contract CfdEngineAccountLens is ICfdEngineAccountLens {

    CfdEngine public immutable engineContract;

    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @notice Returns detailed clearinghouse bucket and reachability state for an account.
    function getAccountCollateralView(
        bytes32 accountId
    ) external view returns (CfdEngine.AccountCollateralView memory viewData) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(accountId);
        viewData.settlementBalanceUsdc = MarginClearinghouseAccountingLib.getSettlementBalanceUsdc(buckets);
        viewData.lockedMarginUsdc = buckets.totalLockedMarginUsdc;
        viewData.activePositionMarginUsdc = MarginClearinghouseAccountingLib.getPositionMarginUsdc(buckets);
        viewData.otherLockedMarginUsdc = MarginClearinghouseAccountingLib.getQueuedReservedUsdc(buckets);
        viewData.freeSettlementUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);
        viewData.closeReachableUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);
        viewData.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(accountId);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(accountId);
        viewData.deferredTraderCreditUsdc = engineContract.deferredTraderCreditUsdc(accountId);
    }

    /// @notice Returns the current withdrawable USDC for an account under engine-side guards.
    /// @dev Open-position withdrawals are limited by free buying power, degraded mode, mark freshness,
    ///      pending carry, and the post-withdraw initial margin requirement.
    function getWithdrawableUsdc(
        bytes32 accountId
    ) external view returns (uint256 withdrawableUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(accountId);
        withdrawableUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);

        CfdTypes.Position memory pos = _position(accountId);
        if (pos.size == 0) {
            return withdrawableUsdc;
        }
        if (engineContract.degradedMode()) {
            return 0;
        }

        uint256 price = engineContract.lastMarkPrice();
        uint64 lastMarkTime = engineContract.lastMarkTime();
        if (price == 0) {
            return 0;
        }
        ICfdVault vault = engineContract.vault();
        uint256 maxStaleness =
            OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile,
            engineContract.isOracleFrozen(),
            engineContract.isFadWindow(),
            engineContract.engineMarkStalenessLimit(),
            address(vault) == address(0) ? 0 : vault.markStalenessLimit(),
            0,
            0,
            engineContract.fadMaxStaleness()
        )
        .maxStaleness;
        if (block.timestamp > lastMarkTime + maxStaleness) {
            return 0;
        }

        uint256 reachableUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets);
        uint256 pendingCarryUsdc = engineContract.unsettledCarryUsdc(accountId);
        if (pos.size > 0 && pos.lastCarryTimestamp > 0 && block.timestamp > pos.lastCarryTimestamp) {
            uint256 lpBackedNotionalUsdc =
                PositionRiskAccountingLib.computeLpBackedNotionalUsdc(pos.size, price, reachableUsdc);
            pendingCarryUsdc += PositionRiskAccountingLib.computePendingCarryUsdc(
                lpBackedNotionalUsdc, _riskParams().baseCarryBps, block.timestamp - pos.lastCarryTimestamp
            );
        }
        if (pendingCarryUsdc > 0) {
            MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
                MarginClearinghouseAccountingLib.planFundingLossConsumption(buckets, pendingCarryUsdc);
            buckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                buckets.settlementBalanceUsdc - carryConsumption.totalConsumedUsdc,
                buckets.activePositionMarginUsdc - carryConsumption.activeMarginConsumedUsdc,
                buckets.otherLockedMarginUsdc,
                0
            );
            pendingCarryUsdc = carryConsumption.uncoveredUsdc;
        }

        withdrawableUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);
        reachableUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets);
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                pos, price, engineContract.CAP_PRICE(), pendingCarryUsdc, reachableUsdc, _riskParams().initMarginBps
            );

        uint256 initialMarginRequirementUsdc = (riskState.currentNotionalUsdc * _riskParams().initMarginBps) / 10_000;
        if (riskState.equityUsdc <= int256(initialMarginRequirementUsdc)) {
            return 0;
        }

        uint256 imrHeadroomUsdc = uint256(riskState.equityUsdc) - initialMarginRequirementUsdc;
        return imrHeadroomUsdc < withdrawableUsdc ? imrHeadroomUsdc : withdrawableUsdc;
    }

    /// @notice Returns a compact accounting split for account custody, escrow, and deferred balances.
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
        viewData.deferredTraderCreditUsdc = snapshot.deferredTraderCreditUsdc;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    /// @notice Returns the full account ledger snapshot used by tests and richer read paths.
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

        snapshot.settlementBalanceUsdc = MarginClearinghouseAccountingLib.getSettlementBalanceUsdc(buckets);
        snapshot.freeSettlementUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);
        snapshot.activePositionMarginUsdc = MarginClearinghouseAccountingLib.getPositionMarginUsdc(buckets);
        snapshot.otherLockedMarginUsdc = MarginClearinghouseAccountingLib.getQueuedReservedUsdc(buckets);
        snapshot.positionMarginBucketUsdc = lockedBuckets.positionMarginUsdc;
        snapshot.committedOrderMarginBucketUsdc = lockedBuckets.committedOrderMarginUsdc;
        snapshot.reservedSettlementBucketUsdc = lockedBuckets.reservedSettlementUsdc;
        snapshot.executionEscrowUsdc = escrow.executionBountyUsdc;
        snapshot.committedMarginUsdc = escrow.committedMarginUsdc;
        snapshot.deferredTraderCreditUsdc = engineContract.deferredTraderCreditUsdc(accountId);
        snapshot.pendingOrderCount = escrow.pendingOrderCount;
        snapshot.closeReachableUsdc = MarginClearinghouseAccountingLib.getFreeSettlementUsdc(buckets);
        snapshot.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(accountId);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(accountId);

        if (pos.size == 0) {
            return snapshot;
        }

        CfdTypes.RiskParams memory params = _riskParams();
        uint256 price = engineContract.lastMarkPrice();
        uint256 pendingCarryUsdc = 0;
        if (price > 0 && pos.lastCarryTimestamp > 0 && block.timestamp > pos.lastCarryTimestamp) {
            uint256 lpBackedNotionalUsdc =
                PositionRiskAccountingLib.computeLpBackedNotionalUsdc(pos.size, price, snapshot.terminalReachableUsdc);
            pendingCarryUsdc = PositionRiskAccountingLib.computePendingCarryUsdc(
                lpBackedNotionalUsdc, params.baseCarryBps, block.timestamp - pos.lastCarryTimestamp
            );
        }
        pendingCarryUsdc += engineContract.unsettledCarryUsdc(accountId);
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                pos,
                price,
                engineContract.CAP_PRICE(),
                pendingCarryUsdc,
                snapshot.terminalReachableUsdc,
                engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
            );

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginUsdc;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(accountId);
        pos.lastCarryTimestamp = engineContract.getPositionLastCarryTimestamp(accountId);
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
