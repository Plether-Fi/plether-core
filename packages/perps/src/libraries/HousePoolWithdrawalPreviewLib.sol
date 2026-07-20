// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";

/// @title HousePoolWithdrawalPreviewLib
/// @notice Pure helpers for applying reservations and computing senior/junior withdrawal caps.
library HousePoolWithdrawalPreviewLib {

    /// @notice Applies an additional reservation to a withdrawal snapshot.
    /// @dev Increases `reserved` by the full amount and reduces `freeUsdc` with saturation at zero.
    /// @param snapshot Current withdrawal accounting snapshot.
    /// @param reservedAssets Additional reserved assets (6 decimals).
    /// @return nextSnapshot Snapshot after applying the reservation.
    function reserveAssets(
        HousePoolAccountingLib.WithdrawalSnapshot memory snapshot,
        uint256 reservedAssets
    ) internal pure returns (HousePoolAccountingLib.WithdrawalSnapshot memory nextSnapshot) {
        nextSnapshot = snapshot;
        if (reservedAssets == 0) {
            return nextSnapshot;
        }

        nextSnapshot.reserved += reservedAssets;
        nextSnapshot.freeUsdc = nextSnapshot.freeUsdc > reservedAssets ? nextSnapshot.freeUsdc - reservedAssets : 0;
    }

    /// @notice Caps senior withdrawals by both free cash and senior principal.
    /// @param freeUsdc Cash remaining after senior protocol reservations (6 decimals).
    /// @param seniorPrincipal Current senior principal (6 decimals).
    /// @return Maximum senior withdrawal (6 decimals).
    function seniorWithdrawCap(
        uint256 freeUsdc,
        uint256 seniorPrincipal
    ) internal pure returns (uint256) {
        return freeUsdc < seniorPrincipal ? freeUsdc : seniorPrincipal;
    }

    /// @notice Caps junior withdrawals to cash remaining after reserving senior principal.
    /// @param freeUsdc Cash remaining after senior protocol reservations (6 decimals).
    /// @param seniorPrincipal Current senior principal senior to junior withdrawals (6 decimals).
    /// @param juniorPrincipal Current junior principal (6 decimals).
    /// @return Maximum junior withdrawal (6 decimals).
    function juniorWithdrawCap(
        uint256 freeUsdc,
        uint256 seniorPrincipal,
        uint256 juniorPrincipal
    ) internal pure returns (uint256) {
        uint256 subordinated = freeUsdc > seniorPrincipal ? freeUsdc - seniorPrincipal : 0;
        return subordinated < juniorPrincipal ? subordinated : juniorPrincipal;
    }

}
