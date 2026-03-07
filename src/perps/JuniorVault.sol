// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IHousePool} from "./IHousePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title JuniorVault
/// @notice ERC4626 share token for the junior (risk-seeking) tranche.
///         Routes all deposits/withdrawals through HousePool.
contract JuniorVault is ERC4626 {

    using SafeERC20 for IERC20;

    IHousePool public immutable pool;

    constructor(
        IERC20 _usdc,
        address _pool
    ) ERC4626(_usdc) ERC20("Plether Junior LP", "juniorUSDC") {
        pool = IHousePool(_pool);
    }

    function totalAssets() public view override returns (uint256) {
        return pool.juniorPrincipal();
    }

    function maxWithdraw(
        address _owner
    ) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(_owner), Math.Rounding.Floor);
        uint256 poolMax = pool.getMaxJuniorWithdraw();
        return ownerAssets < poolMax ? ownerAssets : poolMax;
    }

    function maxRedeem(
        address _owner
    ) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(_owner);
        uint256 poolMax = pool.getMaxJuniorWithdraw();
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
        IERC20(asset()).forceApprove(address(pool), assets);
        pool.depositJunior(assets);
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
        pool.withdrawJunior(assets, receiver);
        emit Withdraw(caller, receiver, _owner, assets, shares);
    }

}
