// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";

/// @notice Externalized settlement executor bound to one CfdEngine host.
/// @dev The sidecar owns no independent economic state and does not validate planner deltas. Each mutation entrypoint
///      requires both `msg.sender` and the supplied `host` to equal `ENGINE`. USDC amounts use 6 decimals, prices use
///      8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEngineSettlementSidecar {

    /// @notice Records the LP-owned frozen-market spread assessed and settled by a voluntary close/reduce.
    /// @param account Account whose close was charged.
    /// @param assessedUsdc Total frozen spread assessed in 6-decimal USDC.
    /// @param paidUsdc Spread recovered from retained value, physical collateral, or existing-claim netting, in
    ///        6-decimal USDC.
    /// @param waivedUsdc Assessed spread left uncollected, in 6-decimal USDC; it does not become bad debt.
    event FrozenCloseSpreadSettled(address indexed account, uint256 assessedUsdc, uint256 paidUsdc, uint256 waivedUsdc);

    /// @notice Returns the engine host authorized to call this sidecar.
    /// @return Bound engine and settlement-host address
    function ENGINE() external view returns (address);

    /// @notice Applies an open/increase settlement delta through the host hooks.
    /// @dev Advances carry and mark state, settles any pool rebate and clearinghouse trade cost, records LP revenue,
    ///      updates side aggregates and fees, then writes the resulting position. The host must supply a valid delta
    ///      consistent with `currentPosition`; the sidecar neither checks `delta.valid` nor recomputes it.
    /// @param host Bound engine settlement host owning canonical storage
    /// @param delta Valid planned open/increase delta
    /// @param currentPosition Position loaded by the engine immediately before settlement
    /// @param publishTime Oracle publish timestamp proposed for the execution mark
    function executeOpen(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a close/decrease settlement delta through the host hooks.
    /// @dev Advances carry and mark state, updates side aggregates, unlocks proportional margin, settles gains or
    ///      losses and claims, records LP revenue, bad debt, fees and any frozen spread, then writes or deletes the
    ///      position. The sidecar trusts the engine-supplied delta and current position.
    /// @param host Bound engine settlement host owning canonical storage
    /// @param delta Valid planned close/decrease delta
    /// @param currentPosition Position loaded by the engine immediately before settlement
    /// @param publishTime Oracle publish timestamp proposed for the execution mark
    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a liquidation settlement delta through the host hooks.
    /// @dev Advances carry and mark state, removes full side exposure, applies the clearinghouse terminal plan, settles
    ///      claims and pool revenue, records bad debt, and deletes the position. It trusts the engine-supplied delta and
    ///      does not independently check `delta.liquidatable`.
    /// @param host Bound engine settlement host owning canonical storage
    /// @param delta Valid planned full-liquidation delta
    /// @param publishTime Oracle publish timestamp proposed for the liquidation mark
    /// @param keeper Clearinghouse account credited with the planned bounty
    /// @return keeperBountyUsdc Planned liquidation bounty credited internally to the keeper in USDC
    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

}
