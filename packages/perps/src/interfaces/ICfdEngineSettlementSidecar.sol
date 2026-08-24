// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Externalized settlement executor bound to one CfdEngine host.
/// @dev The sidecar owns no independent economic state and does not validate planner deltas. Each mutation entrypoint
///      requires `msg.sender` to equal `ENGINE`. USDC amounts use 6 decimals, prices use
///      8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEngineSettlementSidecar {

    /// @notice Records the LP-owned frozen-market spread assessed and settled by a voluntary close/reduce.
    /// @param account Account whose close was charged.
    /// @param assessedUsdc Total frozen spread assessed in 6-decimal USDC.
    /// @param paidUsdc Spread recovered from retained value, physical collateral, or existing-claim netting, in
    ///        6-decimal USDC.
    /// @param waivedUsdc Assessed spread left uncollected, in 6-decimal USDC; it does not become bad debt.
    event FrozenCloseSpreadSettled(address indexed account, uint256 assessedUsdc, uint256 paidUsdc, uint256 waivedUsdc);

    /// @notice Reports raw price loss above the account's exact claim-plus-pledge collectible cap.
    /// @dev This amount was never an LP asset and therefore is not protocol bad debt.
    event PriceLossWrittenOff(address indexed account, uint256 amountUsdc);

    /// @notice Reports fail-soft settlement of a close-time net action rebate.
    /// @dev The paid amount is credited as free settlement only after the dedicated reserve for any surviving negative
    ///      lifetime VPI remains locked. Unfunded value is waived and never becomes a nettable claim.
    event ActionRebateSettled(address indexed account, uint256 assessedUsdc, uint256 paidUsdc, uint256 waivedUsdc);

    /// @notice Reports fail-soft action-charge collection without mixing the shortfall into price PnL or bad debt.
    event ActionChargeSettled(address indexed account, uint256 assessedUsdc, uint256 recoveredUsdc, uint256 waivedUsdc);

    /// @notice Returns the engine host authorized to call this sidecar.
    /// @return Bound engine and settlement-host address
    function ENGINE() external view returns (address);

    /// @notice Reconstructs one canonical raw planning snapshot from the bound Engine and its dependencies.
    function buildRawSnapshot(
        address account,
        uint256 poolDepthUsdc
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snap);

    /// @notice Applies the stateful withdrawal guard after the clearinghouse's provisional debit.
    /// @dev Realizes carry through the host, then enforces fresh-mark exact-lot initial-margin health.
    function validateWithdraw(
        address account
    ) external;

    /// @notice Realizes carry and reserves one close-order bounty exclusively from free settlement.
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external;

    /// @notice Applies an open/increase settlement delta through the host hooks.
    /// @dev Advances carry and mark state, settles any pool rebate and clearinghouse trade cost, then locks the gross
    ///      negative lifetime-VPI target in its dedicated action-reserve sub-ledger. It records LP revenue, updates
    ///      side aggregates and fees, and writes the resulting position. The host must supply a valid delta consistent
    ///      with `currentPosition`; the sidecar neither checks `delta.valid` nor recomputes it.
    /// @param delta Valid planned open/increase delta
    /// @param currentPosition Position loaded by the engine immediately before settlement
    /// @param publishTime Oracle publish timestamp proposed for the execution mark
    function executeOpen(
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a close/decrease settlement delta through the host hooks.
    /// @dev Advances carry and mark state, updates side aggregates, unlocks proportional margin, settles gains or
    ///      collectible losses and claims, consumes or releases negative-VPI reserve while preserving the residual
    ///      target, records LP revenue, fees and any frozen spread, then writes or deletes the position. The sidecar
    ///      trusts the engine-supplied delta and current position.
    /// @param delta Valid planned close/decrease delta
    /// @param currentPosition Position loaded by the engine immediately before settlement
    /// @param publishTime Oracle publish timestamp proposed for the execution mark
    function executeClose(
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external;

    /// @notice Applies a liquidation settlement delta through the host hooks.
    /// @dev Advances carry and mark state, removes full side exposure, settles the gross negative lifetime-VPI
    ///      clawback from its dedicated reserve or equivalent withheld gain, applies the clearinghouse terminal plan,
    ///      settles claims and pool revenue, and deletes the position. It trusts the engine-supplied delta and does not
    ///      independently check `delta.liquidatable`.
    /// @param delta Valid planned full-liquidation delta
    /// @param publishTime Oracle publish timestamp proposed for the liquidation mark
    /// @param keeper Clearinghouse account credited with the planned bounty
    /// @return keeperBountyUsdc Planned liquidation bounty credited internally to the keeper in USDC
    function executeLiquidation(
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

}
