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
/// @dev This permissionless lens is intentionally wider than the product-facing `PerpsPublicLens` surface. It reads
///      cached engine and dependency state only: it does not fetch an oracle update, refresh the mark, checkpoint carry,
///      or mutate account state. Unless stated otherwise, USDC amounts use 6 decimals, prices use 8 decimals, sizes use
///      18 decimals, basis-point values use a 10,000 denominator, and timestamps are Unix seconds. Dependency reverts
///      and ABI-decoding failures are propagated.
contract CfdEngineAccountLens is ICfdEngineAccountLens {

    /// @notice Engine instance permanently inspected by this lens.
    CfdEngine public immutable engineContract;

    /// @notice Binds the lens to one engine instance.
    /// @dev Performs no zero-address, code-size, or interface validation. An invalid engine or invalid engine dependency
    ///      can therefore deploy successfully but cause later reads to revert.
    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @notice Returns clearinghouse custody buckets, legacy reachability values, and claims for an account.
    /// @dev `settlementBalanceUsdc` includes locked value; `lockedMarginUsdc` is the sum of all typed locked buckets;
    ///      `closeReachableUsdc` is exactly free settlement, not a complete close-settlement bound; and terminal
    ///      reachability is `max(settlement balance - router execution-bounty reserve, 0)`. Terminal reachability can
    ///      include locked value released by terminal settlement but excludes trader claims. `accountEquityUsdc` is the
    ///      clearinghouse settlement balance rather than mark-to-market equity, while free buying power excludes all
    ///      locked buckets. This function does not project PnL or carry. If no router is configured, it assumes a zero
    ///      execution-bounty reserve.
    /// @param account Clearinghouse account to inspect.
    /// @return viewData Current custody and claim values; every monetary field uses 6-decimal USDC units.
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

    /// @notice Estimates the same-state withdrawal ceiling under the engine's open-position risk policy.
    /// @dev A flat account returns all current free settlement without degraded-mode or mark-freshness gating. For an
    ///      open position, the estimate is zero in degraded mode, with no usable cached mark, after the applicable
    ///      engine/HousePool freshness limit, or when carry-adjusted equity does not exceed the active requirement. The
    ///      calculation hypothetically consumes stored plus elapsed carry from free settlement and then position margin,
    ///      and caps remaining free settlement by equity above the stricter of initial margin and the active FAD or
    ///      maintenance requirement. It does not checkpoint carry. When risk headroom is the binding cap, withdrawing
    ///      exactly the returned amount leaves equity equal to the requirement, while the live guard requires strict
    ///      excess; callers should treat this as an upper bound and request less than the returned amount.
    /// @param account Clearinghouse account to inspect.
    /// @return withdrawableUsdc Estimated upper bound in 6-decimal USDC units.
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

    /// @notice Returns a compact projection of the expanded account ledger snapshot.
    /// @dev The function still builds the full cached-mark risk snapshot before discarding its position fields. It
    ///      therefore requires a configured ABI-compatible order router and, when nonzero borrow-base carry must be
    ///      projected for an open position, a compatible pool.
    /// @param account Clearinghouse account to inspect.
    /// @return viewData Custody, router reservation, claim, and pending-order values; monetary fields use 6-decimal USDC.
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

    /// @notice Returns expanded custody, reservation, and cached-mark terminal-risk state for an account.
    /// @dev Requires a configured ABI-compatible order router. For an open position, risk uses the cached mark without
    ///      freshness validation, terminal collateral excluding the execution-bounty reserve, stored plus elapsed carry,
    ///      and the active FAD or maintenance requirement; initial margin and trader claims are excluded. Unrealized PnL
    ///      itself excludes carry and VPI, while net equity also subtracts pending carry and any negative-VPI clawback.
    ///      A flat account still returns raw ledger values but leaves every position and risk field, including net equity,
    ///      at its zero default. Projecting nonzero borrow-base carry additionally requires a compatible pool.
    /// @param account Clearinghouse account to inspect.
    /// @return snapshot Expanded account snapshot; USDC values use 6 decimals, size 18, and entry price 8.
    function getAccountLedgerSnapshot(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot) {
        return _buildAccountLedgerSnapshot(account);
    }

    /// @notice Builds raw custody fields and, when a position exists, cached-mark terminal risk.
    /// @param account Clearinghouse account to inspect.
    /// @return snapshot Expanded account snapshot assembled from engine, clearinghouse, router, and pool state.
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

    /// @notice Computes terminal account risk at the cached mark without a freshness check.
    /// @param account Account whose stored and elapsed carry is included.
    /// @param pos Current position.
    /// @param terminalReachableUsdc Settlement collateral reachable by terminal settlement, in 6-decimal USDC.
    /// @return state PnL, carry-adjusted equity, notional, active margin requirement, and liquidation flag.
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

    /// @notice Reconstructs the current position plus its separately stored carry timestamp.
    /// @param account Account whose position is loaded.
    /// @return pos Current engine position.
    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        (,, pos.lastCarryTimestamp) = engineContract.positionCarryState(account);
    }

    /// @notice Computes indexed carry accrued since the position's last side-index checkpoint.
    /// @dev This excludes carry already stored in `unsettledCarryUsdc`.
    /// @param account Account whose carry basis is loaded.
    /// @param pos Current position, used to select the side index.
    /// @return Elapsed carry in 6-decimal USDC units.
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

    /// @notice Projects a side's cumulative carry index through the current block timestamp.
    /// @param side Position side whose stored index is projected.
    /// @return Current cumulative carry index, scaled by 1e18.
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

    /// @notice Reconstructs the engine's current risk-parameter struct from its public tuple getter.
    /// @return params Current risk, VPI, carry, margin, and bounty settings.
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
