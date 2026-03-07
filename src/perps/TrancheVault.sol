// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IHousePool} from "./interfaces/IHousePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TrancheVault
/// @notice ERC4626 share token for a HousePool tranche (senior or junior).
///         Routes all deposits/withdrawals through HousePool.
/// @custom:security-contact contact@plether.com
contract TrancheVault is ERC4626 {

    using SafeERC20 for IERC20;

    IHousePool public immutable POOL;
    bool public immutable IS_SENIOR;

    constructor(
        IERC20 _usdc,
        address _pool,
        bool _isSenior,
        string memory _name,
        string memory _symbol
    ) ERC4626(_usdc) ERC20(_name, _symbol) {
        POOL = IHousePool(_pool);
        IS_SENIOR = _isSenior;
    }

    /// @dev Virtual share offset mitigates ERC4626 first-depositor inflation attack
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    function totalAssets() public view override returns (uint256) {
        return IS_SENIOR ? POOL.seniorPrincipal() : POOL.juniorPrincipal();
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.redeem(shares, receiver, _owner);
    }

    function maxWithdraw(
        address _owner
    ) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(_owner), Math.Rounding.Floor);
        uint256 poolMax = IS_SENIOR ? POOL.getMaxSeniorWithdraw() : POOL.getMaxJuniorWithdraw();
        return ownerAssets < poolMax ? ownerAssets : poolMax;
    }

    function maxRedeem(
        address _owner
    ) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(_owner);
        uint256 poolMax = IS_SENIOR ? POOL.getMaxSeniorWithdraw() : POOL.getMaxJuniorWithdraw();
        uint256 maxShares = _convertToShares(poolMax, Math.Rounding.Floor);
        return ownerShares < maxShares ? ownerShares : maxShares;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        IERC20(asset()).forceApprove(address(POOL), assets);
        if (IS_SENIOR) {
            POOL.depositSenior(assets);
        } else {
            POOL.depositJunior(assets);
        }
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }
        _burn(_owner, shares);
        if (IS_SENIOR) {
            POOL.withdrawSenior(assets, receiver);
        } else {
            POOL.withdrawJunior(assets, receiver);
        }
        emit Withdraw(caller, receiver, _owner, assets, shares);
    }

}
