// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {AccountLensViewTypes} from "./AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "./ICfdEngineTypes.sol";

/// @notice Rich per-account diagnostic lens for audits, tests, and operator tooling.
interface ICfdEngineAccountLens {

    /// @notice Returns detailed clearinghouse bucket and reachability state for an account.
    /// @dev Legacy detailed account lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews` via `PerpsPublicLens`.
    /// @param account Account to inspect
    /// @return viewData Collateral, reachability, and claim balances for the account
    function getAccountCollateralView(
        address account
    ) external view returns (ICfdEngineTypes.AccountCollateralView memory viewData);

    /// @notice Returns the current withdrawable USDC for an account under engine-side guards.
    /// @param account Account to inspect
    /// @return withdrawableUsdc Free settlement amount currently withdrawable
    function getWithdrawableUsdc(
        address account
    ) external view returns (uint256 withdrawableUsdc);

    /// @notice Returns a compact accounting split for account custody, reservation, and trader claims.
    /// @param account Account to inspect
    /// @return viewData Compact ledger view
    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData);

    /// @notice Returns the full account ledger snapshot used by tests and richer read paths.
    /// @param account Account to inspect
    /// @return snapshot Full account ledger snapshot
    function getAccountLedgerSnapshot(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot);

}
