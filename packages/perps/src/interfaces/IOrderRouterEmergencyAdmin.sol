// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsAdmin} from "@plether/perps/interfaces/IPerpsAdmin.sol";

/// @notice Narrow emergency surface exposed by the order router's administrative component.
interface IOrderRouterEmergencyAdmin is IPerpsAdmin {

    /// @notice Returns the inclusive order-id cutoff for opens permanently invalidated by a risk-off pause.
    /// @dev Close orders are unaffected. Zero means no committed open can be covered by the cutoff.
    /// @return Highest order id whose pending opens are invalidated
    function riskOffOrderCutoff() external view returns (uint64);

}
