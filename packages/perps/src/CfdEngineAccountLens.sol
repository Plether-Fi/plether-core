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
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {OrderSettlementFloorLib} from "@plether/perps/libraries/OrderSettlementFloorLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @title CfdEngineAccountLens
/// @notice Rich per-account diagnostic lens for audits, tests, and operator tooling.
/// @dev This permissionless lens is intentionally wider than the product-facing `PerpsPublicLens` surface. It reads
///      cached engine and dependency state only: it does not fetch an oracle update, refresh the mark, checkpoint carry,
///      or mutate account state. Unless stated otherwise, settlement token amounts use 6 decimals, prices use 8 decimals, sizes use
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
    /// @dev `settlementBalanceAssets` includes locked value; `lockedMarginAssets` is the sum of all typed locked buckets;
    ///      `closeReachableAssets` is exactly free settlement, not a complete close-settlement bound; and terminal
    ///      liquidation settlement reachability is `max(settlement balance - router execution-bounty reserve, 0)`.
    ///      That liquidation-only value can include buckets released by liquidation; it is distinct from the exact
    ///      terminal price collectible cap, which is the live position's PnL pledge plus same-account claim clipped to
    ///      its maximum endpoint loss. `accountEquityAssets` is clearinghouse settlement balance rather than mark-to-market
    ///      equity, while free buying power excludes all locked buckets. This function does not project PnL or carry.
    ///      The execution-bounty reserve is read directly from the clearinghouse.
    /// @param account Clearinghouse account to inspect.
    /// @return viewData Current custody and claim values; every monetary field uses 6-decimal settlement token units.
    function getAccountCollateralView(
        address account
    ) external view returns (ICfdEngineTypes.AccountCollateralView memory viewData) {
        IMarginClearinghouse.AccountAssetBuckets memory buckets =
            engineContract.clearinghouse().getAccountAssetBuckets(account);
        viewData.settlementBalanceAssets = buckets.settlementBalanceAssets;
        viewData.lockedMarginAssets = buckets.totalLockedMarginAssets;
        viewData.activePositionMarginAssets = buckets.activePositionMarginAssets;
        viewData.otherLockedMarginAssets = buckets.otherLockedMarginAssets;
        viewData.freeSettlementAssets = buckets.freeSettlementAssets;
        viewData.closeReachableAssets = buckets.freeSettlementAssets;
        uint256 executionBountyReserveAssets = engineContract.clearinghouse().totalBountyReservationsAssets(account);
        viewData.liquidationReachableSettlementAssets = buckets.settlementBalanceAssets > executionBountyReserveAssets
            ? buckets.settlementBalanceAssets - executionBountyReserveAssets
            : 0;
        viewData.terminalPriceCollectibleCapAssets = _terminalPriceCollectibleCapAssets(account, _position(account));
        viewData.accountEquityAssets = buckets.settlementBalanceAssets;
        viewData.freeBuyingPowerAssets = buckets.freeSettlementAssets;
        viewData.traderClaimBalanceAssets = engineContract.traderClaimBalanceAssets(account);
    }

    /// @notice Estimates the same-state withdrawal ceiling under the engine's open-position risk policy.
    /// @dev A flat account returns free settlement above any pending funded floor, without degraded-mode or freshness
    ///      gating. For an
    ///      open position, the estimate is zero in degraded mode, with no usable cached mark, after the applicable
    ///      engine/HousePool freshness limit, when exact price-risk equity does not exceed the active requirement, or
    ///      when any carry remains uncovered, or when the negative-VPI reserve is underfunded. The calculation
    ///      hypothetically consumes stored plus elapsed carry from
    ///      active position margin first, then free settlement. Price health uses the reduced pledge plus same-account
    ///      claim. Claims and other reserves cannot pay residual carry. The full post-carry free amount
    ///      is withdrawable only when the position clears the stricter of initial margin and the active FAD or maintenance
    ///      requirement. This view does not checkpoint carry.
    /// @param account Clearinghouse account to inspect.
    /// @return withdrawableAssets Estimated upper bound in 6-decimal settlement token units.
    function getWithdrawableAssets(
        address account
    ) external view returns (uint256 withdrawableAssets) {
        IMarginClearinghouse.AccountAssetBuckets memory buckets =
            engineContract.clearinghouse().getAccountAssetBuckets(account);
        withdrawableAssets = buckets.freeSettlementAssets;

        CfdTypes.Position memory pos = _position(account);
        if (pos.size == 0) {
            (, uint256 minimum, uint256 maxDebit) = OrderSettlementFloorLib.load(engineContract.orderRouter(), account);
            if (minimum != 0) {
                uint256 balance = buckets.settlementBalanceAssets;
                if (balance < minimum || balance - minimum < maxDebit) {
                    return 0;
                }
                uint256 surplus = balance - minimum - maxDebit;
                if (surplus < withdrawableAssets) {
                    withdrawableAssets = surplus;
                }
            }
            return withdrawableAssets;
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
        if (!HousePoolAccountingLib.isMarkFresh(lastMarkTime, maxStaleness, block.timestamp)) {
            return 0;
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption;
        (carryConsumption, buckets) = _projectAccountCarry(account, pos, buckets);
        if (carryConsumption.uncoveredAssets != 0) {
            return 0;
        }

        withdrawableAssets = buckets.freeSettlementAssets;
        if (!_isWithdrawablePositionHealthy(account, pos, buckets.activePositionMarginAssets, price)) {
            return 0;
        }
        return withdrawableAssets;
    }

    function _isWithdrawablePositionHealthy(
        address account,
        CfdTypes.Position memory pos,
        uint256 activePositionMarginAssets,
        uint256 price
    ) private view returns (bool) {
        CfdTypes.RiskParams memory params = _riskParams();
        uint256 currentMarginBps = engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps;
        uint256 effectiveMarginBps = params.initMarginBps > currentMarginBps ? params.initMarginBps : currentMarginBps;
        if (engineContract.clearinghouse().vpiRebateReserveAssets(account) < _negativeVpiReserveTarget(pos.vpiAccrued))
        {
            return false;
        }
        uint256 riskCollateralAssets = activePositionMarginAssets + engineContract.traderClaimBalanceAssets(account);
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            engineContract.positionEntryCostAssetAtoms(account),
            price,
            engineContract.CAP_PRICE(),
            riskCollateralAssets,
            effectiveMarginBps
        );
        return !riskState.liquidatable;
    }

    /// @notice Returns a compact projection of the expanded account ledger snapshot.
    /// @dev The function still builds the full cached-mark risk snapshot before discarding its position fields. It
    ///      therefore requires a configured ABI-compatible order router and, when nonzero borrow-base carry must be
    ///      projected for an open position, a compatible pool.
    /// @param account Clearinghouse account to inspect.
    /// @return viewData Custody, router reservation, claim, and pending-order values; monetary fields use 6-decimal settlement token.
    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(account);
        viewData.settlementBalanceAssets = snapshot.settlementBalanceAssets;
        viewData.freeSettlementAssets = snapshot.freeSettlementAssets;
        viewData.activePositionMarginAssets = snapshot.activePositionMarginAssets;
        viewData.otherLockedMarginAssets = snapshot.otherLockedMarginAssets;
        viewData.executionBountyReserveAssets = snapshot.executionBountyReserveAssets;
        viewData.committedMarginAssets = snapshot.committedMarginAssets;
        viewData.traderClaimBalanceAssets = snapshot.traderClaimBalanceAssets;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    /// @notice Returns expanded custody, reservation, and cached-mark solvency state for an account.
    /// @dev Requires a configured ABI-compatible order router. For an open position, risk uses the cached mark without
    ///      freshness validation, exact lot-based entry cost, PnL pledge plus same-account claim, exact price PnL, and the
    ///      active FAD or maintenance requirement. Pending carry consumes projected margin first, then free settlement.
    ///      Price health uses the reduced pledge; any carry uncovered by both sources independently sets the
    ///      diagnostic liquidatable flag and cannot consume claims or other reserves. Negative VPI independently
    ///      requires full dedicated-reserve backing; underfunding also sets that flag, but the liquidation planner
    ///      rejects an underfunded snapshot before returning a settlement plan. Excess reserve never adds price
    ///      collateral. The separate terminal-price cap excludes action reserves and clips price collateral to the
    ///      reachable endpoint. A flat account still returns raw ledger values but leaves every position and risk field,
    ///      including net equity, at its zero default. Projecting nonzero borrow-base carry additionally requires a
    ///      compatible pool.
    /// @param account Clearinghouse account to inspect.
    /// @return snapshot Expanded account snapshot; settlement token values use 6 decimals, size 18, and entry price 8.
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
        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation =
            IOrderRouterAccounting(engineContract.orderRouter()).getAccountReservations(account);

        snapshot.settlementBalanceAssets = buckets.settlementBalanceAssets;
        snapshot.freeSettlementAssets = buckets.freeSettlementAssets;
        snapshot.activePositionMarginAssets = buckets.activePositionMarginAssets;
        snapshot.otherLockedMarginAssets = buckets.otherLockedMarginAssets;
        snapshot.positionMarginBucketAssets = lockedBuckets.positionMarginAssets;
        snapshot.committedOrderMarginBucketAssets = lockedBuckets.committedOrderMarginAssets;
        snapshot.reservedSettlementBucketAssets = lockedBuckets.reservedSettlementAssets;
        snapshot.executionBountyReserveAssets = reservation.executionBountyAssets;
        snapshot.committedMarginAssets = reservation.committedMarginAssets;
        snapshot.traderClaimBalanceAssets = engineContract.traderClaimBalanceAssets(account);
        snapshot.pendingOrderCount = reservation.pendingOrderCount;
        snapshot.closeReachableAssets = buckets.freeSettlementAssets;
        uint256 reservationExcludedSettlementAssets = buckets.settlementBalanceAssets
            > reservation.executionBountyAssets
            ? buckets.settlementBalanceAssets - reservation.executionBountyAssets
            : 0;
        IMarginClearinghouse.AccountAssetBuckets memory terminalBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: reservationExcludedSettlementAssets,
            totalLockedMarginAssets: buckets.totalLockedMarginAssets,
            activePositionMarginAssets: buckets.activePositionMarginAssets,
            otherLockedMarginAssets: buckets.otherLockedMarginAssets,
            freeSettlementAssets: buckets.freeSettlementAssets
        });
        snapshot.liquidationReachableSettlementAssets =
            MarginClearinghouseAccountingLib.getTerminalReachableAssets(terminalBuckets);
        snapshot.terminalPriceCollectibleCapAssets = _terminalPriceCollectibleCapAssets(account, pos);
        snapshot.accountEquityAssets = buckets.settlementBalanceAssets;
        snapshot.freeBuyingPowerAssets = buckets.freeSettlementAssets;

        if (pos.size == 0) {
            return snapshot;
        }

        PositionRiskAccountingLib.PositionRiskState memory riskState = _buildSnapshotRiskState(account, pos, buckets);

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = lockedBuckets.positionMarginAssets;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlAssets = riskState.unrealizedPnlAssets;
        snapshot.netEquityAssets = riskState.equityAssets;
        snapshot.liquidatable = riskState.liquidatable;
    }

    /// @notice Computes account solvency risk at the cached mark without a freshness check.
    /// @param account Account whose exact position basis, dedicated price collateral, and isolated carry are included.
    /// @param pos Current position.
    /// @param buckets Already-loaded canonical custody snapshot; kept unchanged for ledger diagnostics.
    /// @return state Exact price PnL, P+C price equity, notional, active requirement, and a diagnostic liquidation
    ///         flag that includes uncovered carry or underfunded negative-VPI reserve. The liquidation planner
    ///         rejects an underfunded VPI reserve rather than executing it.
    function _buildSnapshotRiskState(
        address account,
        CfdTypes.Position memory pos,
        IMarginClearinghouse.AccountAssetBuckets memory buckets
    ) internal view returns (PositionRiskAccountingLib.PositionRiskState memory) {
        CfdTypes.RiskParams memory params = _riskParams();
        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption;
        (carryConsumption, buckets) = _projectAccountCarry(account, pos, buckets);
        bool vpiReserveUnderfunded =
            engineContract.clearinghouse().vpiRebateReserveAssets(account) < _negativeVpiReserveTarget(pos.vpiAccrued);
        uint256 riskCollateralAssets =
            buckets.activePositionMarginAssets + engineContract.traderClaimBalanceAssets(account);

        PositionRiskAccountingLib.PositionRiskState memory state = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            engineContract.positionEntryCostAssetAtoms(account),
            engineContract.lastMarkPrice(),
            engineContract.CAP_PRICE(),
            riskCollateralAssets,
            engineContract.isFadWindow() ? params.fadMarginBps : params.maintMarginBps
        );
        if (carryConsumption.uncoveredAssets != 0 || vpiReserveUnderfunded) {
            state.liquidatable = true;
        }
        return state;
    }

    /// @dev Projects stored and newly indexed carry from the supplied raw buckets without changing ledger fields.
    function _projectAccountCarry(
        address account,
        CfdTypes.Position memory pos,
        IMarginClearinghouse.AccountAssetBuckets memory buckets
    )
        private
        view
        returns (
            MarginClearinghouseAccountingLib.SettlementConsumption memory consumption,
            IMarginClearinghouse.AccountAssetBuckets memory afterBuckets
        )
    {
        return MarginClearinghouseAccountingLib.projectCarryLoss(
            buckets, engineContract.unsettledCarryAssets(account) + _elapsedCarryAssets(account, pos)
        );
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedAssets
    ) private pure returns (uint256 targetAssets) {
        if (vpiAccruedAssets < 0) {
            targetAssets = uint256(-(vpiAccruedAssets + 1)) + 1;
        }
    }

    /// @notice Returns the exact account-local cap committed to the terminal price-PnL book.
    /// @dev Only the PnL pledge and same-account claim contribute for a live position. The cap is clipped at the
    ///      side endpoint; action reserves and zero-bounty close records do not add price-loss backing.
    function _terminalPriceCollectibleCapAssets(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (uint256 effectiveCapAssets) {
        if (pos.size == 0) {
            return 0;
        }

        uint256 lots = CfdMath.sizeToLots(pos.size);
        uint256 entryCostAssetAtoms = engineContract.positionEntryCostAssetAtoms(account);
        uint256 maximumCollectibleAssets = pos.side == CfdTypes.Side.LONG
            ? lots * engineContract.CAP_PRICE() - entryCostAssetAtoms
            : entryCostAssetAtoms;
        IMarginClearinghouse clearinghouse = engineContract.clearinghouse();
        uint256 candidateCapAssets =
            clearinghouse.pnlPledgeAssets(account) + engineContract.traderClaimBalanceAssets(account);
        effectiveCapAssets =
            candidateCapAssets < maximumCollectibleAssets ? candidateCapAssets : maximumCollectibleAssets;
    }

    /// @notice Reconstructs the current position plus its separately stored carry timestamp.
    /// @param account Account whose position is loaded.
    /// @return pos Current engine position.
    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitAssets, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        (,, pos.lastCarryTimestamp) = engineContract.positionCarryState(account);
    }

    /// @notice Computes indexed carry accrued since the position's last side-index checkpoint.
    /// @dev This excludes carry already stored in `unsettledCarryAssets`.
    /// @param account Account whose carry basis is loaded.
    /// @param pos Current position, used to select the side index.
    /// @return Elapsed carry in 6-decimal settlement token units.
    function _elapsedCarryAssets(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (uint256) {
        if (pos.size == 0) {
            return 0;
        }
        (uint256 borrowBaseAssets, uint256 startIndex,) = engineContract.positionCarryState(account);
        if (borrowBaseAssets == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(pos.side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryAssets(borrowBaseAssets, endIndex - startIndex);
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
            engineContract.sideBorrowBaseAssets(sideIndex),
            PositionRiskAccountingLib.computeNetPoolDepthAssets(
                engineContract.pool().totalAssets(), engineContract.totalTraderClaimBalanceAssets()
            ),
            baseCarryBps
        );
    }

    /// @notice Reconstructs the engine's current risk-parameter struct from its public tuple getter.
    /// @return params Current risk, VPI, carry, margin, and bounty settings.
    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        params = ICfdEngineRiskParamsView(address(engineContract)).riskParams();
    }

}
