// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAccountActionView} from "@plether/perps/interfaces/ICfdEngineAccountActionView.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @notice Shared field loaders for engine planning and diagnostic snapshots.
/// @dev Callers select cash and pricing depth, mark context, and collateral source.
library CfdEngineRawSnapshotLib {

    function loadCore(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        address engineAddress,
        address account,
        IHousePool pool
    ) internal view {
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(engineAddress);
        snap.position = _position(engine, account);
        snap.positionEntryCostAssetAtoms = engine.positionEntryCostAssetAtoms(account);
        (, snap.positionLastCarryIndex, snap.position.lastCarryTimestamp) = engine.positionCarryState(account);
        snap.carryIndex = engine.currentCarryIndex();
        snap.account = account;
        snap.currentTimestamp = block.timestamp;
        snap.riskParams = ICfdEngineRiskParamsView(engineAddress).riskParams();
        snap.poolAdditionalReservedAssets =
            pool.pendingRecapitalizationAssets() + pool.pendingTradingRevenueAssets() + pool.unassignedAssets();
        snap.poolQueuesTradingRevenue = pool.seniorPrincipal() == 0 && pool.juniorPrincipal() == 0;
        snap.totalTraderClaimBalanceAssets = engine.totalTraderClaimBalanceAssets();
        snap.totalPositiveVpiAccruedAssets = engine.totalPositiveVpiAccruedAssets();
        snap.totalNegativeVpiAccruedAssets = engine.totalNegativeVpiAccruedAssets();
        snap.unsettledCarryAssets = engine.unsettledCarryAssets(account);
        snap.traderClaimBalanceForAccount = engine.traderClaimBalanceAssets(account);
        snap.capPrice = engine.CAP_PRICE();
        snap.isFadWindow = engine.isFadWindow();
    }

    function loadExecutionContext(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        address engineAddress
    ) internal view {
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(engineAddress);
        snap.degradedMode = engine.degradedMode();
        snap.executionFeeBps = engine.executionFeeBps();
        snap.settlementBufferBps = engine.settlementBufferBps();
        snap.oracleFrozen = engine.isOracleFrozen();
        snap.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
    }

    function loadSideState(
        address engineAddress,
        CfdTypes.Side side
    ) internal view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(engineAddress);
        uint256 index = uint256(side);
        (snap.maxProfitAssets, snap.openInterest, snap.entryNotional, snap.totalMargin) = engine.sides(index);
    }

    function _position(
        ICfdEngineAccountActionView engine,
        address account
    ) private view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitAssets, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(account);
    }

}
