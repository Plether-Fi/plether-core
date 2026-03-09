// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IWithdrawGuard {

    /// @notice Reverts if the account is not allowed to withdraw from the clearinghouse.
    function checkWithdraw(
        bytes32 accountId
    ) external view;

}
