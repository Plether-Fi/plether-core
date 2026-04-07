// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Public trader-facing margin account surface stripped of internal reservation and bucket plumbing.
interface IMarginAccount {

    function depositMargin(
        uint256 amount
    ) external;

    function withdrawMargin(
        uint256 amount
    ) external;

    function getAccountEquityUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    function getWithdrawableUsdc(
        bytes32 accountId
    ) external view returns (uint256);
}
