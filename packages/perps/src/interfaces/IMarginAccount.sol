// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Public trader-facing margin account surface stripped of internal reservation and bucket plumbing.
/// @dev Monetary values use the settlement token's native units, expected to be 6-decimal USDC.
interface IMarginAccount {

    /// @notice Deposits USDC into the caller's canonical margin account.
    /// @dev Requires a positive amount and prior token allowance. Tokens are pulled from the caller, its internal
    ///      settlement balance is credited, and any open-position carry is then checkpointed or realized.
    /// @param amount USDC amount to deposit
    function depositMargin(
        uint256 amount
    ) external;

    /// @notice Withdraws USDC from the caller's canonical margin account.
    /// @dev Carry and engine withdrawal guards are applied after a provisional debit; the remaining settlement must
    ///      still cover all locked buckets. A zero amount is allowed but still runs the checks and hooks.
    /// @param amount USDC amount to withdraw
    function withdrawMargin(
        uint256 amount
    ) external;

    /// @notice Returns total account equity in settlement USDC.
    /// @dev Despite the legacy name, this is the clearinghouse's internal settlement balance and excludes unrealized
    ///      PnL and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Settlement balance in USDC
    function getAccountEquityUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns settlement equity that is not currently locked into margin buckets.
    /// @dev Equals `max(settlement balance - total locked margin, 0)`. This clearinghouse-local view excludes
    ///      unrealized PnL and does not account for engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Unencumbered settlement balance in USDC
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}
