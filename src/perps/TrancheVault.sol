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

    address public seedReceiver;
    uint256 public seedShareFloor;

    error TrancheVault__DepositCooldown();
    error TrancheVault__TransferDuringCooldown();
    error TrancheVault__TrancheImpaired();
    error TrancheVault__ThirdPartyDepositForExistingHolder();
    error TrancheVault__NotPool();
    error TrancheVault__SeedFloorBreached();
    error TrancheVault__InvalidSeedPosition();
    error TrancheVault__TerminallyWiped();
    error TrancheVault__TradingNotActive();

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
        if (from == seedReceiver && from != address(0) && balanceOf(from) - amount < seedShareFloor) {
            revert TrancheVault__SeedFloorBreached();
        }
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

    /// @notice Returns the tranche assets from the pending post-reconcile HousePool state.
    function totalAssets() public view override returns (uint256) {
        (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc,,) = POOL.getPendingTrancheState();
        return IS_SENIOR ? seniorPrincipalUsdc : juniorPrincipalUsdc;
    }

    /// @notice Deposits assets into the tranche after reconciling pool accounting and lifecycle gates.
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        POOL.reconcile();
        _requireLifecycleActiveForOrdinaryDeposit();
        _requireActiveTranche();
        return super.deposit(assets, receiver);
    }

    /// @notice Mints tranche shares after reconciling pool accounting and lifecycle gates.
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        POOL.reconcile();
        _requireLifecycleActiveForOrdinaryDeposit();
        _requireActiveTranche();
        return super.mint(shares, receiver);
    }

    /// @notice Returns the current max deposit if lifecycle, freshness, and impairment gates allow deposits.
    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        if (!_canDepositNow()) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /// @notice Returns the current max mint if lifecycle, freshness, and impairment gates allow deposits.
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        if (!_canDepositNow()) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /// @notice Withdraws tranche assets after reconciling pool accounting.
    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.withdraw(assets, receiver, _owner);
    }

    /// @notice Redeems tranche shares after reconciling pool accounting.
    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        POOL.reconcile();
        return super.redeem(shares, receiver, _owner);
    }

    /// @notice Returns the withdrawable asset amount after cooldown and pool-level withdrawal gates.
    function maxWithdraw(
        address _owner
    ) public view override returns (uint256) {
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            return 0;
        }
        if (!POOL.isWithdrawalLive()) {
            return 0;
        }
        uint256 ownerShares = _unlockedOwnerShares(_owner);
        uint256 ownerAssets = _convertToAssets(ownerShares, Math.Rounding.Floor);
        (,, uint256 maxSeniorWithdrawUsdc, uint256 maxJuniorWithdrawUsdc) = POOL.getPendingTrancheState();
        uint256 poolMax = IS_SENIOR ? maxSeniorWithdrawUsdc : maxJuniorWithdrawUsdc;
        return ownerAssets < poolMax ? ownerAssets : poolMax;
    }

    /// @notice Returns the redeemable share amount after cooldown and pool-level withdrawal gates.
    function maxRedeem(
        address _owner
    ) public view override returns (uint256) {
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            return 0;
        }
        if (!POOL.isWithdrawalLive()) {
            return 0;
        }
        uint256 ownerShares = _unlockedOwnerShares(_owner);
        (,, uint256 maxSeniorWithdrawUsdc, uint256 maxJuniorWithdrawUsdc) = POOL.getPendingTrancheState();
        uint256 poolMax = IS_SENIOR ? maxSeniorWithdrawUsdc : maxJuniorWithdrawUsdc;
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
        uint256 previousBalance = balanceOf(receiver) - shares;
        if (caller == receiver || previousBalance == 0) {
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

    /// @notice Mints shares to explicitly bootstrap previously quarantined pool assets into this tranche.
    /// @dev Only the pool may call this. The pool must have already assigned matching assets to the tranche principal.
    function bootstrapMint(
        uint256 shares,
        address receiver
    ) external {
        if (msg.sender != address(POOL)) {
            revert TrancheVault__NotPool();
        }
        _mint(receiver, shares);
        lastDepositTime[receiver] = block.timestamp;
    }

    /// @notice Registers or increases the permanent seed-share floor for this tranche.
    /// @dev The pool must mint the corresponding shares before or within the same flow.
    function configureSeedPosition(
        address receiver,
        uint256 floorShares
    ) external {
        if (msg.sender != address(POOL)) {
            revert TrancheVault__NotPool();
        }
        if (receiver == address(0) || floorShares == 0) {
            revert TrancheVault__InvalidSeedPosition();
        }
        if (seedReceiver != address(0) && seedReceiver != receiver) {
            revert TrancheVault__InvalidSeedPosition();
        }
        if (balanceOf(receiver) < floorShares || floorShares < seedShareFloor) {
            revert TrancheVault__InvalidSeedPosition();
        }
        seedReceiver = receiver;
        seedShareFloor = floorShares;
    }

    function _unlockedOwnerShares(
        address _owner
    ) internal view returns (uint256 ownerShares) {
        ownerShares = balanceOf(_owner);
        if (_owner == seedReceiver && seedReceiver != address(0)) {
            ownerShares = ownerShares > seedShareFloor ? ownerShares - seedShareFloor : 0;
        }
    }

    function _isTerminallyWiped() internal view returns (bool) {
        return totalSupply() > 0 && totalAssets() == 0;
    }

    function _requireActiveTranche() internal view {
        if (_isTerminallyWiped()) {
            revert TrancheVault__TerminallyWiped();
        }
    }

    function _requireLifecycleActiveForOrdinaryDeposit() internal view {
        if (!_ordinaryDepositsAllowed()) {
            revert TrancheVault__TradingNotActive();
        }
    }

    function _ordinaryDepositsAllowed() internal view returns (bool) {
        return POOL.canAcceptOrdinaryDeposits();
    }

    function _canDepositNow() internal view returns (bool) {
        return !_isTerminallyWiped() && POOL.canAcceptTrancheDeposits(IS_SENIOR);
    }

}
