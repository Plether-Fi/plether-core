// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineSettlementHost} from "./ICfdEngineSettlementHost.sol";

/// @notice Externalized settlement executor bound to one CfdEngine host.
interface ICfdEngineSettlementSidecar {

    /// @notice Returns the engine host authorized to call this sidecar.
    function ENGINE() external view returns (address);

    /// @notice Applies an open/increase settlement delta through the host hooks.
    /// @param host Engine settlement host owning the storage mutation
    /// @param delta Planned open/increase settlement delta
    /// @param currentPosition Current position loaded by the engine before settlement
    /// @param publishTime Oracle publish timestamp for the execution mark
    function executeOpen(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a close/decrease settlement delta through the host hooks.
    /// @param host Engine settlement host owning the storage mutation
    /// @param delta Planned close/decrease settlement delta
    /// @param currentPosition Current position loaded by the engine before settlement
    /// @param publishTime Oracle publish timestamp for the execution mark
    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a liquidation settlement delta through the host hooks.
    /// @param host Engine settlement host owning the storage mutation
    /// @param delta Planned liquidation settlement delta
    /// @param publishTime Oracle publish timestamp for the liquidation mark
    /// @param keeper Keeper credited with any liquidation bounty
    /// @return keeperBountyUsdc Liquidation bounty credited to the keeper
    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

}
