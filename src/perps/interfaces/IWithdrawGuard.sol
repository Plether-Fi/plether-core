// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Pre-withdrawal hook that prevents clearinghouse withdrawals while positions are open.
interface IWithdrawGuard {

    /// @notice Reverts if the account is not allowed to withdraw from the clearinghouse.
    ///         Implementations may inspect current clearinghouse balances after tentative debit.
    /// @param account Cross-margin account to check
    function checkWithdraw(
        address account
    ) external;

}
