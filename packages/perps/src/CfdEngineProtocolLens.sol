// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineProtocolLens} from "@plether/perps/interfaces/ICfdEngineProtocolLens.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @title CfdEngineProtocolLens
/// @notice Rich protocol-accounting lens for audits, tests, and HousePool integration.
/// @dev This permissionless, read-only lens exposes conservative solvency and liability views rather than product-level
///      summaries. It reads cached state and never refreshes a mark or mutates the engine. Unless stated otherwise,
///      monetary fields use 6-decimal USDC, prices use 8 decimals, and timestamps/durations use seconds. Dependency
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
    ///      trader claims and the liability-scaled settlement buffer; free USDC is pool assets above the reserve; and
    ///      effective solvency assets are pool assets net of trader claims. The separately reported net physical assets
    ///      subtract the protocol-treasury clearinghouse balance, but that subtraction is not applied to
    ///      `effectiveSolvencyAssetsUsdc`. `hasLiveLiability` follows nonzero side maximum-profit envelopes rather than
    ///      raw open interest.
    /// @return snapshot Protocol-level accounting, liability, claim, and degraded-mode values in 6-decimal USDC units.
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    /// @notice Builds the engine-side snapshot consumed by HousePool accounting.
    /// @dev Physical assets are current pool `totalAssets`; net physical assets subtract the protocol-treasury
    ///      clearinghouse balance with saturation. Terminal delta, claims, maximum directional liability, open-position
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
        uint256 poolAssetsUsdc = engineContract.pool().totalAssets();
        uint256 protocolTreasuryBalanceUsdc =
            engineContract.clearinghouse().balanceUsdc(engineContract.protocolTreasury());
        snapshot.physicalAssetsUsdc = poolAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc =
            poolAssetsUsdc > protocolTreasuryBalanceUsdc ? poolAssetsUsdc - protocolTreasuryBalanceUsdc : 0;
        snapshot.maxLiabilityUsdc = terminalSnapshot.maxDirectionalLiabilityUsdc;
        snapshot.supplementalReservedUsdc = SolvencyAccountingLib.settlementBufferTargetUsdc(
            snapshot.maxLiabilityUsdc, engineContract.settlementBufferBps()
        );
        snapshot.terminalLpPriceDeltaUsdc = terminalSnapshot.terminalLpPriceDeltaUsdc;
        snapshot.terminalNavBookVersion = terminalSnapshot.bookVersion;
        snapshot.traderClaimBalanceUsdc = terminalSnapshot.totalTraderClaimsUsdc;
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
        uint256 poolAssetsUsdc = engineContract.pool().totalAssets();
        uint256 protocolTreasuryBalanceUsdc =
            engineContract.clearinghouse().balanceUsdc(engineContract.protocolTreasury());
        uint256 maxLiabilityUsdc = SolvencyAccountingLib.getMaxLiability(
            _sideState(CfdTypes.Side.LONG).maxProfitUsdc, _sideState(CfdTypes.Side.SHORT).maxProfitUsdc
        );
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.poolAssetsUsdc = poolAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc > protocolTreasuryBalanceUsdc
            ? solvencyState.netPhysicalAssetsUsdc - protocolTreasuryBalanceUsdc
            : 0;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        uint256 settlementBufferUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engineContract.settlementBufferBps());
        snapshot.withdrawalReservedUsdc = solvencyState.withdrawalReservedUsdc + settlementBufferUsdc;
        snapshot.freeUsdc =
            poolAssetsUsdc > snapshot.withdrawalReservedUsdc ? poolAssetsUsdc - snapshot.withdrawalReservedUsdc : 0;
        snapshot.protocolTreasuryBalanceUsdc = protocolTreasuryBalanceUsdc;
        snapshot.totalTraderClaimBalanceUsdc = engineContract.totalTraderClaimBalanceUsdc();
        snapshot.degradedMode = engineContract.degradedMode();
        ICfdEngineTypes.SideState memory longState = _sideState(CfdTypes.Side.LONG);
        ICfdEngineTypes.SideState memory shortState = _sideState(CfdTypes.Side.SHORT);
        snapshot.hasLiveLiability = longState.maxProfitUsdc + shortState.maxProfitUsdc > 0;
    }

    /// @notice Builds solvency from pool assets, maximum side liability, and aggregate trader claims.
    /// @return Current solvency state; protocol treasury is not a separate deduction.
    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            engineContract.pool().totalAssets(),
            SolvencyAccountingLib.getMaxLiability(
                _sideState(CfdTypes.Side.LONG).maxProfitUsdc, _sideState(CfdTypes.Side.SHORT).maxProfitUsdc
            ),
            engineContract.totalTraderClaimBalanceUsdc()
        );
    }

    /// @notice Reconstructs one aggregate side-state tuple from the engine getter.
    /// @param side Side to inspect.
    /// @return state Maximum profit and aggregate margin in 6-decimal USDC, open interest with 18 decimals, and raw
    ///         `size * entryPrice` notional with 26 decimals.
    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngineTypes.SideState memory state) {
        (state.maxProfitUsdc, state.openInterest, state.entryNotional, state.totalMargin) =
            engineContract.sides(uint8(side));
    }

    /// @notice Reconstructs the engine's current risk-parameter struct from its public tuple getter.
    /// @return params Current risk, VPI, carry, margin, and bounty settings.
    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        params = ICfdEngineRiskParamsView(address(engineContract)).riskParams();
    }

}
