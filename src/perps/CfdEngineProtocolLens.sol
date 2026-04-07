// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "./CfdEngine.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineProtocolLens} from "./interfaces/ICfdEngineProtocolLens.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";
import {CfdEngineSnapshotsLib} from "./libraries/CfdEngineSnapshotsLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "./libraries/SolvencyAccountingLib.sol";
import {WithdrawalAccountingLib} from "./libraries/WithdrawalAccountingLib.sol";

contract CfdEngineProtocolLens is ICfdEngineProtocolLens {

    CfdEngine public immutable engineContract;

    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    function engine() external view returns (address) {
        return address(engineContract);
    }

    function getPositionView(
        bytes32 accountId
    ) external view returns (CfdEngine.PositionView memory viewData) {
        CfdTypes.Position memory pos = _position(accountId);
        if (pos.size == 0) {
            return viewData;
        }

        uint256 reachableUsdc = engineContract.clearinghouse().getTerminalReachableUsdc(accountId);
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos,
            engineContract.lastMarkPrice(),
            engineContract.CAP_PRICE(),
            reachableUsdc,
            engineContract.isFadWindow() ? _riskParams().fadMarginBps : _riskParams().maintMarginBps
        );

        viewData.exists = true;
        viewData.side = pos.side;
        viewData.size = pos.size;
        viewData.margin = engineContract.clearinghouse().getLockedMarginBuckets(accountId).positionMarginUsdc;
        viewData.entryPrice = pos.entryPrice;
        viewData.entryNotionalUsdc = (pos.size * pos.entryPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        viewData.physicalReachableCollateralUsdc = reachableUsdc;
        viewData.nettableDeferredPayoutUsdc = engineContract.deferredPayoutUsdc(accountId);
        viewData.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        viewData.pendingFundingUsdc = 0;
        viewData.netEquityUsdc = riskState.equityUsdc;
        viewData.maxProfitUsdc =
            CfdMath.calculateMaxProfit(pos.size, pos.entryPrice, pos.side, engineContract.CAP_PRICE());
        viewData.liquidatable = riskState.liquidatable;
    }

    function getDeferredPayoutStatus(
        bytes32 accountId,
        address keeper
    ) external view returns (CfdEngine.DeferredPayoutStatus memory status) {
        ICfdEngine.DeferredTraderStatus memory traderStatus = getDeferredTraderStatus(accountId);
        ICfdEngine.DeferredClearerStatus memory clearerStatus = getDeferredClearerStatus(keeper);
        status.deferredTraderPayoutUsdc = traderStatus.deferredPayoutUsdc;
        status.traderPayoutClaimableNow = traderStatus.claimableNow;
        status.deferredClearerBountyUsdc = clearerStatus.deferredBountyUsdc;
        status.liquidationBountyClaimableNow = clearerStatus.claimableNow;
    }

    function getDeferredTraderStatus(
        bytes32 accountId
    ) public view returns (ICfdEngine.DeferredTraderStatus memory status) {
        status.claimId = engineContract.traderDeferredClaimIdByAccount(accountId);
        status.deferredPayoutUsdc = engineContract.deferredPayoutUsdc(accountId);
        uint64 headId = engineContract.deferredClaimHeadId();
        status.isHead = status.claimId != 0 && status.claimId == headId;
        status.claimableNow = status.isHead && _claimableHeadAmountUsdc() > 0;
    }

    function getDeferredClearerStatus(
        address keeper
    ) public view returns (ICfdEngine.DeferredClearerStatus memory status) {
        status.claimId = engineContract.clearerDeferredClaimIdByKeeper(keeper);
        status.deferredBountyUsdc = engineContract.deferredClearerBountyUsdc(keeper);
        uint64 headId = engineContract.deferredClaimHeadId();
        status.isHead = status.claimId != 0 && status.claimId == headId;
        status.claimableNow = status.isHead && _claimableHeadAmountUsdc() > 0;
    }

    function getVaultMtmAdjustment() external view returns (uint256 mtmLiabilityUsdc) {
        mtmLiabilityUsdc = _getVaultMtmLiability();
    }

    function getProtocolStatus() external view returns (ICfdEngine.ProtocolStatus memory status) {
        status.phase = _getProtocolPhase();
        status.lastMarkTime = engineContract.lastMarkTime();
        status.lastMarkPrice = engineContract.lastMarkPrice();
        status.oracleFrozen = engineContract.isOracleFrozen();
        status.fadWindow = engineContract.isFadWindow();
        status.fadMaxStaleness = engineContract.fadMaxStaleness();
    }

    function getProtocolAccountingView() external view returns (CfdEngine.ProtocolAccountingView memory viewData) {
        ICfdEngine.ProtocolAccountingSnapshot memory snapshot = _buildProtocolAccountingSnapshot();
        viewData.vaultAssetsUsdc = snapshot.vaultAssetsUsdc;
        viewData.maxLiabilityUsdc = snapshot.maxLiabilityUsdc;
        viewData.withdrawalReservedUsdc = snapshot.withdrawalReservedUsdc;
        viewData.freeUsdc = snapshot.freeUsdc;
        viewData.accumulatedFeesUsdc = snapshot.accumulatedFeesUsdc;
        viewData.cappedFundingPnlUsdc = snapshot.cappedFundingPnlUsdc;
        viewData.liabilityOnlyFundingPnlUsdc = snapshot.liabilityOnlyFundingPnlUsdc;
        viewData.totalDeferredPayoutUsdc = snapshot.totalDeferredPayoutUsdc;
        viewData.totalDeferredClearerBountyUsdc = snapshot.totalDeferredClearerBountyUsdc;
        viewData.degradedMode = snapshot.degradedMode;
        viewData.hasLiveLiability = snapshot.hasLiveLiability;
    }

    function getProtocolAccountingSnapshot()
        external
        view
        returns (ICfdEngine.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (ICfdEngine.HousePoolInputSnapshot memory snapshot) {
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

    function getHousePoolStatusSnapshot() external view returns (ICfdEngine.HousePoolStatusSnapshot memory snapshot) {
        snapshot.lastMarkTime = engineContract.lastMarkTime();
        snapshot.oracleFrozen = engineContract.isOracleFrozen();
        snapshot.degradedMode = engineContract.degradedMode();
    }

    function _claimableHeadAmountUsdc() internal view returns (uint256) {
        uint64 claimId = engineContract.deferredClaimHeadId();
        if (claimId == 0) {
            return 0;
        }
        (,,, uint256 remainingUsdc,,) = engineContract.deferredClaims(claimId);
        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveDeferredHeadClaim(
            engineContract.vault().totalAssets(),
            engineContract.accumulatedFeesUsdc(),
            engineContract.totalDeferredPayoutUsdc(),
            engineContract.totalDeferredClearerBountyUsdc(),
            remainingUsdc
        );
        return reservation.headClaimServiceableUsdc;
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        int256 ignoredEntryFundingIndex;
        (
            pos.size,
            pos.margin,
            pos.entryPrice,
            pos.maxProfitUsdc,
            ignoredEntryFundingIndex,
            pos.side,
            pos.lastUpdateTime,
            pos.vpiAccrued
        ) = engineContract.positions(accountId);
        ignoredEntryFundingIndex;
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

    function _getProtocolPhase() internal view returns (ICfdEngine.ProtocolPhase) {
        if (address(engineContract.vault()) == address(0) || engineContract.orderRouter() == address(0)) {
            return ICfdEngine.ProtocolPhase.Configuring;
        }
        if (engineContract.degradedMode()) {
            return ICfdEngine.ProtocolPhase.Degraded;
        }
        if (!engineContract.vault().canIncreaseRisk()) {
            return ICfdEngine.ProtocolPhase.Configuring;
        }
        return ICfdEngine.ProtocolPhase.Active;
    }

    function _buildProtocolAccountingSnapshot()
        internal
        view
        returns (ICfdEngine.ProtocolAccountingSnapshot memory snapshot)
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

    function _sideSnapshot(
        ICfdEngine.SideState memory side
    ) internal pure returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: side.maxProfitUsdc,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin
        });
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
