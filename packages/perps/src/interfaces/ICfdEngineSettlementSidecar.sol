// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Externalized settlement executor bound to one CfdEngine host.
/// @dev The sidecar owns no independent economic state and does not validate planner deltas. Each mutation entrypoint
///      requires `msg.sender` to equal `ENGINE`. settlement token amounts use 6 decimals, prices use
///      8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEngineSettlementSidecar {

    /// @notice Records the LP-owned frozen-market spread assessed and settled by a voluntary close/reduce.
    /// @param account Account whose close was charged.
    /// @param assessedAssets Total frozen spread assessed in 6-decimal settlement token.
    /// @param paidAssets Spread recovered from fresh price-gain withholding or eligible action collateral, in 6-decimal
    ///        settlement token; existing trader claims may net only price loss and cannot pay the spread.
    /// @param waivedAssets Assessed spread left uncollected, in 6-decimal settlement token; it does not become bad debt.
    event FrozenCloseSpreadSettled(
        address indexed account, uint256 assessedAssets, uint256 paidAssets, uint256 waivedAssets
    );

    /// @notice Reports raw price loss above the account's exact claim-plus-pledge collectible cap.
    /// @dev This amount was never an LP asset and therefore is not protocol bad debt.
    event PriceLossWrittenOff(address indexed account, uint256 amountAssets);

    /// @notice Reports fail-soft settlement of a close-time net action rebate.
    /// @dev The paid amount is credited as free settlement only after the dedicated reserve for any surviving negative
    ///      lifetime VPI remains locked. Unfunded value is waived and never becomes a nettable claim.
    event ActionRebateSettled(
        address indexed account, uint256 assessedAssets, uint256 paidAssets, uint256 waivedAssets
    );

    /// @notice Reports fail-soft action-charge collection without mixing the shortfall into price PnL or bad debt.
    event ActionChargeSettled(
        address indexed account, uint256 assessedAssets, uint256 recoveredAssets, uint256 waivedAssets
    );

    /// @notice Returns the engine host authorized to call this sidecar.
    /// @return Bound engine and settlement-host address
    function ENGINE() external view returns (address);

    /// @notice Reconstructs one canonical raw planning snapshot from the bound Engine and its dependencies.
    /// @dev Readable only by the engine or its constructor-created immutable planning reader.
    function buildRawSnapshot(
        address account,
        uint256 poolDepthAssets
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snap);

    /// @notice Applies the stateful withdrawal guard after the clearinghouse's provisional debit.
    /// @dev Realizes carry through the host, then enforces fresh-mark exact-lot initial-margin health.
    function validateWithdraw(
        address account
    ) external;

    /// @notice Plans close commitment and realizes carry without reserving a bounty.
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta
    ) external returns (CfdEnginePlanTypes.CloseCommitment memory effects);

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
    /// @return keeperBountyAssets Planned liquidation bounty credited internally to the keeper in settlement token
    function executeLiquidation(
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyAssets);

}
