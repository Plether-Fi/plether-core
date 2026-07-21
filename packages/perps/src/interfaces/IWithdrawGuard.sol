// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Post-debit hook that enforces open-position collateralization on clearinghouse withdrawals.
interface IWithdrawGuard {

    /// @notice Validates an account after the clearinghouse has provisionally debited a withdrawal.
    /// @dev Callable only by the configured clearinghouse. Accounts without a position pass. Open positions require
    ///      non-degraded mode and a cached mark fresh under the active live or frozen policy; the hook realizes carry
    ///      and requires equity above the stricter of initial and active maintenance/FAD margin. Although stateful, all
    ///      mutations roll back if the enclosing withdrawal reverts.
    /// @param account Cross-margin account whose post-withdrawal state is checked
    function checkWithdraw(
        address account
    ) external;

}
