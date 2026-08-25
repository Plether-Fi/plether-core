// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsAdmin} from "@plether/perps/interfaces/IPerpsAdmin.sol";

/// @notice Narrow emergency surface exposed by HousePool.
interface IHousePoolEmergencyAdmin is IPerpsAdmin {

    /// @notice Returns whether LP epoch settlement is independently paused.
    function lpEpochSettlementPaused() external view returns (bool);

    /// @notice Pauses LP epoch settlement without pausing LP request admission.
    function pauseLpEpochSettlement() external;

    /// @notice Releases the LP epoch settlement hold.
    /// @dev HousePool restricts recovery to governance; the coordinator never invokes this selector.
    function unpauseLpEpochSettlement() external;

}
