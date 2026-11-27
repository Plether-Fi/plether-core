// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";

import {ICfdEngineAccountActionView} from "@plether/perps/interfaces/ICfdEngineAccountActionView.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEngineCollateralSnapshotLib} from "@plether/perps/libraries/CfdEngineCollateralSnapshotLib.sol";
import {CfdEngineRawSnapshotLib} from "@plether/perps/libraries/CfdEngineRawSnapshotLib.sol";

interface ICfdEnginePlanningHost {

    function planner() external view returns (ICfdEnginePlanner);
    function settlementSidecar() external view returns (ICfdEngineSettlementSidecar);

}

/// @title CfdEnginePlanningReader
/// @notice Reads the bound engine's canonical snapshot and returns its configured planner's result.
/// @dev Keeps the large snapshot ABI encoding/decoding outside the engine. All entrypoints are read-only;
///      ownership, validation of returned deltas, and settlement remain in the engine. Execution planning sources
///      snapshots from the configured sidecar, which can delegate construction to this reader.
contract CfdEnginePlanningReader {

    ICfdEnginePlanningHost public immutable ENGINE;
    error CfdEnginePlanningReader__OnlyEngine();
    error CfdEnginePlanningReader__OnlyEngineOrSidecar();

    constructor() {
        ENGINE = ICfdEnginePlanningHost(msg.sender);
    }

    modifier onlyEngine() {
        if (msg.sender != address(ENGINE)) {
            revert CfdEnginePlanningReader__OnlyEngine();
        }
        _;
    }

    /// @notice Reconstructs a canonical planning snapshot for the Engine or its configured settlement sidecar.
    /// @dev The close-commit form reads only the exposed side and commitment collateral fields. This is a read-only
    ///      service; permission to obtain a snapshot grants no access to Engine settlement hooks.
    function buildRawSnapshot(
        address account,
        uint256 poolDepthAssets,
        bool closeCommit
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory) {
        if (msg.sender != address(ENGINE) && msg.sender != address(ENGINE.settlementSidecar())) {
            revert CfdEnginePlanningReader__OnlyEngineOrSidecar();
        }
        return _buildRawSnapshot(account, poolDepthAssets, closeCommit);
    }

    function planOpen(
        CfdTypes.Order calldata order,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.OpenDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(order.account, poolDepthAssets);
        return ENGINE.planner().planOpen(snap, order, price);
    }

    function planClose(
        CfdTypes.Order calldata order,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.CloseDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(order.account, poolDepthAssets);
        return ENGINE.planner().planClose(snap, order, price);
    }

    function planLiquidation(
        address account,
        uint256 price,
        uint256 poolDepthAssets
    ) external view onlyEngine returns (CfdEnginePlanTypes.LiquidationDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            ENGINE.settlementSidecar().buildRawSnapshot(account, poolDepthAssets);
        return ENGINE.planner().planLiquidation(snap, price);
    }

    /// @dev Commitment needs only its position side and funding/health state. Execution still reads the full snapshot.
    function _buildRawSnapshot(
        address account,
        uint256 poolDepthAssets,
        bool closeCommit
    ) private view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineSettlementHost host = ICfdEngineSettlementHost(address(ENGINE));
        ICfdEngineAccountActionView engine = ICfdEngineAccountActionView(address(ENGINE));
        IHousePool pool = IHousePool(host.pool());
        CfdEngineRawSnapshotLib.loadCore(snap, address(ENGINE), account, pool);
        snap.lastMarkPrice = engine.lastMarkPrice();
        snap.lastMarkTime = engine.lastMarkTime();

        snap.poolCashAssets = pool.totalAssets();
        // Exact enum dispatch selects the exposed side; this is not a target token-balance equality.
        // slither-disable-next-line incorrect-equality
        if (!closeCommit || snap.position.side == CfdTypes.Side.LONG) {
            snap.longSide = CfdEngineRawSnapshotLib.loadSideState(address(ENGINE), CfdTypes.Side.LONG);
        }
        // The other exact enum value selects the SHORT aggregate snapshot.
        // slither-disable-next-line incorrect-equality
        if (!closeCommit || snap.position.side == CfdTypes.Side.SHORT) {
            snap.shortSide = CfdEngineRawSnapshotLib.loadSideState(address(ENGINE), CfdTypes.Side.SHORT);
        }
        snap.poolAssets = closeCommit ? snap.poolCashAssets : poolDepthAssets;

        IMarginClearinghouse clearinghouse = IMarginClearinghouse(host.clearinghouse());
        CfdEngineCollateralSnapshotLib.load(snap, clearinghouse, account, closeCommit);

        if (!closeCommit) {
            CfdEngineRawSnapshotLib.loadExecutionContext(snap, address(ENGINE));
        }
    }

}
