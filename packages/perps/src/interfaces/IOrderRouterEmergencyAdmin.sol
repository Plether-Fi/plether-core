// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsAdmin} from "@plether/perps/interfaces/IPerpsAdmin.sol";

/// @notice Narrow emergency surface exposed by the order router's administrative component.
interface IOrderRouterEmergencyAdmin is IPerpsAdmin {

    /// @notice Returns the highest order id permanently invalidated by an administrative risk-off pause.
    /// @dev The cutoff is inclusive. A zero value means that no committed order id has been invalidated.
    /// @return Highest invalidated order id
    function riskOffOrderCutoff() external view returns (uint64);

}
