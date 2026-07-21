// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @notice Compact LP-facing read surface implemented by `PerpsPublicLens` for senior and junior tranches.
interface IPerpsLPViews {

    /// @notice Returns compact senior tranche state.
    /// @dev Reads the configured ERC4626 vault and HousePool gates. A missing vault returns a zero-valued view; an
    ///      empty configured vault reports the lens's nominal share price. USDC fields use 6 decimals.
    /// @return viewData Senior assets, shares, share price, fee, withdrawal cap, and current availability flags
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns compact junior tranche state.
    /// @dev Reads the configured ERC4626 vault and HousePool gates. A missing vault returns a zero-valued view; an
    ///      empty configured vault reports the lens's nominal share price. USDC fields use 6 decimals.
    /// @return viewData Junior assets, shares, share price, fee, withdrawal cap, and current availability flags
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns high-level LP status flags.
    /// @dev Oracle freshness is the HousePool liquidity view's current `markFresh` result; `lastMarkTime` is the
    ///      cached engine mark's Unix publish timestamp.
    /// @return viewData Trading, withdrawal, mark-freshness, and oracle-frozen status
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData);

}
