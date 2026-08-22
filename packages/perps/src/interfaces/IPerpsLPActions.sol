// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @notice HousePool LP mutation surface used by configured tranche vaults and permissionless epoch settlers.
/// @dev Reservation selectors authorize only the configured senior vault; legacy synchronous deposit selectors always
///      revert. `settleLpEpoch` is the sole ordinary entry-finalization and pool cash-exit path and is permissionless.
interface IPerpsLPActions {

    /// @notice Retained compatibility selector for the removed synchronous senior-entry hook.
    /// @dev Always reverts. Senior entry is requested through the vault and finalized only by `settleLpEpoch`.
    /// @param amount Ignored legacy USDC amount
    function depositSenior(
        uint256 amount
    ) external;

    /// @notice Reserves governed senior capacity for a delayed deposit request.
    /// @param amount Gross USDC request amount to reserve (6 decimals)
    function reserveSeniorDeposit(
        uint256 amount
    ) external;

    /// @notice Releases governed senior capacity after a delayed request is cancelled.
    /// @param amount Gross USDC request amount to release (6 decimals)
    function releaseSeniorDepositReservation(
        uint256 amount
    ) external;

    /// @notice Retained compatibility selector for the removed synchronous junior-entry hook.
    /// @dev Always reverts. Junior entry is requested through the vault and finalized only by `settleLpEpoch`.
    /// @param amount Ignored legacy USDC amount
    function depositJunior(
        uint256 amount
    ) external;

    /// @notice Runs one bounded synchronized LP epoch settlement.
    /// @dev Funds matured senior withdrawal requests before junior requests, then finalizes eligible delayed deposits.
    ///      Funded user claims remain in vault escrow and are claimed without another HousePool call.
    /// @return result Exact funding, entry finalization, and residual-work summary.
    function settleLpEpoch() external returns (IHousePool.LpEpochSettlementResult memory result);

}
