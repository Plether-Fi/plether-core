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
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        snapshot.maxLiabilityUsdc = _maxLiabilityFromSides(bullState, bearState);
        snapshot.supplementalReservedUsdc = 0;
        snapshot.unrealizedMtmLiabilityUsdc = _getVaultMtmLiability();
        snapshot.deferredTraderCreditUsdc = engineContract.totalDeferredTraderCreditUsdc();
        snapshot.deferredKeeperCreditUsdc = engineContract.totalDeferredKeeperCreditUsdc();
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
        if (engineContract.lastMarkTime() == 0) {
            return 0;
        }

        uint256 price = engineContract.lastMarkPrice();
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        uint256 capPrice = engineContract.CAP_PRICE();
        return CfdMath.conservativeMtmLiability(bullState.maxProfitUsdc, CfdTypes.Side.BULL, price, capPrice)
            + CfdMath.conservativeMtmLiability(bearState.maxProfitUsdc, CfdTypes.Side.BEAR, price, capPrice);
    }

    function _buildProtocolAccountingSnapshot()
        internal
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        uint256 vaultAssetsUsdc = engineContract.vault().totalAssets();
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        uint256 maxLiabilityUsdc = _maxLiabilityFromSides(bullState, bearState);
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.vaultAssetsUsdc = vaultAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        snapshot.withdrawalReservedUsdc = solvencyState.withdrawalReservedUsdc;
        snapshot.freeUsdc = solvencyState.freeWithdrawableUsdc;
        snapshot.accumulatedFeesUsdc = engineContract.accumulatedFeesUsdc();
        snapshot.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snapshot.totalDeferredTraderCreditUsdc = engineContract.totalDeferredTraderCreditUsdc();
        snapshot.totalDeferredKeeperCreditUsdc = engineContract.totalDeferredKeeperCreditUsdc();
        snapshot.degradedMode = engineContract.degradedMode();
        snapshot.hasLiveLiability = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        ICfdEngine.SideState memory bullState = _sideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = _sideState(CfdTypes.Side.BEAR);
        return SolvencyAccountingLib.buildSolvencyState(
            engineContract.vault().totalAssets(),
            engineContract.accumulatedFeesUsdc(),
            _maxLiabilityFromSides(bullState, bearState),
            engineContract.totalDeferredTraderCreditUsdc(),
            engineContract.totalDeferredKeeperCreditUsdc()
        );
    }

    function _maxLiabilityFromSides(
        ICfdEngine.SideState memory bullState,
        ICfdEngine.SideState memory bearState
    ) internal view returns (uint256) {
        bullState;
        bearState;
        return SolvencyAccountingLib.getMaxLiability(
            engineContract.sideLpBackedRiskUsdc(uint8(CfdTypes.Side.BULL)),
            engineContract.sideLpBackedRiskUsdc(uint8(CfdTypes.Side.BEAR))
        );
    }

    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngine.SideState memory state) {
        (state.maxProfitUsdc, state.openInterest, state.entryNotional, state.totalMargin) =
            engineContract.sides(uint8(side));
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
