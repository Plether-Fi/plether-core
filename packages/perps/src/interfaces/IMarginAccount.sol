// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Public trader-facing margin account surface stripped of internal reservation and bucket plumbing.
interface IMarginAccount {

    /// @notice Deposits USDC into the caller's canonical margin account.
    /// @param amount USDC amount to deposit
    function depositMargin(
        uint256 amount
    ) external;

    /// @notice Withdraws USDC from the caller's canonical margin account.
    /// @param amount USDC amount to withdraw
    function withdrawMargin(
        uint256 amount
    ) external;

    /// @notice Returns total account equity in settlement USDC.
    /// @param account Account to inspect
    function getAccountEquityUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns settlement equity that is not currently locked into margin buckets.
    /// @dev This is a clearinghouse-local view and does not account for engine withdrawal guards.
    /// @param account Account to inspect
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}
