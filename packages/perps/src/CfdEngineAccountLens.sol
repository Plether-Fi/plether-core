// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineAccountLens} from "@plether/perps/interfaces/ICfdEngineAccountLens.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
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

    /// @notice Returns clearinghouse custody buckets, settlement reachability, and the exact terminal price cap.
    /// @dev `settlementBalanceUsdc` includes locked value; `lockedMarginUsdc` is the sum of all typed locked buckets;
    ///      `closeReachableUsdc` is exactly free settlement, not a complete close-settlement bound; and terminal
    ///      liquidation settlement reachability is `max(settlement balance - router execution-bounty reserve, 0)`.
    ///      That liquidation-only value can include buckets released by liquidation; it is distinct from the exact
    ///      terminal price collectible cap, which is the live position's PnL pledge plus same-account claim clipped to
    ///      its maximum endpoint loss. `accountEquityUsdc` is clearinghouse settlement balance rather than mark-to-market
    ///      equity, while free buying power excludes all locked buckets. This function does not project PnL or carry. If
    ///      no router is configured, it assumes a zero execution-bounty reserve.
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
        viewData.liquidationReachableSettlementUsdc = buckets.settlementBalanceUsdc > executionBountyReserveUsdc
            ? buckets.settlementBalanceUsdc - executionBountyReserveUsdc
            : 0;
        viewData.terminalPriceCollectibleCapUsdc = _terminalPriceCollectibleCapUsdc(account, _position(account));
        viewData.accountEquityUsdc = engineContract.clearinghouse().getAccountEquityUsdc(account);
        viewData.freeBuyingPowerUsdc = engineContract.clearinghouse().getFreeBuyingPowerUsdc(account);
        viewData.traderClaimBalanceUsdc = engineContract.traderClaimBalanceUsdc(account);
    }

    /// @notice Estimates the same-state withdrawal ceiling under the engine's open-position risk policy.
    /// @dev A flat account returns all current free settlement without degraded-mode or mark-freshness gating. For an
    ///      open position, the estimate is zero in degraded mode, with no usable cached mark, after the applicable
    ///      engine/HousePool freshness limit, when exact price-risk equity does not exceed the active requirement, or
    ///      when any carry remains uncovered. The calculation hypothetically consumes stored plus elapsed carry from
    ///      eligible free settlement first. Fully funded carry does not worsen price health; PnL pledge plus same-account
    ///      claim remains exclusive to exact price risk and cannot offset residual carry. The full post-carry free amount
    ///      is withdrawable only when the position clears the stricter of initial margin and the active FAD or maintenance
    ///      requirement. This view does not checkpoint carry.
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

        uint256 pendingCarryUsdc = engineContract.unsettledCarryUsdc(account);
        pendingCarryUsdc += _elapsedCarryUsdc(account, pos);
        if (pendingCarryUsdc > 0) {
            MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
                MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
            if (carryConsumption.uncoveredUsdc != 0) {
                return 0;
            }
            buckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                buckets.settlementBalanceUsdc - carryConsumption.totalConsumedUsdc,
                buckets.activePositionMarginUsdc - carryConsumption.activeMarginConsumedUsdc,
                buckets.otherLockedMarginUsdc,
                0
            );
        }

        withdrawableUsdc = buckets.freeSettlementUsdc;
        if (!_isWithdrawablePositionHealthy(account, pos, buckets.activePositionMarginUsdc, price)) {
            return 0;
        }
        return withdrawableUsdc;
    }

    function _isWithdrawablePositionHealthy(
        address account,
        CfdTypes.Position memory pos,
        uint256 activePositionMarginUsdc,
        uint256 price
    ) private view returns (bool) {
        CfdTypes.RiskParams memory params = _riskParams();
        uint256 currentMarginBps = engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps;
        uint256 effectiveMarginBps = params.initMarginBps > currentMarginBps ? params.initMarginBps : currentMarginBps;
        if (engineContract.clearinghouse().vpiRebateReserveUsdc(account) < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            return false;
        }
        uint256 riskCollateralUsdc = activePositionMarginUsdc + engineContract.traderClaimBalanceUsdc(account);
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            engineContract.positionEntryCostUsdcAtoms(account),
            price,
            engineContract.CAP_PRICE(),
            riskCollateralUsdc,
            effectiveMarginBps
        );
        return !riskState.liquidatable;
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

    /// @notice Returns expanded custody, reservation, and cached-mark solvency state for an account.
    /// @dev Requires a configured ABI-compatible order router. For an open position, risk uses the cached mark without
    ///      freshness validation, exact lot-based entry cost, PnL pledge plus same-account claim, exact price PnL, and the
    ///      active FAD or maintenance requirement. Pending carry is first projected against eligible free settlement: a
    ///      fully funded amount leaves price health unchanged, while any uncovered remainder independently makes the
    ///      account liquidatable and cannot consume pledge or claim. Negative VPI is independently required to have full
    ///      dedicated-reserve backing; underfunding makes the account liquidatable, while excess reserve never adds price
    ///      collateral. The separate terminal-price cap excludes action reserves and clips price collateral to the
    ///      reachable endpoint. A flat account still returns raw ledger values but leaves every position and risk field,
    ///      including net equity, at its zero default. Projecting nonzero borrow-base carry additionally requires a
    ///      compatible pool.
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
        snapshot.liquidationReachableSettlementUsdc =
            MarginClearinghouseAccountingLib.getTerminalReachableUsdc(terminalBuckets);
        snapshot.terminalPriceCollectibleCapUsdc = _terminalPriceCollectibleCapUsdc(account, pos);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(account);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(account);

        if (pos.size == 0) {
            return snapshot;
        }

        PositionRiskAccountingLib.PositionRiskState memory riskState = _buildSnapshotRiskState(account, pos);

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginUsdc;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
    }

    /// @notice Computes account solvency risk at the cached mark without a freshness check.
    /// @param account Account whose exact position basis, dedicated price collateral, and isolated carry are included.
    /// @param pos Current position.
    /// @return state Exact price PnL, P+C price equity, notional, active requirement, and a liquidation flag that
    ///         independently includes any uncovered carry or underfunded negative-VPI reserve.
    function _buildSnapshotRiskState(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (PositionRiskAccountingLib.PositionRiskState memory) {
        CfdTypes.RiskParams memory params = _riskParams();
        uint256 pendingCarryUsdc = engineContract.unsettledCarryUsdc(account) + _elapsedCarryUsdc(account, pos);
        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(
                engineContract.clearinghouse().getAccountUsdcBuckets(account), pendingCarryUsdc
            );
        bool vpiReserveUnderfunded =
            engineContract.clearinghouse().vpiRebateReserveUsdc(account) < _negativeVpiReserveTarget(pos.vpiAccrued);
        uint256 riskCollateralUsdc = pos.margin + engineContract.traderClaimBalanceUsdc(account);

        PositionRiskAccountingLib.PositionRiskState memory state = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            engineContract.positionEntryCostUsdcAtoms(account),
            engineContract.lastMarkPrice(),
            engineContract.CAP_PRICE(),
            riskCollateralUsdc,
            engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
        );
        if (carryConsumption.uncoveredUsdc != 0 || vpiReserveUnderfunded) {
            state.liquidatable = true;
        }
        return state;
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedUsdc
    ) private pure returns (uint256 targetUsdc) {
        if (vpiAccruedUsdc < 0) {
            targetUsdc = uint256(-(vpiAccruedUsdc + 1)) + 1;
        }
    }

    /// @notice Returns the exact account-local cap committed to the terminal price-PnL book.
    /// @dev Claims are included only for a live position and unreachable collateral is clipped at the side endpoint.
    function _terminalPriceCollectibleCapUsdc(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (uint256 effectiveCapUsdc) {
        if (pos.size == 0) {
            return 0;
        }

        uint256 lots = CfdMath.sizeToLots(pos.size);
        uint256 entryCostUsdcAtoms = engineContract.positionEntryCostUsdcAtoms(account);
        uint256 maximumCollectibleUsdc = pos.side == CfdTypes.Side.BULL
            ? lots * engineContract.CAP_PRICE() - entryCostUsdcAtoms
            : entryCostUsdcAtoms;
        uint256 candidateCapUsdc =
            engineContract.clearinghouse().pnlPledgeUsdc(account) + engineContract.traderClaimBalanceUsdc(account);
        effectiveCapUsdc = candidateCapUsdc < maximumCollectibleUsdc ? candidateCapUsdc : maximumCollectibleUsdc;
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
        (,,,,, uint256 baseCarryBps,,,,) = engineContract.riskParams();
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
        params = ICfdEngineRiskParamsView(address(engineContract)).riskParams();
    }

}
