// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Read surface implemented by the router-discoverable position-protection book.
interface IPositionProtectionViews {

    /// @notice Returns the account's pending-open, armed, triggered, or latched protection id.
    /// @param account Account to inspect.
    /// @return protectionId Active protection id, or zero when none exists.
    function activePositionProtectionId(
        address account
    ) external view returns (uint64 protectionId);

    /// @notice Returns a retained protection record, including terminal history.
    /// @param protectionId Protection identifier to inspect.
    /// @return protection Record data; an unknown id returns `None` and otherwise zero-valued fields.
    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection);

}
