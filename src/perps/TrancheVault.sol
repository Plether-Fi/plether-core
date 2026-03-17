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
    uint256 public constant DEPOSIT_COOLDOWN = 1 hours;

    mapping(address => uint256) public lastDepositTime;

    error TrancheVault__DepositCooldown();
    error TrancheVault__TransferDuringCooldown();
    error TrancheVault__TrancheImpaired();
    error TrancheVault__ThirdPartyDepositForExistingHolder();

    /// @param _usdc         Underlying USDC token used as the vault asset
    /// @param _pool         HousePool that holds USDC and manages the tranche waterfall
    /// @param _isSenior     True for the senior tranche, false for junior
    /// @param _name         ERC20 share token name
    /// @param _symbol       ERC20 share token symbol
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

    /// @notice Enforces a deposit cooldown on share transfers.
    ///         Prevents flash-deposit-then-transfer to bypass the withdrawal cooldown.
    ///         Propagates the sender's cooldown to the receiver if it is more recent.
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            if (block.timestamp < lastDepositTime[from] + DEPOSIT_COOLDOWN) {
                revert TrancheVault__TransferDuringCooldown();
            }
            if (lastDepositTime[to] < lastDepositTime[from]) {
                lastDepositTime[to] = lastDepositTime[from];
            }
        }
        super._update(from, to, amount);
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
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            return 0;
        }
        if (!POOL.isWithdrawalLive()) {
            return 0;
        }
        uint256 ownerAssets = _convertToAssets(balanceOf(_owner), Math.Rounding.Floor);
        uint256 poolMax = IS_SENIOR ? POOL.getMaxSeniorWithdraw() : POOL.getMaxJuniorWithdraw();
        return ownerAssets < poolMax ? ownerAssets : poolMax;
    }

    function maxRedeem(
        address _owner
    ) public view override returns (uint256) {
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            return 0;
        }
        if (!POOL.isWithdrawalLive()) {
            return 0;
        }
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
        // Only reset the withdrawal cooldown for meaningful deposits. A third party can reset a
        // victim's cooldown by depositing >=5% of their balance to the victim's address, but this
        // requires permanently donating that USDC — economically irrational griefing.
        uint256 previousBalance = balanceOf(receiver) - shares;
        uint256 meaningfulTopUpThreshold = previousBalance / 20;
        if (meaningfulTopUpThreshold == 0 && previousBalance > 0) {
            meaningfulTopUpThreshold = 1;
        }
        if (caller == receiver || previousBalance == 0 || shares >= meaningfulTopUpThreshold) {
            lastDepositTime[receiver] = block.timestamp;
        }
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            revert TrancheVault__DepositCooldown();
        }
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
