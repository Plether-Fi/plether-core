// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolAccountingLib} from "./HousePoolAccountingLib.sol";

library HousePoolWithdrawalPreviewLib {
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

    function seniorWithdrawCap(
        uint256 freeUsdc,
        uint256 seniorPrincipal
    ) internal pure returns (uint256) {
        return freeUsdc < seniorPrincipal ? freeUsdc : seniorPrincipal;
    }

    function juniorWithdrawCap(
        uint256 freeUsdc,
        uint256 seniorPrincipal,
        uint256 juniorPrincipal
    ) internal pure returns (uint256) {
        uint256 subordinated = freeUsdc > seniorPrincipal ? freeUsdc - seniorPrincipal : 0;
        return subordinated < juniorPrincipal ? subordinated : juniorPrincipal;
    }
}
