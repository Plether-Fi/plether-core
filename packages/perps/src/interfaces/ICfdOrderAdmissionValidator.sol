// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

/// @notice Read-only fixed-request and account-queue checks for the lens's immutable engine.
interface ICfdOrderAdmissionValidator {

    function validateRequest(
        OrderV3Types.OrderRequest calldata request
    ) external view;

    function validateOpen(
        address account,
        OrderV3Types.OrderRequest calldata request,
        uint256 bountyAssets
    ) external view;

    function queuedPosition(
        address account
    ) external view returns (bool exists, CfdTypes.Side side, uint256 size, uint256 closeableSize);

    function prepareOpenCommitSnapshot(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionBountyAssets
    ) external pure returns (CfdEnginePlanTypes.RawSnapshot memory);

}
