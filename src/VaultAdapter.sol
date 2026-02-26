// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VaultAdapter
/// @custom:security-contact contact@plether.com
/// @notice ERC4626-compliant wrapper that deposits into a Morpho vault for yield.
/// @dev Interchangeable with other yield adapters. Only accepts deposits from SyntheticSplitter.
contract VaultAdapter is ERC4626, Ownable2Step, IYieldAdapter {

    using SafeERC20 for IERC20;

    /// @notice Morpho vault (ERC4626) that generates yield.
    IERC4626 public immutable VAULT;

    /// @notice SyntheticSplitter authorized to deposit.
    address public immutable SPLITTER;

    /// @notice Thrown when caller is not the SyntheticSplitter.
    error VaultAdapter__OnlySplitter();

    /// @notice Thrown when a zero address is provided.
    error VaultAdapter__InvalidAddress();

    /// @notice Thrown when vault's underlying asset doesn't match this adapter's asset.
    error VaultAdapter__InvalidVault();

    /// @notice Thrown when attempting to rescue the underlying asset.
    error VaultAdapter__CannotRescueUnderlying();

    /// @notice Thrown when attempting to rescue vault share tokens.
    error VaultAdapter__CannotRescueVaultShares();

    /// @notice Thrown when a reward claim call fails.
    error VaultAdapter__CallFailed();

    /// @notice Thrown when claimRewards targets a forbidden address.
    error VaultAdapter__ForbiddenTarget();

    /// @notice Deploys adapter targeting a Morpho vault.
    /// @param _asset Underlying asset (USDC).
    /// @param _vault Morpho vault address (must have same underlying asset).
    /// @param _owner Admin address for rescue operations.
    /// @param _splitter SyntheticSplitter authorized to deposit.
    constructor(
        IERC20 _asset,
        address _vault,
        address _owner,
        address _splitter
    ) ERC4626(_asset) ERC20("Vault Yield Wrapper", "vyUSDC") Ownable(_owner) {
        if (_vault == address(0)) {
            revert VaultAdapter__InvalidAddress();
        }
        if (_splitter == address(0)) {
            revert VaultAdapter__InvalidAddress();
        }
        if (IERC4626(_vault).asset() != address(_asset)) {
            revert VaultAdapter__InvalidVault();
        }

        VAULT = IERC4626(_vault);
        SPLITTER = _splitter;

        _asset.safeIncreaseAllowance(_vault, type(uint256).max);
    }

    // ==========================================
    // ERC-4626 OVERRIDES
    // ==========================================

    /// @notice Maximum USDC withdrawable by owner.
    /// @dev Does not cap by VAULT.maxWithdraw() — Morpho Vault V2 returns 0 for all max*
    ///      functions due to its gate system. Actual liquidity is enforced at withdrawal time.
    function maxWithdraw(
        address owner
    ) public view override returns (uint256) {
        return previewRedeem(balanceOf(owner));
    }

    /// @notice Maximum adapter shares redeemable by owner.
    /// @dev See maxWithdraw for rationale on not delegating to vault.
    function maxRedeem(
        address owner
    ) public view override returns (uint256) {
        return balanceOf(owner);
    }

    /// @notice Maximum USDC depositable.
    /// @dev See maxWithdraw for rationale on not delegating to vault.
    function maxDeposit(
        address
    ) public view override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum adapter shares mintable.
    /// @dev See maxWithdraw for rationale on not delegating to vault.
    function maxMint(
        address
    ) public view override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns total USDC value of this adapter's vault position.
    /// @return Total assets held in the Morpho vault, converted from vault shares.
    function totalAssets() public view override returns (uint256) {
        uint256 shares = VAULT.balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        return VAULT.convertToAssets(shares);
    }

    /// @dev Deposits assets to Morpho vault after ERC4626 share minting.
    /// @param caller Must be SPLITTER.
    /// @param receiver Receiver of adapter shares.
    /// @param assets Amount of USDC to deposit.
    /// @param shares Amount of adapter shares minted.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != SPLITTER) {
            revert VaultAdapter__OnlySplitter();
        }

        super._deposit(caller, receiver, assets, shares);

        VAULT.deposit(assets, address(this));
    }

    /// @dev Withdraws assets from Morpho vault before ERC4626 share burning.
    /// @param caller Caller requesting withdrawal.
    /// @param receiver Receiver of withdrawn USDC.
    /// @param owner Owner of adapter shares being burned.
    /// @param assets Amount of USDC to withdraw.
    /// @param shares Amount of adapter shares burned.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        VAULT.withdraw(assets, address(this), address(this));

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ==========================================
    // YIELD ADAPTER INTERFACE
    // ==========================================

    /// @notice No-op — Morpho vault accrues interest on underlying markets during deposit/withdraw.
    /// @dev View functions (totalAssets, convertToAssets) may lag by a few blocks of unaccrued
    ///      interest across the vault's markets. This is negligible for an actively-used vault
    ///      and self-corrects on the next state-changing interaction.
    function accrueInterest() external {}

    // ==========================================
    // SAFETY
    // ==========================================

    /// @notice Recovers stuck tokens (excluding the underlying asset and vault shares).
    /// @param token Token to rescue.
    /// @param to Recipient address.
    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (token == asset()) {
            revert VaultAdapter__CannotRescueUnderlying();
        }
        if (token == address(VAULT)) {
            revert VaultAdapter__CannotRescueVaultShares();
        }
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Claims rewards from an external distributor (Merkl, URD, etc.).
    /// @dev Reward tokens land in this contract; use rescueToken() to extract them.
    /// @param target Distributor contract to call.
    /// @param data ABI-encoded call data for the claim function.
    function claimRewards(
        address target,
        bytes calldata data
    ) external onlyOwner {
        if (target == asset() || target == address(VAULT) || target == address(this)) {
            revert VaultAdapter__ForbiddenTarget();
        }
        (bool success,) = target.call(data);
        if (!success) {
            revert VaultAdapter__CallFailed();
        }
    }

}
