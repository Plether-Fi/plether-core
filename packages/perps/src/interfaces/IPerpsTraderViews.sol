// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Compact trader-facing read surface implemented by `PerpsPublicLens`.
interface IPerpsTraderViews {

    /// @notice Returns compact account equity, withdrawable balance, and queued margin state.
    /// @dev Monetary fields use 6-decimal USDC. The reported withdrawable amount comes from the diagnostic account
    ///      lens and is a conservative upper bound; callers should leave a buffer at strict collateral boundaries.
    /// @param account Account to inspect
    /// @return viewData Settlement equity, withdrawal bound, locked/reserved margin, and pending-order summary
    function getTraderAccount(
        address account
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData);

    /// @notice Returns compact current-position state.
    /// @dev Evaluates price PnL and liquidatability at the cached engine mark without enforcing mark freshness. PnL
    ///      excludes carry and VPI; the active FAD margin ratio replaces normal maintenance while FAD is active.
    /// @param account Account to inspect
    /// @return viewData Zero-valued when no position exists; otherwise cached-mark position and risk summary
    function getPosition(
        address account
    ) external view returns (PerpsViewTypes.PositionView memory viewData);

    /// @notice Returns currently pending delayed orders for an account.
    /// @dev Traverses live account-queue links in FIFO order. Committed margin comes from the clearinghouse reservation
    ///      ledger and execution bounty is clearinghouse-custodied even though it is attributed by the router.
    /// @param account Account to inspect
    /// @return pending Pending orders in account queue order
    function getPendingOrders(
        address account
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending);

    /// @notice Returns the account's pending-open, armed, or triggered position protection.
    /// @param account Account to inspect
    /// @return protection Active protection record, or a zero-valued `None` record when none exists
    function getActivePositionProtection(
        address account
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection);

    /// @notice Returns a retained position-protection record by id, including terminal history.
    /// @dev Historical enumeration is event-driven; this getter resolves one known protection id.
    /// @param protectionId Protection identifier to inspect
    /// @return protection Retained record, or a zero-valued `None` record for an unknown id
    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection);

    /// @notice Returns whether the account's current live position is liquidatable.
    /// @dev Uses the same cached-mark, no-freshness-check risk snapshot as `getPosition`: exact price risk uses dedicated
    ///      backing, while any carry left after projected eligible-free-settlement collection independently returns true.
    /// @param account Account to inspect
    /// @return Whether the current cached-mark position meets the active liquidation condition
    function isLiquidatable(
        address account
    ) external view returns (bool);

}
