// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @title TrancheVault
/// @notice ERC-4626 share vault for either the senior or junior tranche of a `HousePool`.
/// @dev Active tranche assets are custodied and accounted for by `POOL`; this contract escrows assets awaiting
///      delayed-deposit finalization and shares awaiting claim. Immediate entry is available only while the pool's
///      lifecycle and risk gates permit it, while delayed requests batch entrants into future pricing epochs.
///      Withdrawals and ordinary share transfers are cooldown-gated, and a configured seed-share floor is permanent.
///      Asset amounts use the underlying token's units (expected to be USDC with 6 decimals). The ERC-4626 virtual
///      offset adds 3 decimals to the share token and mitigates first-depositor inflation attacks.
/// @custom:security-contact contact@plether.com
contract TrancheVault is ERC4626 {

    using SafeERC20 for IERC20;

    /// @notice House pool that custodies the active assets and maintains this vault's tranche accounting.
    IHousePool public immutable POOL;

    /// @notice Whether this vault represents the senior tranche (`true`) or junior tranche (`false`).
    bool public immutable IS_SENIOR;

    /// @notice Cooldown applied to withdrawals and ordinary share transfers, in seconds.
    /// @dev Immediate deposits, bootstrap mints, and successful withdrawals set the account's cooldown timestamp.
    uint256 public constant DEPOSIT_COOLDOWN = 1 hours;

    /// @notice Duration of each delayed-deposit epoch, in seconds.
    uint256 public constant DEPOSIT_EPOCH_DURATION = 1 hours;

    /// @notice Number of epoch indices between a request's submission epoch and activation epoch.
    uint256 public constant DEPOSIT_ACTIVATION_EPOCH_DELAY = 2;

    /// @notice Aggregate asset and share accounting for one delayed-deposit epoch.
    /// @dev `assets` is the aggregate USDC contribution basis assigned to the epoch: the tokens are escrowed here
    ///      before finalization and deposited into `POOL` at finalization. `shares` is then fixed and held by this
    ///      vault until claimed. `claimedAssets` and `claimedShares` track completed pro rata claims; the last asset
    ///      claimant receives all remaining shares so rounding dust is fully allocated.
    struct DepositEpoch {
        /// @dev Underlying assets assigned to the epoch, in USDC units.
        uint256 assets;
        /// @dev Vault shares minted at finalization and escrowed for claimants.
        uint256 shares;
        /// @dev Contribution basis whose corresponding shares have been claimed, in USDC units.
        uint256 claimedAssets;
        /// @dev Vault shares already distributed to claimants.
        uint256 claimedShares;
        /// @dev Whether the epoch price has been fixed and its assets deposited into `POOL`.
        bool finalized;
    }

    /// @notice Cooldown anchor timestamp for each share owner, in Unix seconds.
    /// @dev The timestamp is propagated to recipients of ordinary transfers when it would tighten their cooldown.
    mapping(address => uint256) public lastDepositTime;

    /// @notice Returns an epoch's contributed assets, finalized shares, claimed totals, and finalization status.
    mapping(uint256 => DepositEpoch) public depositEpochs;

    /// @notice Outstanding deposit contribution basis owned by a receiver in an epoch, in USDC units.
    mapping(address => mapping(uint256 => uint256)) public pendingDepositAssets;

    /// @notice Account required to retain the permanent seed-share floor, or the zero address before configuration.
    address public seedReceiver;

    /// @notice Minimum vault-share balance that `seedReceiver` must permanently retain.
    uint256 public seedShareFloor;

    /// @notice A withdrawal or redemption was attempted before the owner's cooldown expired.
    error TrancheVault__DepositCooldown();

    /// @notice An ordinary share transfer was attempted before the sender's cooldown expired.
    error TrancheVault__TransferDuringCooldown();

    /// @notice Reserved for tranche-impairment failures; current entry paths surface pool gates or pool errors.
    error TrancheVault__TrancheImpaired();

    /// @notice A third party attempted to deposit for a receiver that already owns vault shares.
    error TrancheVault__ThirdPartyDepositForExistingHolder();

    /// @notice A pool-only bootstrap or seed operation was called by another account.
    error TrancheVault__NotPool();

    /// @notice A transfer or burn would reduce the seed receiver below the configured share floor.
    error TrancheVault__SeedFloorBreached();

    /// @notice A seed receiver or floor is zero, changes the established receiver, exceeds its balance, or decreases.
    error TrancheVault__InvalidSeedPosition();

    /// @notice A deposit was attempted after the tranche lost all assets while shares remained outstanding.
    error TrancheVault__TerminallyWiped();

    /// @notice An ordinary immediate or delayed entry was attempted before the seeded pool activated trading.
    error TrancheVault__TradingNotActive();

    /// @notice An immediate or delayed entry's asset amount is below the pool's minimum tranche deposit.
    error TrancheVault__DepositTooSmall();

    /// @notice A withdrawal or redemption is zero or below the minimum without fully exiting unlocked shares.
    error TrancheVault__WithdrawalTooSmall();

    /// @notice A delayed deposit was requested while the pool's tranche-deposit gates were closed.
    error TrancheVault__DepositsUnavailable();

    /// @notice A delayed-deposit epoch was finalized before its activation timestamp.
    error TrancheVault__DepositEpochNotActive();

    /// @notice Cancellation was attempted at or after activation without finalization-blocking senior impairment.
    error TrancheVault__DepositEpochAlreadyActive();

    /// @notice An operation requiring an unfinalized deposit epoch was attempted after finalization.
    error TrancheVault__DepositEpochFinalized();

    /// @notice Deposit shares were claimed before the epoch was finalized.
    error TrancheVault__DepositEpochNotFinalized();

    /// @notice Finalization was attempted for an epoch with no pending assets.
    error TrancheVault__DepositEpochEmpty();

    /// @notice The caller has no pending assets in the specified epoch.
    error TrancheVault__NoPendingDeposit();

    /// @notice Finalization or claim would mint or allocate zero shares.
    error TrancheVault__ClaimSharesZero();

    /// @notice A delayed deposit specified the zero address as its receiver.
    error TrancheVault__ZeroAddress();

    /// @notice Emitted when assets are escrowed for a future delayed-deposit epoch.
    /// @param caller Account that supplied the assets.
    /// @param owner Account that owns the pending deposit and may cancel or claim it.
    /// @param epochId Activation epoch assigned to the request.
    /// @param assets Underlying asset amount escrowed, in USDC units.
    event DepositRequested(address indexed caller, address indexed owner, uint256 indexed epochId, uint256 assets);

    /// @notice Emitted when a pending deposit is cancelled and its escrowed assets are returned.
    /// @param owner Pending-deposit owner that received the refund.
    /// @param epochId Epoch from which the request was removed.
    /// @param assets Underlying asset amount refunded, in USDC units.
    event DepositRequestCancelled(address indexed owner, uint256 indexed epochId, uint256 assets);

    /// @notice Emitted when an activation epoch's assets are deposited and its claimant shares are minted.
    /// @param epochId Finalized activation epoch.
    /// @param isSenior Whether the assets were deposited into the senior tranche.
    /// @param assets Aggregate underlying assets deposited into the pool, in USDC units.
    /// @param shares Aggregate vault shares minted to claimant escrow.
    event DepositEpochFinalized(uint256 indexed epochId, bool indexed isSenior, uint256 assets, uint256 shares);

    /// @notice Emitted when a pending-deposit owner receives its finalized shares.
    /// @param owner Pending-deposit owner receiving the shares.
    /// @param epochId Finalized epoch from which shares were claimed.
    /// @param assets Owner's deposit contribution basis used for the allocation, in USDC units.
    /// @param shares Vault shares transferred to the owner.
    event DepositSharesClaimed(address indexed owner, uint256 indexed epochId, uint256 assets, uint256 shares);

    /// @notice Creates a share vault permanently bound to one house-pool tranche.
    /// @dev Deployment must supply the intended asset and pool; this constructor does not validate `_pool` or its
    ///      relationship to the selected tranche.
    /// @param _usdc Underlying ERC-20 asset, expected to be USDC with 6 decimals.
    /// @param _pool HousePool that custodies USDC and manages the tranche waterfall.
    /// @param _isSenior True for the senior tranche; false for the junior tranche.
    /// @param _name ERC-20 share-token name.
    /// @param _symbol ERC-20 share-token symbol.
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

    /// @dev Returns the virtual share offset used by ERC-4626 conversion math.
    /// @return Number of decimals added to the underlying asset's decimals; always 3.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Enforces the permanent seed floor and the sender's cooldown on ordinary share transfers. The more recent
    ///      cooldown anchor is propagated to the receiver. Minting, burning, and transfers of escrowed shares from
    ///      this vault are exempt from transfer cooldown enforcement.
    /// @param from Account whose share balance decreases, or the zero address for a mint.
    /// @param to Account whose share balance increases, or the zero address for a burn.
    /// @param amount Share amount transferred, minted, or burned.
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == seedReceiver && from != address(0) && balanceOf(from) - amount < seedShareFloor) {
            revert TrancheVault__SeedFloorBreached();
        }
        if (from != address(0) && to != address(0) && from != address(this)) {
            if (block.timestamp < lastDepositTime[from] + DEPOSIT_COOLDOWN) {
                revert TrancheVault__TransferDuringCooldown();
            }
            if (lastDepositTime[to] < lastDepositTime[from]) {
                lastDepositTime[to] = lastDepositTime[from];
            }
        }
        super._update(from, to, amount);
    }

    /// @notice Returns this tranche's active assets from the pool's simulated post-reconcile state.
    /// @dev Excludes underlying assets escrowed in unfinalized deposit epochs because they have not entered the
    ///      tranche.
    /// @return Active senior or junior tranche principal, in USDC units.
    function totalAssets() public view override returns (uint256) {
        (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc,,) = POOL.getPendingTrancheState();
        return IS_SENIOR ? seniorPrincipalUsdc : juniorPrincipalUsdc;
    }

    /// @notice Converts assets to shares using the current deposit-side NAV estimate.
    /// @dev Uses the pool's simulated deposit-side reconcile state and does not apply the frozen-oracle LP fee.
    /// @param assets Underlying asset amount to convert, in USDC units.
    /// @return Equivalent vault-share amount, rounded down.
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToSharesUsingAssets(assets, _depositPricingAssets(), Math.Rounding.Floor);
    }

    /// @notice Returns the current delayed-deposit epoch id.
    /// @return Current Unix timestamp divided by `DEPOSIT_EPOCH_DURATION`.
    function currentDepositEpoch() public view returns (uint256) {
        return block.timestamp / DEPOSIT_EPOCH_DURATION;
    }

    /// @notice Returns the start timestamp for a delayed-deposit epoch.
    /// @param epochId Deposit epoch id.
    /// @return Epoch activation timestamp, in Unix seconds.
    function depositEpochStart(
        uint256 epochId
    ) public pure returns (uint256) {
        return epochId * DEPOSIT_EPOCH_DURATION;
    }

    /// @notice Escrows assets for a delayed deposit assigned to the current epoch plus the activation delay.
    /// @dev Requires a nonterminal tranche, the pool's active seed/trading lifecycle and delayed-deposit gate, a
    ///      nonzero receiver, and at least the pool minimum. Transfers assets from the caller into this vault without
    ///      minting shares or changing a cooldown. `receiver` owns the resulting pending balance and is the only
    ///      account that can cancel or claim it. A third party may fund a receiver only while that receiver has no
    ///      active vault shares.
    /// @param assets Underlying asset amount to escrow, in USDC units.
    /// @param receiver Account that owns and may later cancel or claim the pending deposit.
    /// @return epochId Activation epoch assigned to the request.
    function requestDeposit(
        uint256 assets,
        address receiver
    ) public returns (uint256 epochId) {
        _requireRequestDepositPreflight(assets, receiver);

        epochId = currentDepositEpoch() + DEPOSIT_ACTIVATION_EPOCH_DELAY;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        depositEpochs[epochId].assets += assets;
        pendingDepositAssets[receiver][epochId] += assets;
        emit DepositRequested(msg.sender, receiver, epochId, assets);
    }

    /// @notice Cancels the caller's pending deposit and refunds its escrowed assets.
    /// @dev Cancellation is available before activation. At or after activation it remains available only when the
    ///      pool reports that senior impairment would block finalization. The epoch must not have been finalized.
    /// @param epochId Epoch containing the caller's pending deposit.
    /// @return assets Underlying asset amount returned to the caller, in USDC units.
    function cancelPendingDeposit(
        uint256 epochId
    ) public returns (uint256 assets) {
        bool activeEpoch = block.timestamp >= depositEpochStart(epochId);
        if (activeEpoch && !POOL.isSeniorImpairedAfterPendingDepositReconcile()) {
            revert TrancheVault__DepositEpochAlreadyActive();
        }
        DepositEpoch storage epoch = depositEpochs[epochId];
        if (epoch.finalized) {
            revert TrancheVault__DepositEpochFinalized();
        }
        assets = pendingDepositAssets[msg.sender][epochId];
        if (assets == 0) {
            revert TrancheVault__NoPendingDeposit();
        }

        pendingDepositAssets[msg.sender][epochId] = 0;
        epoch.assets -= assets;
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit DepositRequestCancelled(msg.sender, epochId, assets);
    }

    /// @notice Permissionlessly prices a matured deposit epoch and deposits its assets into the house pool.
    /// @dev Prices the full batch at the current deposit-side NAV, including any active frozen-oracle LP fee. The
    ///      aggregate assets are moved into `POOL`, and the resulting shares are minted to this vault as claimant
    ///      escrow. Pool deposit gates and reconciliation checks still apply at finalization time.
    /// @param epochId Activated, nonempty epoch to finalize.
    /// @return shares Vault shares minted to this vault for later claimant distribution.
    function finalizeDepositEpoch(
        uint256 epochId
    ) public returns (uint256 shares) {
        if (block.timestamp < depositEpochStart(epochId)) {
            revert TrancheVault__DepositEpochNotActive();
        }
        DepositEpoch storage epoch = depositEpochs[epochId];
        if (epoch.finalized) {
            revert TrancheVault__DepositEpochFinalized();
        }
        uint256 assets = epoch.assets;
        if (assets == 0) {
            revert TrancheVault__DepositEpochEmpty();
        }

        shares = previewDeposit(assets);
        if (shares == 0) {
            revert TrancheVault__ClaimSharesZero();
        }
        epoch.shares = shares;
        epoch.finalized = true;

        IERC20(asset()).forceApprove(address(POOL), assets);
        if (IS_SENIOR) {
            POOL.depositSenior(assets);
        } else {
            POOL.depositJunior(assets);
        }
        _mint(address(this), shares);

        emit DepositEpochFinalized(epochId, IS_SENIOR, assets, shares);
    }

    /// @notice Claims the caller's tranche shares for its pending assets in a finalized epoch.
    /// @dev Allocates shares pro rata, rounded down, except that the last asset claimant receives all remaining shares.
    ///      Releases shares from this vault's escrow without restarting the receiver's cooldown and emits both
    ///      `DepositSharesClaimed` and the ERC-4626 `Deposit` event.
    /// @param epochId Finalized epoch containing the caller's pending deposit.
    /// @return shares Vault shares transferred to the caller.
    function claimDepositShares(
        uint256 epochId
    ) public returns (uint256 shares) {
        DepositEpoch storage epoch = depositEpochs[epochId];
        if (!epoch.finalized) {
            revert TrancheVault__DepositEpochNotFinalized();
        }
        uint256 assets = pendingDepositAssets[msg.sender][epochId];
        if (assets == 0) {
            revert TrancheVault__NoPendingDeposit();
        }

        uint256 remainingAssets = epoch.assets - epoch.claimedAssets;
        if (assets == remainingAssets) {
            shares = epoch.shares - epoch.claimedShares;
        } else {
            shares = Math.mulDiv(assets, epoch.shares, epoch.assets, Math.Rounding.Floor);
        }
        if (shares == 0) {
            revert TrancheVault__ClaimSharesZero();
        }
        pendingDepositAssets[msg.sender][epochId] = 0;
        epoch.claimedAssets += assets;
        epoch.claimedShares += shares;
        _transfer(address(this), msg.sender, shares);

        emit DepositSharesClaimed(msg.sender, epochId, assets, shares);
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    /// @notice Immediately deposits underlying assets and mints tranche shares when the pool permits instant entry.
    /// @dev Requires a nonterminal tranche, the active seed/trading lifecycle, all instant pool gates, and the pool
    ///      minimum deposit. Pulls assets from the caller and routes them into `POOL`. The receiver's cooldown starts
    ///      at the current timestamp. A third party may fund a receiver only while that receiver has no active vault
    ///      shares. During frozen-oracle mode the configured LP entry fee reduces the shares minted rather than the
    ///      assets deposited.
    /// @param assets Underlying asset amount to deposit, in USDC units.
    /// @param receiver Account receiving the minted vault shares.
    /// @return Vault shares minted to `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        _requireActiveTranche();
        _requireLifecycleActiveForOrdinaryDeposit();
        if (!POOL.canAcceptInstantTrancheDeposits(IS_SENIOR)) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, 0);
        }
        _requireMinimumDeposit(assets);
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps > 0) {
            uint256 shares = previewDeposit(assets);
            _deposit(msg.sender, receiver, assets, shares);
            return shares;
        }
        return super.deposit(assets, receiver);
    }

    /// @notice Immediately mints an exact amount of tranche shares when the pool permits instant entry.
    /// @dev Requires a nonterminal tranche, the active seed/trading lifecycle, all instant pool gates, and a quoted
    ///      asset amount at least equal to the pool minimum. Pulls the required assets from the caller and routes them
    ///      into `POOL`. The receiver's cooldown starts at the current timestamp. A third party may fund a receiver
    ///      only while that receiver has no active vault shares. During frozen-oracle mode the asset quote is grossed
    ///      up for the configured LP entry fee.
    /// @param shares Exact vault-share amount to mint.
    /// @param receiver Account receiving the minted vault shares.
    /// @return Underlying assets supplied by the caller, in USDC units.
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        _requireActiveTranche();
        _requireLifecycleActiveForOrdinaryDeposit();
        if (!POOL.canAcceptInstantTrancheDeposits(IS_SENIOR)) {
            revert ERC4626ExceededMaxMint(receiver, shares, 0);
        }
        _requireMinimumDeposit(previewMint(shares));
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps > 0) {
            uint256 assets = previewMint(shares);
            _deposit(msg.sender, receiver, assets, shares);
            return assets;
        }
        return super.mint(shares, receiver);
    }

    /// @notice Previews shares minted for an asset deposit, net of the frozen-oracle LP fee when active.
    /// @dev Uses the pool's simulated deposit-side reconcile state and rounds down.
    /// @param assets Underlying asset amount to deposit, in USDC units.
    /// @return Vault shares that would be minted.
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps == 0) {
            return _previewDepositShares(assets);
        }
        return _previewFrozenDepositShares(assets, feeBps);
    }

    /// @notice Previews assets required to mint shares, grossed up for the frozen-oracle LP fee when active.
    /// @dev Uses the pool's simulated deposit-side reconcile state and rounds up. While a frozen fee applies, requests
    ///      above `maxMint` return `type(uint256).max` because the fee-adjusted pricing denominator is exhausted.
    /// @param shares Vault-share amount to mint.
    /// @return Underlying assets required, in USDC units.
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps == 0) {
            return _previewMintAssets(shares);
        }
        return _previewFrozenMintAssets(shares, feeBps);
    }

    /// @notice Returns the maximum immediate asset deposit allowed by the current global pool gates.
    /// @dev Returns zero when the tranche is terminally wiped or the pool blocks instant deposits because of lifecycle,
    ///      pause, open-position, mark-freshness, pending-bootstrap, or senior-impairment state. Receiver-specific
    ///      third-party funding restrictions and the minimum deposit are enforced by `deposit`, not by this view.
    /// @param receiver Account that would receive shares; currently does not change the global cap.
    /// @return Maximum underlying asset amount accepted, in USDC units.
    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        receiver;
        if (!_canInstantDepositNow()) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /// @notice Returns the maximum immediate share mint allowed by the current global pool gates.
    /// @dev Returns zero under the same global gates as `maxDeposit`. In frozen-oracle mode, returns the finite share
    ///      cap for which fee-adjusted mint pricing remains defined. Receiver-specific third-party funding restrictions
    ///      and the minimum deposit are enforced by `mint`, not by this view.
    /// @param receiver Account that would receive shares; currently does not change the global cap.
    /// @return Maximum vault-share amount accepted.
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        receiver;
        if (!_canInstantDepositNow()) {
            return 0;
        }
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps > 0) {
            return _maxFrozenMintShares(feeBps);
        }
        return super.maxMint(receiver);
    }

    /// @notice Returns the maximum delayed-deposit request allowed by the current global pool gates.
    /// @dev Returns zero when the tranche is terminally wiped or delayed deposits are globally unavailable;
    ///      otherwise returns `type(uint256).max`. Receiver validity, third-party funding restrictions, and the
    ///      minimum deposit are enforced by `requestDeposit`, not by this view.
    /// @param receiver Account that would own the pending deposit; currently does not change the global cap.
    /// @return Maximum underlying asset amount that may be requested, in USDC units.
    function maxRequestDeposit(
        address receiver
    ) public view returns (uint256) {
        receiver;
        if (!_canDepositNow()) {
            return 0;
        }
        return type(uint256).max;
    }

    /// @notice Burns enough owner shares to withdraw an exact asset amount after pool reconciliation.
    /// @dev Requires the owner's cooldown to have expired and the amount to fit its unlocked, pool-capped withdrawal
    ///      limit. Enforces share allowance when the caller differs from `_owner`, transfers assets from `POOL` to
    ///      `receiver`, and restarts the owner's cooldown after every successful withdrawal. During frozen-oracle mode
    ///      the configured LP exit fee increases the shares burned while the requested net asset amount is paid.
    ///      Sub-minimum partial exits are rejected, but a complete exit may be smaller than the minimum.
    /// @param assets Exact underlying asset amount paid to `receiver`, in USDC units.
    /// @param receiver Account receiving the withdrawn assets.
    /// @param _owner Account whose vault shares are burned.
    /// @return Vault shares burned from `_owner`.
    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        _requireWithdrawPreflight(assets, _owner);
        POOL.reconcile();
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps > 0) {
            uint256 shares = previewWithdraw(assets);
            _withdraw(msg.sender, receiver, _owner, assets, shares);
            return shares;
        }
        return super.withdraw(assets, receiver, _owner);
    }

    /// @notice Burns an exact owner-share amount for assets after pool reconciliation.
    /// @dev Requires the owner's cooldown to have expired and the shares to fit its unlocked, pool-capped redemption
    ///      limit. Enforces share allowance when the caller differs from `_owner`, transfers assets from `POOL` to
    ///      `receiver`, and restarts the owner's cooldown after every successful redemption. During frozen-oracle mode
    ///      the configured LP exit fee reduces assets paid. Sub-minimum partial exits are rejected, but a complete
    ///      redemption of the owner's unlocked shares may return less than the minimum.
    /// @param shares Exact vault-share amount burned from `_owner`.
    /// @param receiver Account receiving the redeemed assets.
    /// @param _owner Account whose vault shares are burned.
    /// @return Underlying assets paid to `receiver`, in USDC units.
    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        _requireRedeemPreflight(shares, _owner);
        POOL.reconcile();
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps > 0) {
            uint256 assets = previewRedeem(shares);
            _withdraw(msg.sender, receiver, _owner, assets, shares);
            return assets;
        }
        return super.redeem(shares, receiver, _owner);
    }

    /// @notice Previews shares required to withdraw assets, grossed up for the frozen-oracle LP fee when active.
    /// @param assets Net underlying asset amount to withdraw, in USDC units.
    /// @return Vault shares that would be burned, rounded up.
    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps == 0) {
            return super.previewWithdraw(assets);
        }
        return _convertToShares(_grossUpForFee(assets, feeBps), Math.Rounding.Ceil);
    }

    /// @notice Previews assets received for redeeming shares, net of the frozen-oracle LP fee when active.
    /// @param shares Vault-share amount to redeem.
    /// @return Underlying assets that would be paid, in USDC units and rounded down.
    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        uint256 feeBps = _frozenLpFeeBps();
        if (feeBps == 0) {
            return super.previewRedeem(shares);
        }
        return _applyFee(_convertToAssets(shares, Math.Rounding.Floor), feeBps);
    }

    /// @notice Returns the owner's maximum currently withdrawable asset amount.
    /// @dev Returns zero during cooldown or while pool withdrawals are not live. Excludes permanent seed-floor shares
    ///      and caps the owner's net asset value by the pool's simulated tranche withdrawal limit.
    /// @param _owner Share owner to inspect.
    /// @return Maximum underlying asset amount withdrawable, in USDC units.
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
        uint256 ownerAssets = previewRedeem(ownerShares);
        (,, uint256 maxSeniorWithdrawUsdc, uint256 maxJuniorWithdrawUsdc) = POOL.getPendingTrancheState();
        uint256 poolMax = IS_SENIOR ? maxSeniorWithdrawUsdc : maxJuniorWithdrawUsdc;
        return ownerAssets < poolMax ? ownerAssets : poolMax;
    }

    /// @notice Returns the owner's maximum currently redeemable share amount.
    /// @dev Returns zero during cooldown or while pool withdrawals are not live. Excludes permanent seed-floor shares
    ///      and caps the result by the shares needed to consume the pool's simulated tranche withdrawal limit.
    /// @param _owner Share owner to inspect.
    /// @return Maximum vault-share amount redeemable.
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
        uint256 maxShares = previewWithdraw(poolMax);
        return ownerShares < maxShares ? ownerShares : maxShares;
    }

    /// @dev ERC-4626 deposit hook that moves assets through `POOL`, mints shares, and starts the receiver cooldown.
    /// @param caller Account supplying the underlying assets.
    /// @param receiver Account receiving the minted vault shares.
    /// @param assets Underlying asset amount deposited, in USDC units.
    /// @param shares Vault-share amount minted.
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
        uint256 previousBalance = balanceOf(receiver);
        if (caller != receiver && previousBalance != 0) {
            revert TrancheVault__ThirdPartyDepositForExistingHolder();
        }
        _mint(receiver, shares);
        if (caller == receiver || previousBalance == 0) {
            lastDepositTime[receiver] = block.timestamp;
        }
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev ERC-4626 withdrawal hook that spends allowance, burns owner shares, and instructs `POOL` to pay the
    ///      receiver. The owner's cooldown anchor is reset before the external pool withdrawal call.
    /// @param caller Account initiating the withdrawal or redemption.
    /// @param receiver Account receiving the underlying assets.
    /// @param _owner Account whose shares are burned.
    /// @param assets Underlying asset amount paid, in USDC units.
    /// @param shares Vault-share amount burned.
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
        lastDepositTime[_owner] = block.timestamp;
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

    /// @notice Mints shares for assets that the pool has explicitly assigned to this tranche.
    /// @dev Only `POOL` may call this. No assets move through the vault; the pool must have already assigned matching
    ///      tranche principal. Starts the receiver's cooldown at the current timestamp.
    /// @param shares Vault-share amount to mint.
    /// @param receiver Account receiving the minted shares.
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

    /// @notice Registers or increases this tranche's permanent seed-share floor.
    /// @dev Only `POOL` may call this. The receiver must already hold at least `floorShares`; after the first
    ///      configuration the receiver cannot change and the floor cannot decrease. Transfers and redemptions cannot
    ///      reduce the receiver below the floor.
    /// @param receiver Seed owner account.
    /// @param floorShares Minimum vault shares that must remain owned by the seed owner.
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

    function _requireMinimumDeposit(
        uint256 assets
    ) internal view {
        if (assets < POOL.minTrancheDepositUsdc()) {
            revert TrancheVault__DepositTooSmall();
        }
    }

    function _requireRequestDepositPreflight(
        uint256 assets,
        address receiver
    ) internal view {
        _requireActiveTranche();
        _requireMinimumDeposit(assets);
        _requireLifecycleActiveForOrdinaryDeposit();
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        if (!_canDepositNow()) {
            revert TrancheVault__DepositsUnavailable();
        }
        if (msg.sender != receiver && balanceOf(receiver) != 0) {
            revert TrancheVault__ThirdPartyDepositForExistingHolder();
        }
    }

    function _requireWithdrawPreflight(
        uint256 assets,
        address _owner
    ) internal view {
        if (assets == 0) {
            revert TrancheVault__WithdrawalTooSmall();
        }
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            revert TrancheVault__DepositCooldown();
        }
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssets);
        }
        if (assets >= POOL.minTrancheDepositUsdc()) {
            return;
        }
        uint256 ownerShares = _unlockedOwnerShares(_owner);
        uint256 ownerAssets = previewRedeem(ownerShares);
        if (assets < ownerAssets && previewWithdraw(assets) < ownerShares) {
            revert TrancheVault__WithdrawalTooSmall();
        }
    }

    function _requireRedeemPreflight(
        uint256 shares,
        address _owner
    ) internal view {
        if (shares == 0) {
            revert TrancheVault__WithdrawalTooSmall();
        }
        if (block.timestamp < lastDepositTime[_owner] + DEPOSIT_COOLDOWN) {
            revert TrancheVault__DepositCooldown();
        }
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
        }
        if (previewRedeem(shares) >= POOL.minTrancheDepositUsdc()) {
            return;
        }
        if (shares < _unlockedOwnerShares(_owner)) {
            revert TrancheVault__WithdrawalTooSmall();
        }
    }

    function _ordinaryDepositsAllowed() internal view returns (bool) {
        return POOL.canAcceptOrdinaryDeposits();
    }

    function _canDepositNow() internal view returns (bool) {
        return !_isTerminallyWiped() && POOL.canAcceptTrancheDeposits(IS_SENIOR);
    }

    function _canInstantDepositNow() internal view returns (bool) {
        return !_isTerminallyWiped() && POOL.canAcceptInstantTrancheDeposits(IS_SENIOR);
    }

    function _frozenLpFeeBps() internal view returns (uint256) {
        return POOL.frozenLpFeeBps(IS_SENIOR);
    }

    function _applyFee(
        uint256 grossAssets,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return grossAssets;
        }
        return Math.mulDiv(grossAssets, 10_000 - feeBps, 10_000, Math.Rounding.Floor);
    }

    function _grossUpForFee(
        uint256 netAssets,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return netAssets;
        }
        return Math.mulDiv(netAssets, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function _applyFeeToShares(
        uint256 grossShares,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return grossShares;
        }
        return Math.mulDiv(grossShares, 10_000 - feeBps, 10_000, Math.Rounding.Floor);
    }

    function _grossUpSharesForFee(
        uint256 netShares,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return netShares;
        }
        return Math.mulDiv(netShares, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function _depositPricingAssets() internal view returns (uint256 assets) {
        (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc) = POOL.getPendingDepositTrancheState();
        return IS_SENIOR ? seniorPrincipalUsdc : juniorPrincipalUsdc;
    }

    function _convertToSharesUsingAssets(
        uint256 assets,
        uint256 totalAssets_,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), totalAssets_ + 1, rounding);
    }

    function _convertToAssetsUsingAssets(
        uint256 shares,
        uint256 totalAssets_,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return Math.mulDiv(shares, totalAssets_ + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _previewDepositShares(
        uint256 assets
    ) internal view returns (uint256) {
        return _convertToSharesUsingAssets(assets, _depositPricingAssets(), Math.Rounding.Floor);
    }

    function _previewMintAssets(
        uint256 shares
    ) internal view returns (uint256) {
        return _convertToAssetsUsingAssets(shares, _depositPricingAssets(), Math.Rounding.Ceil);
    }

    function _previewFrozenDepositShares(
        uint256 assets,
        uint256 feeBps
    ) internal view returns (uint256) {
        uint256 netAssets = _applyFee(assets, feeBps);
        uint256 adjustedShares = totalSupply() + 10 ** _decimalsOffset();
        uint256 adjustedAssetsAfterDeposit = _depositPricingAssets() + assets + 1;
        uint256 denominator = adjustedAssetsAfterDeposit - netAssets;
        return Math.mulDiv(netAssets, adjustedShares, denominator, Math.Rounding.Floor);
    }

    function _previewFrozenMintAssets(
        uint256 shares,
        uint256 feeBps
    ) internal view returns (uint256) {
        if (shares > _maxFrozenMintShares(feeBps)) {
            return type(uint256).max;
        }
        uint256 adjustedShares = totalSupply() + 10 ** _decimalsOffset();
        uint256 adjustedAssets = _depositPricingAssets() + 1;
        uint256 denominator = ((10_000 - feeBps) * adjustedShares) - (feeBps * shares);
        return Math.mulDiv(10_000 * shares, adjustedAssets, denominator, Math.Rounding.Ceil);
    }

    function _maxFrozenMintShares(
        uint256 feeBps
    ) internal view returns (uint256) {
        uint256 adjustedShares = totalSupply() + 10 ** _decimalsOffset();
        uint256 quotient = Math.mulDiv(adjustedShares, 10_000 - feeBps, feeBps, Math.Rounding.Floor);
        if (mulmod(adjustedShares, 10_000 - feeBps, feeBps) == 0) {
            return quotient == 0 ? 0 : quotient - 1;
        }
        return quotient;
    }

}
