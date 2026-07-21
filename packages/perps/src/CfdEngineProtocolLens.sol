// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
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
    ///      trader claims; free USDC is pool assets above the reserve; and effective solvency assets are pool assets net
    ///      of trader claims. The separately reported net physical assets subtract the protocol-treasury clearinghouse
    ///      balance, but that subtraction is not applied to `effectiveSolvencyAssetsUsdc`. Accumulated bad debt is
    ///      reported diagnostically and likewise is not subtracted by this snapshot. `hasLiveLiability` follows nonzero
    ///      side maximum-profit envelopes rather than raw open interest.
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
    ///      clearinghouse balance with saturation. Maximum liability is the larger side maximum-profit envelope.
    ///      Withdrawal-only unrealized MtM liability uses both side envelopes at the cached mark and is zero before the
    ///      first mark. Deposit MtM and supplemental reserve are deliberately zero. Open-position status follows side
    ///      open interest, while mark-freshness gating follows side maximum-profit liability. When gating is required,
    ///      frozen-market policy uses `fadMaxStaleness`; live policy uses the tighter nonzero engine/pool limit. This
    ///      function selects a limit but does not itself test the cached mark's age.
    /// @param markStalenessLimit HousePool live-mark age limit in seconds; zero delegates to the engine limit.
    /// @return snapshot Engine inputs for HousePool reconcile, deposit, and withdrawal calculations.
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot) {
        uint256 poolAssetsUsdc = engineContract.pool().totalAssets();
        uint256 protocolTreasuryBalanceUsdc =
            engineContract.clearinghouse().balanceUsdc(engineContract.protocolTreasury());
        snapshot.physicalAssetsUsdc = poolAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc =
            poolAssetsUsdc > protocolTreasuryBalanceUsdc ? poolAssetsUsdc - protocolTreasuryBalanceUsdc : 0;
        snapshot.maxLiabilityUsdc = SolvencyAccountingLib.getMaxLiability(
            _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
        );
        snapshot.supplementalReservedUsdc = 0;
        snapshot.unrealizedMtmLiabilityUsdc = _getVaultMtmLiability();
        // Deposit pricing is intentionally neutral to unrealized trader PnL. Conservative MtM remains
        // withdrawal-only; without per-position netting, any aggregate deposit-side MtM is manipulable.
        snapshot.depositMtmLiabilityUsdc = 0;
        ICfdEngineTypes.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngineTypes.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        snapshot.traderClaimBalanceUsdc = engineContract.totalTraderClaimBalanceUsdc();
        snapshot.hasOpenPositions = bullState.openInterest > 0 || bearState.openInterest > 0;
        snapshot.markFreshnessRequired = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
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

    /// @notice Computes conservative withdrawal-only MtM liability at the cached engine mark.
    /// @dev Returns zero until a mark timestamp has been established, then sums the two side liability envelopes.
    /// @return Conservative current MtM liability in 6-decimal USDC units.
    function _getVaultMtmLiability() internal view returns (uint256) {
        if (engineContract.lastMarkTime() == 0) {
            return 0;
        }

        uint256 price = engineContract.lastMarkPrice();
        ICfdEngineTypes.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngineTypes.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        uint256 capPrice = engineContract.CAP_PRICE();
        return CfdMath.conservativeMtmLiability(bullState.maxProfitUsdc, CfdTypes.Side.BULL, price, capPrice)
            + CfdMath.conservativeMtmLiability(bearState.maxProfitUsdc, CfdTypes.Side.BEAR, price, capPrice);
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
            _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
        );
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.poolAssetsUsdc = poolAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc > protocolTreasuryBalanceUsdc
            ? solvencyState.netPhysicalAssetsUsdc - protocolTreasuryBalanceUsdc
            : 0;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        snapshot.withdrawalReservedUsdc = solvencyState.withdrawalReservedUsdc;
        snapshot.freeUsdc = solvencyState.freeWithdrawableUsdc;
        snapshot.protocolTreasuryBalanceUsdc = protocolTreasuryBalanceUsdc;
        snapshot.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snapshot.totalTraderClaimBalanceUsdc = engineContract.totalTraderClaimBalanceUsdc();
        snapshot.degradedMode = engineContract.degradedMode();
        ICfdEngineTypes.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngineTypes.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        snapshot.hasLiveLiability = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    /// @notice Builds solvency from pool assets, maximum side liability, and aggregate trader claims.
    /// @return Current solvency state; protocol treasury and accumulated bad debt are not separate deductions.
    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            engineContract.pool().totalAssets(),
            SolvencyAccountingLib.getMaxLiability(
                _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
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
