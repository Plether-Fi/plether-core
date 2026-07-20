// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice HousePool tranche-mutation hooks used by the configured senior and junior ERC4626 vaults.
/// @dev These selectors are not direct end-user deposit/withdraw entrypoints: the HousePool authorizes only configured
///      tranche vaults. LPs ordinarily interact with the appropriate vault, which handles shares and calls these hooks.
interface IPerpsLPActions {

    /// @notice Pulls USDC from a configured vault and adds it to senior principal.
    /// @dev Reconciles, requires any needed mark to satisfy active freshness policy, checkpoints engine carry, and
    ///      requires an unpaused pool, no unassigned-asset bootstrap, unimpaired senior principal, and the minimum
    ///      tranche deposit. User-facing vault deposits separately enforce seed and trading-lifecycle readiness before
    ///      calling this hook. Also raises the protected senior high-water mark.
    /// @param amount USDC amount to deposit (6 decimals)
    function depositSenior(
        uint256 amount
    ) external;

    /// @notice Removes senior principal and transfers USDC to a receiver for a configured vault.
    /// @dev Reconciles first, requires live withdrawals outside degraded mode and any needed mark to satisfy active
    ///      freshness policy, caps the amount by free cash and senior principal, checkpoints carry, and scales the
    ///      senior high-water mark. An authorized zero-amount withdrawal returns before those checks.
    /// @param amount USDC amount to withdraw (6 decimals)
    /// @param receiver Address receiving withdrawn USDC
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Pulls USDC from a configured vault and adds it to junior principal.
    /// @dev Applies the same reconciliation, mark-freshness, pause, bootstrap, senior-impairment, carry, and minimum-size
    ///      gates as the senior deposit hook. User-facing vault deposits separately enforce seed and trading-lifecycle
    ///      readiness before calling this hook.
    /// @param amount USDC amount to deposit (6 decimals)
    function depositJunior(
        uint256 amount
    ) external;

    /// @notice Removes junior principal and transfers USDC to a receiver for a configured vault.
    /// @dev Reconciles first, requires live withdrawals and any needed mark to satisfy active freshness policy, and
    ///      preserves free liquidity sufficient to cover senior principal. Checkpoints carry before reducing pool depth.
    /// @param amount USDC amount to withdraw (6 decimals)
    /// @param receiver Address receiving withdrawn USDC
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

}
