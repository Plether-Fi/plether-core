// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact LP-facing read surface for senior and junior tranches.
interface IPerpsLPViews {

    /// @notice Returns compact senior tranche state.
    /// @return viewData Senior tranche balances, shares, and availability
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns compact junior tranche state.
    /// @return viewData Junior tranche balances, shares, and availability
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns high-level LP status flags.
    /// @return viewData Deposit, withdrawal, and lifecycle status flags
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData);

}
