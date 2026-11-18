// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineProtocolLens} from "@plether/perps/interfaces/ICfdEngineProtocolLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
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
    ///      trader claims, settlement buffer, and pending-open capacity. Free settlement token is pool assets above the reserve, and
    ///      effective solvency assets are pool assets net of trader claims. Net physical assets equal canonical pool
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
    ///      queued opening exposure and the settlement buffer from LP withdrawals without changing terminal NAV.
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
        (uint256 pendingLong, uint256 pendingShort) = _unexpiredOpenLots();
        if (pendingLong == 0 && pendingShort == 0) {
            return SolvencyAccountingLib.settlementBufferTargetAssets(liveMaxLiability, bufferBps);
        }

        uint256 capPrice = engineContract.CAP_PRICE();
        (uint256 longLiability, uint256 longSize,,) = engineContract.sides(uint8(CfdTypes.Side.LONG));
        (uint256 shortLiability, uint256 shortSize,,) = engineContract.sides(uint8(CfdTypes.Side.SHORT));
        uint256 projectedLiability = SolvencyAccountingLib.getMaxLiability(
            longLiability + pendingLong * capPrice, shortLiability + pendingShort * capPrice
        );
        uint256 liabilityFloor =
            projectedLiability + SolvencyAccountingLib.settlementBufferTargetAssets(projectedLiability, bufferBps);

        uint256 longLots = longSize / CfdTypes.SIZE_QUANTUM;
        uint256 shortLots = shortSize / CfdTypes.SIZE_QUANTUM;
        uint256 worstLongSkew = Math.saturatingSub(longLots + pendingLong, shortLots) * capPrice;
        uint256 worstShortSkew = Math.saturatingSub(shortLots + pendingShort, longLots) * capPrice;
        // A lighter-side open that reduces skew can still execute above the cap. Reserve depth for each pending
        // side that could finish heavier, without assuming that intervening opens on the other side will fill.
        uint256 cappedSkew = Math.max(pendingLong == 0 ? 0 : worstLongSkew, pendingShort == 0 ? 0 : worstShortSkew);
        (uint256 vpiFactor, uint256 maxSkewRatio,,,,,,,,) = engineContract.riskParams();
        uint256 skewDepth;
        if (maxSkewRatio != 0) {
            skewDepth = cappedSkew > Math.mulDiv(poolAssets, maxSkewRatio, CfdMath.WAD)
                ? poolAssets
                : Math.mulDiv(cappedSkew, CfdMath.WAD, maxSkewRatio, Math.Rounding.Ceil);
        }

        uint256 requiredDepth = Math.max(liabilityFloor, skewDepth);
        if (vpiFactor != 0 && requiredDepth < poolAssets) {
            // A negative VPI cannot exceed the entire pre-open skew cost. That cost decreases with depth.
            (bool valid, uint256 maxRebate) =
                CfdMath.tryGetSkewCost(Math.max(worstLongSkew, worstShortSkew), requiredDepth, vpiFactor);
            requiredDepth = valid ? Math.saturatingAdd(requiredDepth, maxRebate) : poolAssets;
        }
        return Math.min(requiredDepth, Math.max(liabilityFloor, poolAssets)) - liveMaxLiability;
    }

    function _unexpiredOpenLots() private view returns (uint256, uint256) {
        address router = engineContract.orderRouter();
        if (router.code.length == 0) {
            return (0, 0);
        }
        // The production router binds its book at construction. Direct engine integrations may have no order queue.
        try IOrderRouterExecutionHost(router).lifecycleBook() returns (address boundBook) {
            return OrderLifecycleBook(boundBook).unexpiredOpenLots();
        } catch {
            return (0, 0);
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
        snapshot.withdrawalReservedAssets =
            solvencyState.withdrawalReservedAssets + _withdrawalSupplement(maxLiabilityAssets, poolAssets);
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
