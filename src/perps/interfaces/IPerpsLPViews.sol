// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact LP-facing read surface for senior and junior tranches.
interface IPerpsLPViews {

    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData);

}
