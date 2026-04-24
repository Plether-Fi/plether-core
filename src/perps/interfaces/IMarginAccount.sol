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
        address account
    ) external view returns (uint256);

    /// @notice Returns settlement equity that is not currently locked into margin buckets.
    /// @dev This is a clearinghouse-local view and does not account for engine withdrawal guards.
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}
