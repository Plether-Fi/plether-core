// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact protocol-wide read surface for product consumers.
interface IProtocolViews {

    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData);

}
