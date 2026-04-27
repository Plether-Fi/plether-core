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
        address account
    ) external view returns (CfdEngine.AccountCollateralView memory viewData) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(account);
        viewData.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        viewData.lockedMarginUsdc = buckets.totalLockedMarginUsdc;
        viewData.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        viewData.freeSettlementUsdc = buckets.freeSettlementUsdc;
        viewData.closeReachableUsdc = buckets.freeSettlementUsdc;
        viewData.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(account);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(account);
        viewData.traderClaimBalanceUsdc = engineContract.clearinghouse().traderClaimBalanceUsdc(account);
    }

    /// @notice Returns the current withdrawable USDC for an account under engine-side guards.
    /// @dev Open-position withdrawals are limited by free buying power, degraded mode, mark freshness,
    ///      pending carry, and the post-withdraw initial margin requirement.
    function getWithdrawableUsdc(
        address account
    ) external view returns (uint256 withdrawableUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(account);
        withdrawableUsdc = buckets.freeSettlementUsdc;

        CfdTypes.Position memory pos = _position(account);
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
        uint256 pendingCarryUsdc = engineContract.unsettledCarryUsdc(account);
        if (pos.size > 0 && pos.lastCarryTimestamp > 0 && block.timestamp > pos.lastCarryTimestamp) {
            uint256 lpBackedNotionalUsdc =
                PositionRiskAccountingLib.computeLpBackedNotionalUsdc(pos.size, price, reachableUsdc);
            pendingCarryUsdc += PositionRiskAccountingLib.computePendingCarryUsdc(
                lpBackedNotionalUsdc, _riskParams().baseCarryBps, block.timestamp - pos.lastCarryTimestamp
            );
        }
        if (pendingCarryUsdc > 0) {
            MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
                MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
            buckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                buckets.settlementBalanceUsdc - carryConsumption.totalConsumedUsdc,
                buckets.activePositionMarginUsdc - carryConsumption.activeMarginConsumedUsdc,
                buckets.otherLockedMarginUsdc,
                0
            );
            pendingCarryUsdc = carryConsumption.uncoveredUsdc;
        }

        withdrawableUsdc = buckets.freeSettlementUsdc;
        reachableUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets);
        CfdTypes.RiskParams memory params = _riskParams();
        uint256 currentMarginBps = engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps;
        uint256 effectiveMarginBps = params.initMarginBps > currentMarginBps ? params.initMarginBps : currentMarginBps;
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                pos, price, engineContract.CAP_PRICE(), pendingCarryUsdc, reachableUsdc, effectiveMarginBps
            );

        uint256 initialMarginRequirementUsdc = (riskState.currentNotionalUsdc * effectiveMarginBps) / 10_000;
        if (riskState.equityUsdc <= int256(initialMarginRequirementUsdc)) {
            return 0;
        }

        uint256 imrHeadroomUsdc = uint256(riskState.equityUsdc) - initialMarginRequirementUsdc;
        return imrHeadroomUsdc < withdrawableUsdc ? imrHeadroomUsdc : withdrawableUsdc;
    }

    /// @notice Returns a compact accounting split for account custody, escrow, and claim balances.
    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(account);
        viewData.settlementBalanceUsdc = snapshot.settlementBalanceUsdc;
        viewData.freeSettlementUsdc = snapshot.freeSettlementUsdc;
        viewData.activePositionMarginUsdc = snapshot.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = snapshot.otherLockedMarginUsdc;
        viewData.executionEscrowUsdc = snapshot.executionEscrowUsdc;
        viewData.committedMarginUsdc = snapshot.committedMarginUsdc;
        viewData.traderClaimBalanceUsdc = snapshot.traderClaimBalanceUsdc;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    /// @notice Returns the full account ledger snapshot used by tests and richer read paths.
    function getAccountLedgerSnapshot(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot) {
        return _buildAccountLedgerSnapshot(account);
    }

    function _buildAccountLedgerSnapshot(
        address account
    ) internal view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot) {
        CfdTypes.Position memory pos = _position(account);
        IMarginClearinghouse clearinghouse = engineContract.clearinghouse();
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        IOrderRouterAccounting.AccountEscrowView memory escrow =
            IOrderRouterAccounting(engineContract.orderRouter()).getAccountEscrow(account);

        snapshot.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        snapshot.freeSettlementUsdc = buckets.freeSettlementUsdc;
        snapshot.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        snapshot.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        snapshot.positionMarginBucketUsdc = lockedBuckets.positionMarginUsdc;
        snapshot.committedOrderMarginBucketUsdc = lockedBuckets.committedOrderMarginUsdc;
        snapshot.reservedSettlementBucketUsdc = lockedBuckets.reservedSettlementUsdc;
        snapshot.executionEscrowUsdc = escrow.executionBountyUsdc;
        snapshot.committedMarginUsdc = escrow.committedMarginUsdc;
        snapshot.traderClaimBalanceUsdc = engineContract.clearinghouse().traderClaimBalanceUsdc(account);
        snapshot.pendingOrderCount = escrow.pendingOrderCount;
        snapshot.closeReachableUsdc = buckets.freeSettlementUsdc;
        snapshot.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(buckets);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(account);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(account);

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
        pendingCarryUsdc += engineContract.unsettledCarryUsdc(account);
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
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        pos.lastCarryTimestamp = engineContract.getPositionLastCarryTimestamp(account);
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
