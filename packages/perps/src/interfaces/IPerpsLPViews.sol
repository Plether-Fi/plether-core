// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @notice Compact LP-facing read surface implemented by `PerpsPublicLens` for senior and junior tranches.
interface IPerpsLPViews {

    /// @notice Returns compact senior tranche state.
    /// @dev Reads the configured ERC4626 vault and HousePool gates. A missing vault returns a zero-valued view; an
    ///      empty configured vault reports the lens's nominal share price. Senior effective supply equals raw supply,
    ///      and its maintenance-fee fields are zero. USDC fields use 6 decimals.
    /// @return viewData Senior assets, raw/effective shares, share price, fees, withdrawal cap, and availability flags
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns compact junior tranche state.
    /// @dev Reads the configured ERC4626 vault and HousePool gates. A missing vault returns a zero-valued view; an
    ///      empty configured vault reports the lens's nominal share price. Effective supply includes uncheckpointed
    ///      maintenance-fee shares so the displayed price matches current Junior conversion economics. USDC fields
    ///      use 6 decimals.
    /// @return viewData Junior assets, raw/effective shares, share price, fees, withdrawal cap, and availability flags
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData);

    /// @notice Returns high-level LP status flags.
    /// @dev Oracle freshness is the HousePool liquidity view's current `markFresh` result; `lastMarkTime` is the
    ///      cached engine mark's Unix publish timestamp. The settlement-hold flag distinguishes intentional
    ///      governance containment from oracle or solvency liveness failures.
    /// @return viewData Trading, withdrawal, settlement-hold, mark-freshness, and oracle-frozen status
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData);

    /// @notice Returns request timing, matured queue heads, and settlement gates for one tranche.
    /// @dev `cutoffEpoch` is the latest epoch eligible for settlement now. `nextRequestCutoffTime` is the future
    ///      timestamp when the epoch targeted by new deposits and redemptions will next change. The settlement-hold
    ///      flag is independent from the LP-entry pause and does not imply request admission is disabled.
    /// @param isSenior True for the Senior tranche and false for the Junior tranche.
    /// @return viewData Shared epoch and request window, matured work, backlog flags, and runtime gates.
    function getTrancheQueues(
        bool isSenior
    ) external view returns (PerpsViewTypes.TrancheQueueView memory viewData);

    /// @notice Returns one controller's pending, claimable, rejected, and refundable request state.
    /// @param isSenior True for the Senior tranche and false for the Junior tranche.
    /// @param requestId Shared LP epoch used as the asynchronous request id.
    /// @param controller Account that controls the request.
    /// @return viewData Pending estimates and exact terminal/claim balances for both async directions.
    function getLpRequestState(
        bool isSenior,
        uint256 requestId,
        address controller
    ) external view returns (PerpsViewTypes.LpRequestStateView memory viewData);

}
