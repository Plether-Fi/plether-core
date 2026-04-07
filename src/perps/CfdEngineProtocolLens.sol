// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEngineProtocolLens} from "./interfaces/ICfdEngineProtocolLens.sol";
import {HousePoolEngineViewTypes} from "./interfaces/HousePoolEngineViewTypes.sol";
import {ProtocolLensViewTypes} from "./interfaces/ProtocolLensViewTypes.sol";
import {SolvencyAccountingLib} from "./libraries/SolvencyAccountingLib.sol";
import {WithdrawalAccountingLib} from "./libraries/WithdrawalAccountingLib.sol";

contract CfdEngineProtocolLens is ICfdEngineProtocolLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot) {
        uint256 vaultAssetsUsdc = engineContract.vault().totalAssets();
        snapshot.physicalAssetsUsdc = vaultAssetsUsdc;
        snapshot.protocolFeesUsdc = engineContract.accumulatedFeesUsdc();
        snapshot.netPhysicalAssetsUsdc =
            vaultAssetsUsdc > snapshot.protocolFeesUsdc ? vaultAssetsUsdc - snapshot.protocolFeesUsdc : 0;
        snapshot.maxLiabilityUsdc = engineContract.getMaxLiability();
        snapshot.withdrawalFundingLiabilityUsdc = 0;
        snapshot.unrealizedMtmLiabilityUsdc = _getVaultMtmLiability();
        snapshot.deferredTraderPayoutUsdc = engineContract.totalDeferredPayoutUsdc();
        snapshot.deferredClearerBountyUsdc = engineContract.totalDeferredClearerBountyUsdc();
        ICfdEngine.SideState memory bullState = engineContract.getSideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = engineContract.getSideState(CfdTypes.Side.BEAR);
        snapshot.markFreshnessRequired = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
        if (snapshot.markFreshnessRequired) {
            snapshot.maxMarkStaleness =
                engineContract.isOracleFrozen() ? engineContract.fadMaxStaleness() : markStalenessLimit;
        }
    }

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
        ICfdEngine.SideState memory bullState = engineContract.getSideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = engineContract.getSideState(CfdTypes.Side.BEAR);
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
        uint256 maxLiabilityUsdc = engineContract.getMaxLiability();
        WithdrawalAccountingLib.WithdrawalState memory withdrawalState = WithdrawalAccountingLib.buildWithdrawalState(
            vaultAssetsUsdc,
            maxLiabilityUsdc,
            engineContract.accumulatedFeesUsdc(),
            engineContract.totalDeferredPayoutUsdc(),
            engineContract.totalDeferredClearerBountyUsdc()
        );
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.vaultAssetsUsdc = vaultAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        snapshot.withdrawalReservedUsdc = withdrawalState.reservedUsdc;
        snapshot.freeUsdc = withdrawalState.freeUsdc;
        snapshot.accumulatedFeesUsdc = engineContract.accumulatedFeesUsdc();
        snapshot.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snapshot.cappedFundingPnlUsdc = 0;
        snapshot.liabilityOnlyFundingPnlUsdc = 0;
        snapshot.totalDeferredPayoutUsdc = engineContract.totalDeferredPayoutUsdc();
        snapshot.totalDeferredClearerBountyUsdc = engineContract.totalDeferredClearerBountyUsdc();
        snapshot.degradedMode = engineContract.degradedMode();
        ICfdEngine.SideState memory bullState = engineContract.getSideState(CfdTypes.Side.BULL);
        ICfdEngine.SideState memory bearState = engineContract.getSideState(CfdTypes.Side.BEAR);
        snapshot.hasLiveLiability = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            engineContract.vault().totalAssets(),
            engineContract.accumulatedFeesUsdc(),
            engineContract.getMaxLiability(),
            engineContract.totalDeferredPayoutUsdc(),
            engineContract.totalDeferredClearerBountyUsdc()
        );
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
