// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact protocol-wide read surface for product consumers.
interface IProtocolViews {

    /// @notice Returns high-level protocol runtime status flags.
    /// @return viewData Protocol phase, oracle, and degraded-mode status
    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData);

}
