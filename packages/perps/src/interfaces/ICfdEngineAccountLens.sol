// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Rich per-account diagnostic lens for audits, tests, and operator tooling.
/// @dev Monetary fields returned by this interface use 6-decimal USDC.
interface ICfdEngineAccountLens {

    /// @notice Returns detailed clearinghouse bucket and reachability state for an account.
    /// @dev Legacy detailed account lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews` via `PerpsPublicLens`.
    /// @param account Account to inspect
    /// @return viewData Clearinghouse custody, legacy close reachability, terminal reachability, and separate claims
    function getAccountCollateralView(
        address account
    ) external view returns (ICfdEngineTypes.AccountCollateralView memory viewData);

    /// @notice Returns a conservative upper bound on currently withdrawable USDC under engine-side guards.
    /// @dev Flat accounts return free settlement without applying degraded-mode or mark-freshness gates. For open
    ///      positions the view accounts for carry, the stricter of initial and active maintenance margin, degraded
    ///      mode, and cached-mark freshness. Because live withdrawal rejects equality at the collateral boundary,
    ///      withdrawing the exact reported headroom can still revert; callers should leave a small safety buffer.
    /// @param account Account to inspect
    /// @return withdrawableUsdc Conservative withdrawal upper bound in USDC
    function getWithdrawableUsdc(
        address account
    ) external view returns (uint256 withdrawableUsdc);

    /// @notice Returns a compact accounting split for account custody, reservation, and trader claims.
    /// @param account Account to inspect
    /// @return viewData Compact custody, reservation, order-count, and separate trader-claim ledger view
    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData);

    /// @notice Returns the full account ledger snapshot used by tests and richer read paths.
    /// @param account Account to inspect
    /// @return snapshot Full custody, reachability, cached-mark risk, reservation, and separate claim snapshot
    function getAccountLedgerSnapshot(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot);

}
