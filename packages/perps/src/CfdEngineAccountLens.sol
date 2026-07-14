// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineAccountLens} from "@plether/perps/interfaces/ICfdEngineAccountLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

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
    /// @param account Account to inspect
    /// @return viewData Collateral, reachability, and claim balances for the account
    function getAccountCollateralView(
        address account
    ) external view returns (ICfdEngineTypes.AccountCollateralView memory viewData) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            engineContract.clearinghouse().getAccountUsdcBuckets(account);
        viewData.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        viewData.lockedMarginUsdc = buckets.totalLockedMarginUsdc;
        viewData.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        viewData.freeSettlementUsdc = buckets.freeSettlementUsdc;
        viewData.closeReachableUsdc = buckets.freeSettlementUsdc;
        uint256 executionBountyReserveUsdc;
        address orderRouter = engineContract.orderRouter();
        if (orderRouter != address(0)) {
            executionBountyReserveUsdc =
            IOrderRouterAccounting(orderRouter).getAccountReservations(account).executionBountyUsdc;
        }
        viewData.terminalReachableUsdc = buckets.settlementBalanceUsdc > executionBountyReserveUsdc
            ? buckets.settlementBalanceUsdc - executionBountyReserveUsdc
            : 0;
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(account);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(account);
        viewData.traderClaimBalanceUsdc = engineContract.traderClaimBalanceUsdc(account);
    }

    /// @notice Returns the current withdrawable USDC for an account under engine-side guards.
    /// @dev Open-position withdrawals are limited by free buying power, degraded mode, mark freshness,
    ///      pending carry, and the post-withdraw initial margin requirement.
    /// @param account Account to inspect
    /// @return withdrawableUsdc Free settlement amount currently withdrawable
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
        IHousePool pool = engineContract.pool();
        uint256 maxStaleness =
            OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile,
            engineContract.isOracleFrozen(),
            engineContract.isFadWindow(),
            engineContract.engineMarkStalenessLimit(),
            address(pool) == address(0) ? 0 : pool.markStalenessLimit(),
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
        pendingCarryUsdc += _elapsedCarryUsdc(account, pos);
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

    /// @notice Returns a compact accounting split for account custody, reservation, and trader claims.
    /// @param account Account to inspect
    /// @return viewData Compact ledger view
    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(account);
        viewData.settlementBalanceUsdc = snapshot.settlementBalanceUsdc;
        viewData.freeSettlementUsdc = snapshot.freeSettlementUsdc;
        viewData.activePositionMarginUsdc = snapshot.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = snapshot.otherLockedMarginUsdc;
        viewData.executionBountyReserveUsdc = snapshot.executionBountyReserveUsdc;
        viewData.committedMarginUsdc = snapshot.committedMarginUsdc;
        viewData.traderClaimBalanceUsdc = snapshot.traderClaimBalanceUsdc;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    /// @notice Returns the full account ledger snapshot used by tests and richer read paths.
    /// @param account Account to inspect
    /// @return snapshot Full account ledger snapshot
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
        IOrderRouterAccounting.AccountReservationView memory reservation =
            IOrderRouterAccounting(engineContract.orderRouter()).getAccountReservations(account);

        snapshot.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        snapshot.freeSettlementUsdc = buckets.freeSettlementUsdc;
        snapshot.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        snapshot.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        snapshot.positionMarginBucketUsdc = lockedBuckets.positionMarginUsdc;
        snapshot.committedOrderMarginBucketUsdc = lockedBuckets.committedOrderMarginUsdc;
        snapshot.reservedSettlementBucketUsdc = lockedBuckets.reservedSettlementUsdc;
        snapshot.executionBountyReserveUsdc = reservation.executionBountyUsdc;
        snapshot.committedMarginUsdc = reservation.committedMarginUsdc;
        snapshot.traderClaimBalanceUsdc = engineContract.traderClaimBalanceUsdc(account);
        snapshot.pendingOrderCount = reservation.pendingOrderCount;
        snapshot.closeReachableUsdc = buckets.freeSettlementUsdc;
        uint256 reservationExcludedSettlementUsdc = buckets.settlementBalanceUsdc > reservation.executionBountyUsdc
            ? buckets.settlementBalanceUsdc - reservation.executionBountyUsdc
            : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory terminalBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: reservationExcludedSettlementUsdc,
            totalLockedMarginUsdc: buckets.totalLockedMarginUsdc,
            activePositionMarginUsdc: buckets.activePositionMarginUsdc,
            otherLockedMarginUsdc: buckets.otherLockedMarginUsdc,
            freeSettlementUsdc: buckets.freeSettlementUsdc
        });
        snapshot.terminalReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(terminalBuckets);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(account);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(account);

        if (pos.size == 0) {
            return snapshot;
        }

        PositionRiskAccountingLib.PositionRiskState memory riskState =
            _buildSnapshotRiskState(account, pos, snapshot.terminalReachableUsdc);

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginUsdc;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
    }

    function _buildSnapshotRiskState(
        address account,
        CfdTypes.Position memory pos,
        uint256 terminalReachableUsdc
    ) internal view returns (PositionRiskAccountingLib.PositionRiskState memory) {
        CfdTypes.RiskParams memory params = _riskParams();
        uint256 pendingCarryUsdc = engineContract.unsettledCarryUsdc(account) + _elapsedCarryUsdc(account, pos);

        return PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            pos,
            engineContract.lastMarkPrice(),
            engineContract.CAP_PRICE(),
            pendingCarryUsdc,
            terminalReachableUsdc,
            engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
        );
    }

    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        (,, pos.lastCarryTimestamp) = engineContract.positionCarryState(account);
    }

    function _elapsedCarryUsdc(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (uint256) {
        if (pos.size == 0) {
            return 0;
        }
        (uint256 borrowBaseUsdc, uint256 startIndex,) = engineContract.positionCarryState(account);
        if (borrowBaseUsdc == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(pos.side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryUsdc(borrowBaseUsdc, endIndex - startIndex);
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
