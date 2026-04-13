// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {HousePoolEngineViewTypes} from "./interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEngineProtocolLens} from "./interfaces/ICfdEngineProtocolLens.sol";
import {ProtocolLensViewTypes} from "./interfaces/ProtocolLensViewTypes.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {SolvencyAccountingLib} from "./libraries/SolvencyAccountingLib.sol";

/// @title CfdEngineProtocolLens
/// @notice Rich protocol-accounting lens for audits, tests, and HousePool integration.
/// @dev Exposes conservative solvency and liability views rather than product-level summaries.
contract CfdEngineProtocolLens is ICfdEngineProtocolLens {

    CfdEngine public immutable engineContract;

    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @notice Returns the canonical protocol-accounting snapshot used by diagnostics and audits.
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    /// @notice Builds the HousePool accounting snapshot against a caller-supplied freshness limit.
    /// @dev This packages the engine-side values HousePool needs for reconcile and withdrawal logic.
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot) {
        uint256 vaultAssetsUsdc = engineContract.vault().totalAssets();
        snapshot.physicalAssetsUsdc = vaultAssetsUsdc;
        snapshot.protocolFeesUsdc = engineContract.accumulatedFeesUsdc();
        snapshot.netPhysicalAssetsUsdc =
            vaultAssetsUsdc > snapshot.protocolFeesUsdc ? vaultAssetsUsdc - snapshot.protocolFeesUsdc : 0;
        snapshot.maxLiabilityUsdc = SolvencyAccountingLib.getMaxLiability(
            _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
        );
        snapshot.supplementalReservedUsdc = 0;
        snapshot.unrealizedMtmLiabilityUsdc = _getVaultMtmLiability();
        snapshot.deferredTraderPayoutUsdc = engineContract.totalDeferredPayoutUsdc();
        snapshot.deferredKeeperCreditUsdc = engineContract.totalDeferredKeeperCreditUsdc();
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        snapshot.markFreshnessRequired = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
        if (snapshot.markFreshnessRequired) {
            snapshot.maxMarkStaleness = OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.PoolReconcile,
                engineContract.isOracleFrozen(),
                engineContract.isFadWindow(),
                engineContract.engineMarkStalenessLimit(),
                markStalenessLimit,
                0,
                0,
                engineContract.fadMaxStaleness()
            ).maxStaleness;
        }
    }

    /// @notice Returns the current HousePool status flags sourced from engine runtime state.
    function getHousePoolStatusSnapshot()
        external
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot)
    {
        snapshot.lastMarkTime = engineContract.lastMarkTime();
        snapshot.oracleFrozen = engineContract.isOracleFrozen();
        snapshot.degradedMode = engineContract.degradedMode();
    }

    function _getVaultMtmLiability() internal view returns (uint256) {
        uint256 price = engineContract.lastMarkPrice();

        int256 bullPnl;
        int256 bearPnl;
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        if (price > 0) {
            bullPnl = (int256(bullState.entryNotional) - int256(bullState.openInterest * price))
                / int256(CfdMath.USDC_TO_TOKEN_SCALE);
            bearPnl = (int256(bearState.openInterest * price) - int256(bearState.entryNotional))
                / int256(CfdMath.USDC_TO_TOKEN_SCALE);
        }
        int256 bullTotal = bullPnl;
        int256 bearTotal = bearPnl;
        if (bullTotal < 0) {
            bullTotal = 0;
        }
        if (bearTotal < 0) {
            bearTotal = 0;
        }
        return uint256(bullTotal) + uint256(bearTotal);
    }

    function _buildProtocolAccountingSnapshot()
        internal
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        uint256 vaultAssetsUsdc = engineContract.vault().totalAssets();
        uint256 maxLiabilityUsdc = SolvencyAccountingLib.getMaxLiability(
            _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
        );
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.vaultAssetsUsdc = vaultAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        snapshot.withdrawalReservedUsdc = solvencyState.withdrawalReservedUsdc;
        snapshot.freeUsdc = solvencyState.freeWithdrawableUsdc;
        snapshot.accumulatedFeesUsdc = engineContract.accumulatedFeesUsdc();
        snapshot.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snapshot.totalDeferredPayoutUsdc = engineContract.totalDeferredPayoutUsdc();
        snapshot.totalDeferredKeeperCreditUsdc = engineContract.totalDeferredKeeperCreditUsdc();
        snapshot.degradedMode = engineContract.degradedMode();
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        snapshot.hasLiveLiability = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            engineContract.vault().totalAssets(),
            engineContract.accumulatedFeesUsdc(),
            SolvencyAccountingLib.getMaxLiability(
                _sideState(CfdTypes.Side.BULL).maxProfitUsdc, _sideState(CfdTypes.Side.BEAR).maxProfitUsdc
            ),
            engineContract.totalDeferredPayoutUsdc(),
            engineContract.totalDeferredKeeperCreditUsdc()
        );
    }

    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngine.SideState memory state) {
        (state.maxProfitUsdc, state.openInterest, state.entryNotional, state.totalMargin) = engineContract.sides(uint8(side));
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
