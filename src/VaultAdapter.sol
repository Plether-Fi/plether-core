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
/// @notice ERC4626-compliant wrapper that deposits into a MetaMorpho vault for yield.
/// @dev Interchangeable with other yield adapters. Only accepts deposits from SyntheticSplitter.
contract VaultAdapter is ERC4626, Ownable2Step, IYieldAdapter {

    using SafeERC20 for IERC20;

    /// @notice MetaMorpho vault (ERC4626) that generates yield.
    IERC4626 public immutable VAULT;

    /// @notice SyntheticSplitter authorized to deposit.
    address public immutable SPLITTER;

    error VaultAdapter__OnlySplitter();
    error VaultAdapter__InvalidAddress();
    error VaultAdapter__InvalidVault();
    error VaultAdapter__CannotRescueUnderlying();
    error VaultAdapter__CannotRescueVaultShares();

    /// @param _asset Underlying asset (USDC).
    /// @param _vault MetaMorpho vault address (must have same underlying asset).
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

    /// @notice Returns total USDC value of this adapter's vault position.
    function totalAssets() public view override returns (uint256) {
        uint256 shares = VAULT.balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        return VAULT.convertToAssets(shares);
    }

    /// @dev Deposits assets to MetaMorpho vault after ERC4626 share minting.
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

    /// @dev Withdraws assets from MetaMorpho vault before ERC4626 share burning.
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

    /// @notice No-op — MetaMorpho handles interest accrual internally.
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

}
