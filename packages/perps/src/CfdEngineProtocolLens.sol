// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineProtocolLens} from "@plether/perps/interfaces/ICfdEngineProtocolLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
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
    ///      trader claims and the liability-scaled settlement buffer; free settlement token is pool assets above the reserve; and
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
    ///      status, and book version come from one authenticated Engine snapshot. The supplemental reserve is the
    ///      liability-scaled settlement buffer and affects withdrawals without changing terminal NAV.
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
        snapshot.supplementalReservedAssets = SolvencyAccountingLib.settlementBufferTargetAssets(
            snapshot.maxLiabilityAssets, engineContract.settlementBufferBps()
        );
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
        uint256 settlementBufferAssets = SolvencyAccountingLib.settlementBufferTargetAssets(
            maxLiabilityAssets, engineContract.settlementBufferBps()
        );
        snapshot.withdrawalReservedAssets = solvencyState.withdrawalReservedAssets + settlementBufferAssets;
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
