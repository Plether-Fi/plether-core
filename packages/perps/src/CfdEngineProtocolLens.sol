// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineProtocolLens} from "@plether/perps/interfaces/ICfdEngineProtocolLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @title CfdEngineProtocolLens
/// @notice Rich protocol-accounting lens for audits, tests, and HousePool integration.
/// @dev This permissionless, read-only lens exposes conservative solvency and liability views rather than product-level
///      summaries. It reads cached state and never refreshes a mark or mutates the engine. Unless stated otherwise,
///      monetary fields use 6-decimal settlement token, prices use 8 decimals, and timestamps/durations use seconds. Dependency
///      reverts and ABI-decoding failures are propagated.
contract CfdEngineProtocolLens is ICfdEngineProtocolLens {

    /// @notice Engine instance permanently inspected by this lens.
    CfdEngine public immutable engineContract;

    /// @notice Binds the lens to one engine instance.
    /// @dev Performs no zero-address, code-size, or interface validation. Invalid bindings can deploy successfully but
    ///      cause later reads to revert.
    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @notice Returns the canonical protocol accounting and solvency snapshot.
    /// @dev Maximum liability is the larger side maximum-profit envelope. Withdrawal reserve is that liability plus all
    ///      trader claims, refundable positive lifetime VPI, the liability-scaled settlement buffer, and pending-open
    ///      capacity. Free settlement token is pool assets above that reserve; effective solvency assets are pool assets
    ///      net of trader claims. Net physical assets equal canonical pool
    ///      assets: treasury clearinghouse balances are separate custody and are reported without subtracting them.
    ///      `hasLiveLiability` follows nonzero side maximum-profit envelopes rather than raw open interest.
    /// @return snapshot Protocol-level accounting, liability, claim, and degraded-mode values in 6-decimal settlement token units.
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    /// @notice Builds the engine-side snapshot consumed by HousePool accounting.
    /// @dev Physical and net physical assets are current pool `totalAssets`; treasury clearinghouse balances are
    ///      outside pool custody. Terminal delta, claims, maximum directional liability, open-position
    ///      status, and book version come from one authenticated Engine snapshot. The supplemental reserve protects
    ///      queued opening exposure and the liability-scaled settlement buffer from LP withdrawals without changing
    ///      terminal NAV. A separately authenticated VPI snapshot supplies refundable pool cash and collectible
    ///      clearinghouse backing for LP NAV.
    ///      Mark freshness is required whenever terminal price exposure exists. When gating is required,
    ///      frozen-market policy uses `fadMaxStaleness`; live policy uses the tighter nonzero engine/pool limit. This
    ///      function selects a limit but does not itself test the cached mark's age.
    /// @param markStalenessLimit HousePool live-mark age limit in seconds; zero delegates to the engine limit.
    /// @return snapshot Engine inputs for HousePool reconcile, deposit, and withdrawal calculations.
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot) {
        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engineContract.terminalNavSnapshot();
        uint256 poolAssets = engineContract.pool().totalAssets();
        snapshot.physicalAssets = poolAssets;
        snapshot.netPhysicalAssets = poolAssets;
        snapshot.maxLiabilityAssets = terminalSnapshot.maxDirectionalLiabilityAssets;
        snapshot.supplementalReservedAssets = _withdrawalSupplement(snapshot.maxLiabilityAssets, poolAssets);
        snapshot.terminalLpPriceDeltaAssets = terminalSnapshot.terminalLpPriceDeltaAssets;
        snapshot.terminalNavBookVersion = terminalSnapshot.bookVersion;
        snapshot.traderClaimBalanceAssets = terminalSnapshot.totalTraderClaimsAssets;
        (snapshot.totalPositiveVpiAccruedAssets, snapshot.totalNegativeVpiAccruedAssets) =
            engineContract.vpiAccountingSnapshot();
        snapshot.hasOpenPositions = terminalSnapshot.hasOpenPositions;
        snapshot.markFreshnessRequired = terminalSnapshot.hasOpenPositions;
        if (snapshot.markFreshnessRequired) {
            snapshot.maxMarkStaleness =
            OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.PoolReconcile,
                engineContract.isOracleFrozen(),
                engineContract.isFadWindow(),
                engineContract.engineMarkStalenessLimit(),
                markStalenessLimit,
                0,
                0,
                engineContract.fadMaxStaleness()
            )
            .maxStaleness;
        }
    }

    /// @dev Holds capacity for pending opens only in the LP budget. The cap price bounds each lot's liability and
    ///      skew contribution before its first eligible oracle update is known.
    function _withdrawalSupplement(
        uint256 liveMaxLiability,
        uint256 poolAssets
    ) private view returns (uint256) {
        uint256 bufferBps = engineContract.settlementBufferBps();
        IOrderLifecycleBook book = _lifecycleBook();
        (uint256 pendingLong, uint256 pendingShort) =
            address(book) == address(0) ? (uint256(0), uint256(0)) : book.unexpiredOpenLots();
        if (pendingLong == 0 && pendingShort == 0) {
            return SolvencyAccountingLib.settlementBufferTargetAssets(liveMaxLiability, bufferBps);
        }

        uint256 liabilityFloor;
        uint256 worstLongSkew;
        uint256 worstShortSkew;
        {
            uint256 capPrice = engineContract.CAP_PRICE();
            (uint256 longLiability, uint256 longSize,,) = engineContract.sides(uint8(CfdTypes.Side.LONG));
            (uint256 shortLiability, uint256 shortSize,,) = engineContract.sides(uint8(CfdTypes.Side.SHORT));
            uint256 projectedLiability = SolvencyAccountingLib.getMaxLiability(
                longLiability + pendingLong * capPrice, shortLiability + pendingShort * capPrice
            );
            liabilityFloor =
                projectedLiability + SolvencyAccountingLib.settlementBufferTargetAssets(projectedLiability, bufferBps);
            if (liabilityFloor >= poolAssets) {
                return liabilityFloor - liveMaxLiability;
            }

            (worstLongSkew, worstShortSkew) =
                _projectedSkew(book, longSize, shortSize, pendingLong, pendingShort, capPrice);
        }
        uint256 vpiFactor;
        uint256 requiredDepth = liabilityFloor;
        {
            // Only orders that could finish on the heavier side need depth for the skew limit.
            uint256 cappedSkew = Math.max(pendingLong == 0 ? 0 : worstLongSkew, pendingShort == 0 ? 0 : worstShortSkew);
            uint256 maxSkewRatio;
            (vpiFactor, maxSkewRatio,,,,,,,,) = engineContract.riskParams();
            if (maxSkewRatio != 0) {
                uint256 skewDepth = cappedSkew > Math.mulDiv(poolAssets, maxSkewRatio, CfdMath.WAD)
                    ? poolAssets
                    : Math.mulDiv(cappedSkew, CfdMath.WAD, maxSkewRatio, Math.Rounding.Ceil);
                requiredDepth = Math.max(requiredDepth, skewDepth);
            }
        }
        if (vpiFactor != 0 && requiredDepth < poolAssets) {
            // A negative VPI cannot exceed the entire pre-open skew cost. That cost decreases with depth.
            uint256 rebateSkew = Math.max(pendingShort == 0 ? 0 : worstLongSkew, pendingLong == 0 ? 0 : worstShortSkew);
            (bool valid, uint256 maxRebate) = CfdMath.tryGetSkewCost(rebateSkew, requiredDepth, vpiFactor);
            requiredDepth = valid ? Math.saturatingAdd(requiredDepth, maxRebate) : poolAssets;
        }
        return Math.min(requiredDepth, poolAssets) - liveMaxLiability;
    }

    function _projectedSkew(
        IOrderLifecycleBook book,
        uint256 longSize,
        uint256 shortSize,
        uint256 pendingLong,
        uint256 pendingShort,
        uint256 capPrice
    ) private view returns (uint256 longSkew, uint256 shortSkew) {
        (uint256 closingLong, uint256 closingShort) = book.unexpiredCloseLots();
        uint256 longLots = longSize / CfdTypes.SIZE_QUANTUM;
        uint256 shortLots = shortSize / CfdTypes.SIZE_QUANTUM;
        // Opposing interest may close ahead of an open. Credit only the live lots that queued closes cannot remove.
        longSkew = Math.saturatingSub(longLots + pendingLong, Math.saturatingSub(shortLots, closingShort)) * capPrice;
        shortSkew = Math.saturatingSub(shortLots + pendingShort, Math.saturatingSub(longLots, closingLong)) * capPrice;
    }

    function _lifecycleBook() private view returns (IOrderLifecycleBook) {
        address router = engineContract.orderRouter();
        if (router.code.length == 0) {
            return IOrderLifecycleBook(address(0));
        }
        // The production router binds its book at construction. Direct engine integrations may have no order queue.
        try IOrderRouterExecutionHost(router).lifecycleBook() returns (address boundBook) {
            return IOrderLifecycleBook(boundBook);
        } catch {
            return IOrderLifecycleBook(address(0));
        }
    }

    /// @notice Returns cached-mark time and current runtime mode flags used by HousePool.
    /// @return snapshot Latest mark publish time plus oracle-frozen and degraded-mode flags.
    function getHousePoolStatusSnapshot()
        external
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot)
    {
        snapshot.lastMarkTime = engineContract.lastMarkTime();
        snapshot.oracleFrozen = engineContract.isOracleFrozen();
        snapshot.degradedMode = engineContract.degradedMode();
    }

    /// @notice Returns physical cash above current engine reserves and the caller's additional pool reservation.
    /// @dev Uses live aggregate getters rather than authenticated terminal/VPI snapshots so HousePool can query this
    ///      during engine settlement. Negative lifetime-VPI backing is clearinghouse custody, not available pool cash.
    ///      This diagnostic does not apply HousePool's zero-principal protocol-fee policy.
    /// @param reservedPoolAssets Pending claimant and unassigned assets additionally reserved by HousePool.
    /// @return Unreserved settlement-token cash in six-decimal units.
    function getSettlementFreeAssets(
        uint256 reservedPoolAssets
    ) external view override returns (uint256) {
        (uint256 longMaxProfitAssets,,,) = engineContract.sides(0);
        (uint256 shortMaxProfitAssets,,,) = engineContract.sides(1);
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot;
        snapshot.physicalAssets = engineContract.pool().totalAssets();
        snapshot.maxLiabilityAssets = SolvencyAccountingLib.getMaxLiability(longMaxProfitAssets, shortMaxProfitAssets);
        snapshot.traderClaimBalanceAssets = engineContract.totalTraderClaimBalanceAssets();
        snapshot.totalPositiveVpiAccruedAssets = engineContract.totalPositiveVpiAccruedAssets();
        snapshot.supplementalReservedAssets = reservedPoolAssets
            + SolvencyAccountingLib.settlementBufferTargetAssets(
                snapshot.maxLiabilityAssets, engineContract.settlementBufferBps()
            );
        return HousePoolAccountingLib.buildWithdrawalSnapshot(snapshot).freeAssets;
    }

    /// @notice Assembles protocol accounting from pool, clearinghouse, side, claim, and engine status state.
    /// @return snapshot Canonical diagnostic accounting snapshot.
    function _buildProtocolAccountingSnapshot()
        internal
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        uint256 poolAssets = engineContract.pool().totalAssets();
        uint256 protocolTreasuryBalanceAssets =
            engineContract.clearinghouse().balanceAssets(engineContract.protocolTreasury());
        ICfdEngineTypes.SideState memory longState = _sideState(CfdTypes.Side.LONG);
        ICfdEngineTypes.SideState memory shortState = _sideState(CfdTypes.Side.SHORT);
        uint256 maxLiabilityAssets =
            SolvencyAccountingLib.getMaxLiability(longState.maxProfitAssets, shortState.maxProfitAssets);
        uint256 totalTraderClaimBalanceAssets = engineContract.totalTraderClaimBalanceAssets();
        SolvencyAccountingLib.SolvencyState memory solvencyState =
            SolvencyAccountingLib.buildSolvencyState(poolAssets, maxLiabilityAssets, totalTraderClaimBalanceAssets);
        snapshot.poolAssets = poolAssets;
        snapshot.netPhysicalAssets = solvencyState.netPhysicalAssets;
        snapshot.maxLiabilityAssets = maxLiabilityAssets;
        snapshot.effectiveSolvencyAssets = solvencyState.effectiveAssets;
        (uint256 positiveVpiAssets,) = engineContract.vpiAccountingSnapshot();
        snapshot.withdrawalReservedAssets = solvencyState.withdrawalReservedAssets
            + _withdrawalSupplement(maxLiabilityAssets, poolAssets) + positiveVpiAssets;
        snapshot.freeAssets =
            poolAssets > snapshot.withdrawalReservedAssets ? poolAssets - snapshot.withdrawalReservedAssets : 0;
        snapshot.protocolTreasuryBalanceAssets = protocolTreasuryBalanceAssets;
        snapshot.totalTraderClaimBalanceAssets = totalTraderClaimBalanceAssets;
        snapshot.degradedMode = engineContract.degradedMode();
        snapshot.hasLiveLiability = longState.maxProfitAssets + shortState.maxProfitAssets > 0;
    }

    /// @notice Reconstructs one aggregate side-state tuple from the engine getter.
    /// @param side Side to inspect.
    /// @return state Maximum profit and aggregate margin in 6-decimal settlement token, open interest with 18 decimals, and raw
    ///         exact entry cost scaled by `1e20`, with 26-decimal precision.
    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngineTypes.SideState memory state) {
        (state.maxProfitAssets, state.openInterest, state.entryNotional, state.totalMargin) =
            engineContract.sides(uint8(side));
    }

}
