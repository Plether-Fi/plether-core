// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IMarginAccount} from "@plether/perps/interfaces/IMarginAccount.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IWithdrawGuard} from "@plether/perps/interfaces/IWithdrawGuard.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

interface IPositionProtectionBookSource {

    function positionProtectionBook() external view returns (address);

}

/// @title MarginClearinghouse
/// @notice Custodies the settlement token and maintains the margin buckets used by Plether perpetual accounts.
/// @dev Account ids are addresses. A settlement balance is an internal claim on this contract's token custody;
///      PnL pledge, liquidation reserve, committed-order margin, and action reserve are encumbrances within that
///      balance, not separate token balances. The contract assumes a standard six-decimal ERC-20 implementation and
///      does not support fee-on-transfer accounting. The deployer owns the one-time engine wiring and rescue of
///      non-settlement tokens through `Ownable2Step`. Asset amounts use settlement-token units, including
///      MockUSDG on the new testnet stack; unsolicited settlement-token transfers do not credit an account.
/// @custom:security-contact contact@plether.com
contract MarginClearinghouse is IMarginAccount, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    struct LiquidationSettlementExecution {
        address recipient;
        address keeper;
        uint256 keeperBountyAssets;
        address protocolFeeAccount;
        uint256 protocolFeeAssets;
        uint256 lpLiquidationFeeAssets;
    }

    mapping(address => uint256) internal settlementBalances;

    mapping(address => uint256) internal positionMarginAssets;
    mapping(address => uint256) internal committedOrderMarginAssets;
    mapping(address => uint256) internal reservedSettlementAssets;
    /// @dev Mandatory negative-lifetime-VPI floor contained inside `reservedSettlementAssets`; never counted twice.
    mapping(address => uint256) internal vpiRebateReserveBalances;
    mapping(address => uint256) internal liquidationReserveBalances;
    mapping(uint64 => IMarginClearinghouse.OrderReservation) internal orderReservations;
    mapping(address => uint256) internal activeCommittedOrderReservationAssets;

    struct ReservationQueue {
        uint64 head;
        uint64 tail;
        uint128 count;
    }
    mapping(address => ReservationQueue) internal reservationQueues;
    mapping(IMarginClearinghouse.BountyKind => mapping(uint64 => IMarginClearinghouse.BountyReservation)) internal
        bountyReservations;
    mapping(address => uint256) public totalBountyReservationsAssets;

    error MarginClearinghouse__InvalidBountyReservation();
    event BountyReservationUpdated(
        IMarginClearinghouse.BountyKind indexed kind, uint64 indexed id, address indexed account, uint256 amountAssets
    );

    /// @notice Settlement ERC-20 whose native units are used for every balance and margin amount.
    /// @dev Expected to have six decimals; the constructor does not inspect the token contract or its decimals.
    address public immutable settlementAsset;

    /// @notice Engine authorized to operate account balances and margin buckets.
    /// @dev Zero until `setEngine` is called. Some operations also authorize the engine-reported order router or
    ///      settlement sidecar, as documented on those entrypoints.
    address public engine;

    /// @notice The caller is not the engine or the engine-derived integration authorized for the operation.
    error MarginClearinghouse__NotOperator();

    /// @notice A legacy owner-authenticated deposit or withdrawal named an account other than the caller.
    error MarginClearinghouse__NotAccountOwner();

    /// @notice An operation that requires a nonzero amount received zero.
    error MarginClearinghouse__ZeroAmount();

    /// @notice The settlement token delivered a different amount than requested by a third-party deposit.
    error MarginClearinghouse__UnexpectedTransferAmount(uint256 expected, uint256 received);

    /// @notice The account's settlement balance cannot cover a requested user withdrawal.
    error MarginClearinghouse__InsufficientBalance();

    /// @notice Free settlement equity cannot cover a lock or would fall below locked margin after withdrawal.
    error MarginClearinghouse__InsufficientFreeEquity();

    /// @notice The account's settlement balance cannot cover a settlement debit or its remaining locked margin.
    error MarginClearinghouse__InsufficientAssetsForSettlement();

    /// @notice Settlement custody or the required reserved bucket cannot cover an operator-directed debit.
    error MarginClearinghouse__InsufficientAssetToSeize();

    /// @notice An unsupported margin or reservation bucket was supplied.
    error MarginClearinghouse__InvalidMarginBucket();

    /// @notice The order id already has a reservation record, including a terminal record.
    error MarginClearinghouse__ReservationAlreadyExists();

    /// @notice The requested reservation does not exist or is no longer active.
    error MarginClearinghouse__ReservationNotActive();

    /// @notice Supplied reservation ids do not cover committed-order margin that the settlement plan consumes.
    error MarginClearinghouse__IncompleteReservationCoverage();

    /// @notice The owner attempted to replace the already configured engine.
    error MarginClearinghouse__EngineAlreadySet();

    /// @notice A required engine, recipient, or keeper address is zero.
    error MarginClearinghouse__ZeroAddress();

    /// @notice Settlement tokens cannot be rescued, including unsolicited transfers.
    error MarginClearinghouse__CannotRescueSettlementAsset();

    /// @notice A typed locked-margin bucket cannot cover the requested decrease.
    error MarginClearinghouse__InsufficientBucketMargin();

    /// @notice A reservation amount cannot be represented by the reservation ledger's `uint96` fields.
    error MarginClearinghouse__AmountOverflow();

    /// @notice Planned action-reserve consumption does not match the reserve available above queued bounties.
    error MarginClearinghouse__ActionReserveMismatch();

    /// @notice A supplied reservation belongs to an account other than the expected account.
    error MarginClearinghouse__ReservationAccountMismatch(
        uint64 orderId, address expectedAccount, address actualAccount
    );

    /// @notice Emitted after settlement tokens are transferred in and credited to an account.
    /// @param account Account credited with the deposit
    /// @param asset Settlement token transferred in
    /// @param amount Amount transferred and credited, in the token's native units
    event Deposit(address indexed account, address indexed asset, uint256 amount);

    /// @notice Identifies the payer of a credit-only deposit; its matching `Deposit` event records the same credit.
    /// @dev Indexers must not count this metadata event as an additional settlement credit.
    event DepositFor(address indexed payer, address indexed account, uint256 amount);

    /// @notice Emitted after settlement tokens are debited from an account and transferred to its owner.
    /// @param account Account debited by the withdrawal
    /// @param asset Settlement token transferred out
    /// @param amount Amount debited and transferred, in the token's native units
    event Withdraw(address indexed account, address indexed asset, uint256 amount);

    /// @notice Emitted after the owner rescues a non-settlement token.
    /// @param token ERC-20 token rescued
    /// @param recipient Recipient of the transfer
    /// @param amount Requested transfer amount in the token's native units
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when an account's typed locked-margin bucket increases.
    /// @dev Locking is an internal reclassification and does not itself move settlement tokens.
    /// @param account Account whose locked bucket increased
    /// @param bucket Locked-margin bucket that increased
    /// @param amountAssets Increase in six-decimal settlement token units
    event MarginLocked(address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountAssets);

    /// @notice Emitted when an account's typed locked-margin bucket decreases.
    /// @dev The decrease may release funds or accompany a settlement debit; the event alone does not imply that
    ///      the amount became withdrawable.
    /// @param account Account whose locked bucket decreased
    /// @param bucket Locked-margin bucket that decreased
    /// @param amountAssets Decrease in six-decimal settlement token units
    event MarginUnlocked(
        address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountAssets
    );

    /// @notice Emitted when committed-order margin is locked against a new order id.
    /// @param orderId Order id assigned the reservation
    /// @param account Account whose committed-order margin backs the reservation
    /// @param bucket Reservation bucket used by the record
    /// @param amountAssets Original reserved amount in six-decimal settlement token units
    event ReservationCreated(
        uint64 indexed orderId,
        address indexed account,
        IMarginClearinghouse.ReservationBucket indexed bucket,
        uint256 amountAssets
    );

    /// @notice Emitted when all or part of an active order reservation is consumed.
    /// @param orderId Order id whose reservation was consumed
    /// @param account Account that owns the reservation
    /// @param amountAssets Amount consumed in six-decimal settlement token units
    /// @param remainingAmountAssets Amount still active after consumption, in six-decimal settlement token units
    event ReservationConsumed(
        uint64 indexed orderId, address indexed account, uint256 amountAssets, uint256 remainingAmountAssets
    );

    /// @notice Emitted when the remaining amount of an active reservation is released.
    /// @param orderId Order id whose reservation was released
    /// @param account Account that owns the reservation
    /// @param amountAssets Amount released from committed-order margin, in six-decimal settlement token units
    event ReservationReleased(uint64 indexed orderId, address indexed account, uint256 amountAssets);

    /// @notice Emitted after a risk-off refund releases order margin and refundable bounty classifications.
    /// @param account Account whose risk-off order reserves were released
    /// @param releasedMarginAssets Aggregate committed-order margin released in six-decimal settlement token units
    /// @param refundableBountyAssets Reserved order and attached-protection bounties released in six-decimal settlement token units
    event RiskOffOrderReservesRefunded(
        address indexed account, uint256 releasedMarginAssets, uint256 refundableBountyAssets
    );

    /// @notice Emitted when settlement value is debited from an account and routed to a recipient.
    /// @dev Routing may be an external token transfer or an internal clearinghouse credit, such as a protocol fee.
    /// @param account Account from which settlement value was debited
    /// @param asset Settlement token representing the routed value
    /// @param amount Amount routed, in the token's native units
    /// @param recipient External recipient or clearinghouse account credited
    event AssetSeized(address indexed account, address indexed asset, uint256 amount, address recipient);

    /// @notice Emitted when reserved settlement value is credited internally to another account.
    /// @param account Source account whose settlement value was debited
    /// @param recipient Clearinghouse account credited
    /// @param amountAssets Amount transferred in six-decimal settlement token units
    event ReservedSettlementTransferred(address indexed account, address indexed recipient, uint256 amountAssets);

    /// @dev Restricts calls to the engine or its currently reported settlement sidecar.
    modifier onlyOperator() {
        address engine_ = engine;
        if (engine_ == address(0)) {
            revert MarginClearinghouse__NotOperator();
        }
        if (msg.sender != engine_ && !_isSettlementSidecar(engine_, msg.sender)) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @dev Restricts calls to the engine or its currently reported order router.
    modifier onlyEngineOrOrderRouter() {
        address engine_ = engine;
        if (engine_ == address(0) || (msg.sender != engine_ && !_isOrderRouter(engine_, msg.sender))) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @dev Restricts reserved-settlement locks to the engine, its router, or that router's position-protection book.
    modifier onlyReservedSettlementLocker() {
        address engine_ = engine;
        if (
            engine_ == address(0)
                || (msg.sender != engine_
                    && !_isOrderRouter(engine_, msg.sender)
                    && !_isPositionProtectionBook(engine_, msg.sender))
        ) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @dev Restricts calls to the order router currently reported by the configured engine.
    modifier onlyOrderRouter() {
        address engine_ = engine;
        if (engine_ == address(0) || !_isOrderRouter(engine_, msg.sender)) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @dev Restricts reserved-settlement unlocks to the engine, its router/sidecar, or the position-protection book.
    modifier onlyReservedSettlementOperator() {
        address engine_ = engine;
        if (
            engine_ == address(0)
                || (msg.sender != engine_
                    && !_isOrderRouter(engine_, msg.sender)
                    && !_isSettlementSidecar(engine_, msg.sender)
                    && !_isPositionProtectionBook(engine_, msg.sender))
        ) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @dev Restricts calls to the configured engine itself.
    modifier onlyEngine() {
        address engine_ = engine;
        if (engine_ == address(0) || msg.sender != engine_) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @notice Deploys the clearinghouse and assigns ownership to the deployer.
    /// @dev `_settlementAsset` is stored without zero-address, code, symbol, or decimal validation.
    /// @param _settlementAsset ERC-20 used for settlement custody; expected to be six-decimal settlement token
    constructor(
        address _settlementAsset
    ) Ownable(msg.sender) {
        settlementAsset = _settlementAsset;
    }

    /// @notice Permanently configures the engine used for settlement, margin operations, and integration discovery.
    /// @dev Callable only by the owner. The address must be nonzero and can be set exactly once, but contract code
    ///      and interface support are not validated here. The owner cannot later rotate or clear it.
    /// @param _engine Engine address to authorize and query for its order router and settlement sidecar
    function setEngine(
        address _engine
    ) external onlyOwner {
        if (_engine == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (engine != address(0)) {
            revert MarginClearinghouse__EngineAlreadySet();
        }
        engine = _engine;
    }

    /// @notice Rescues the full balance of an accidentally transferred non-settlement ERC-20.
    /// @dev Owner-only. Settlement settlement token is always excluded, even when sent without an account credit.
    ///      Does not change settlement balances or margin buckets. Transfer-tax tokens may deliver less than `amount`
    ///      emitted by `TokenRescued`.
    /// @param token Non-settlement ERC-20 to rescue
    /// @param recipient Nonzero address receiving the tokens
    function rescueToken(
        address token,
        address recipient
    ) external onlyOwner nonReentrant {
        if (token == settlementAsset) {
            revert MarginClearinghouse__CannotRescueSettlementAsset();
        }
        if (token == address(0) || recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRescued(token, recipient, amount);
    }

    // ==========================================
    // USER ACTIONS
    // ==========================================

    /// @notice Transfers settlement settlement token from the caller and credits the caller's margin account.
    /// @dev `account` must equal `msg.sender` and `amount` must be nonzero. Requires prior ERC-20 allowance. If the
    ///      engine is configured, the deposit invokes its carry-realization hook after crediting the balance.
    /// @param account Account receiving the deposit; must be the caller's address
    /// @param amount Amount to transfer and credit, in six-decimal settlement token units
    function deposit(
        address account,
        uint256 amount
    ) external {
        _deposit(account, msg.sender, amount);
    }

    /// @notice Transfers settlement settlement token from the caller into its canonical address-based margin account.
    /// @dev Requires a nonzero amount and prior ERC-20 allowance. If the engine is configured, the deposit invokes
    ///      its carry-realization hook after crediting the balance.
    /// @param amount Amount to transfer and credit, in six-decimal settlement token units
    function depositMargin(
        uint256 amount
    ) external nonReentrant {
        _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Transfers the caller's settlement token into custody and credits another account's free settlement.
    /// @dev Requires an exact, nonzero token transfer and a nonzero beneficiary. Does not allocate position margin,
    ///      checkpoint carry, or give the payer authority over the beneficiary. Existing carry remains due and is
    ///      projected or collected by the normal account actions. Self-funding and counterfactual accounts are allowed.
    /// @param account Account whose free settlement balance receives the deposit
    /// @param amount Exact settlement-token amount to pull from the caller, in six-decimal settlement token units
    function depositFor(
        address account,
        uint256 amount
    ) external nonReentrant {
        if (account == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (amount == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        IERC20 asset = IERC20(settlementAsset);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) {
            revert MarginClearinghouse__UnexpectedTransferAmount(amount, received);
        }

        _creditSettlementAssets(account, amount);

        emit Deposit(account, settlementAsset, amount);
        emit DepositFor(msg.sender, account, amount);
    }

    /// @notice Debits the caller's margin account and transfers settlement settlement token to the caller.
    /// @dev `account` must equal `msg.sender`. Before transfer, the function checkpoints carry, applies the engine's
    ///      withdrawal guard when configured, and verifies the remaining settlement balance covers all locked
    ///      buckets. A zero amount is permitted but still runs those checks and hooks.
    /// @param account Account funding the withdrawal; must be the caller's address
    /// @param amount Amount to debit and transfer, in six-decimal settlement token units
    function withdraw(
        address account,
        uint256 amount
    ) external nonReentrant {
        _withdraw(account, msg.sender, amount);
    }

    /// @notice Withdraws settlement settlement token from the caller's canonical address-based margin account.
    /// @dev Checkpoints carry, applies the configured engine's withdrawal guard, and verifies the remaining
    ///      settlement balance covers every locked bucket. A zero amount is permitted but still runs the checks.
    /// @param amount Amount to debit and transfer, in six-decimal settlement token units
    function withdrawMargin(
        uint256 amount
    ) external nonReentrant {
        _withdraw(msg.sender, msg.sender, amount);
    }

    function _deposit(
        address account,
        address owner,
        uint256 amount
    ) internal {
        if (owner != account) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (amount == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        IERC20(settlementAsset).safeTransferFrom(owner, address(this), amount);

        settlementBalances[account] += amount;

        _realizeOrCheckpointCarryBeforeMarginChange(account);

        emit Deposit(account, settlementAsset, amount);
    }

    function _withdraw(
        address account,
        address owner,
        uint256 amount
    ) internal {
        if (owner != account) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        _checkpointCarryBeforeMarginChange(account);

        address engine_ = engine;

        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        settlementBalances[account] -= amount;

        if (engine_ != address(0)) {
            IWithdrawGuard(engine_).checkWithdraw(account);
        }

        uint256 remainingEquity = getAccountEquityAssets(account);
        uint256 totalLockedMargin = _totalLockedMarginAssets(account);
        if (remainingEquity < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[account] < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientAssetsForSettlement();
        }

        IERC20(settlementAsset).safeTransfer(owner, amount);
        emit Withdraw(account, settlementAsset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns an account's internal settlement settlement token balance.
    /// @dev This clearinghouse-local value does not include unrealized PnL or apply engine withdrawal guards.
    /// @param account Account to inspect
    /// @return totalEquityAssets Settlement balance in six-decimal settlement token units
    function getAccountEquityAssets(
        address account
    ) public view override returns (uint256 totalEquityAssets) {
        return settlementBalances[account];
    }

    /// @notice Returns settlement balance not encumbered by any typed locked-margin bucket.
    /// @dev Equals `max(settlement balance - total locked margin, 0)` and excludes unrealized PnL and engine
    ///      withdrawal constraints.
    /// @param account Account to query
    /// @return Unencumbered settlement balance in six-decimal settlement token units
    function getFreeBuyingPowerAssets(
        address account
    ) public view override returns (uint256) {
        uint256 equity = getAccountEquityAssets(account);
        uint256 encumbered = _totalLockedMarginAssets(account);
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns the account's settlement balance and its typed locked/free margin breakdown.
    /// @dev `otherLockedMarginAssets` combines liquidation, committed-order, and action-reserve margin. Every amount is in
    ///      six-decimal settlement token units; unrealized PnL and engine withdrawal guards are not included.
    /// @param account Account to inspect
    /// @return buckets Settlement balance, total locked, position locked, other locked, and free settlement amounts
    function getAccountAssetBuckets(
        address account
    ) public view returns (IMarginClearinghouse.AccountAssetBuckets memory buckets) {
        buckets = _buildAccountAssetBuckets(account);
    }

    /// @notice Returns the canonical V3 PnL-isolated settlement classification.
    function getPnlIsolationBuckets(
        address account
    ) public view returns (IMarginClearinghouse.PnlIsolationBuckets memory buckets) {
        buckets.settlementBalanceAssets = settlementBalances[account];
        buckets.pnlPledgeAssets = positionMarginAssets[account];
        buckets.liquidationReserveAssets = liquidationReserveBalances[account];
        buckets.orderMarginAssets = committedOrderMarginAssets[account];
        buckets.actionReserveAssets = reservedSettlementAssets[account];
        buckets.vpiRebateReserveAssets = vpiRebateReserveBalances[account];
        buckets.totalLockedAssets = _totalLockedMarginAssets(account);
        buckets.freeSettlementAssets = buckets.settlementBalanceAssets > buckets.totalLockedAssets
            ? buckets.settlementBalanceAssets - buckets.totalLockedAssets
            : 0;
    }

    function pnlPledgeAssets(
        address account
    ) external view returns (uint256) {
        return positionMarginAssets[account];
    }

    function liquidationReserveAssets(
        address account
    ) external view returns (uint256) {
        return liquidationReserveBalances[account];
    }

    function orderMarginAssets(
        address account
    ) external view returns (uint256) {
        return committedOrderMarginAssets[account];
    }

    function actionReserveAssets(
        address account
    ) external view returns (uint256) {
        return reservedSettlementAssets[account];
    }

    function vpiRebateReserveAssets(
        address account
    ) external view returns (uint256) {
        return vpiRebateReserveBalances[account];
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Encumbers free settlement in the active-position margin bucket.
    /// @dev Callable only by the engine or its reported settlement sidecar. The settlement balance is unchanged;
    ///      the call reverts if free settlement is less than `amountAssets`. This entrypoint does not checkpoint carry.
    /// @param account Account whose settlement should be encumbered
    /// @param amountAssets Amount to lock in six-decimal settlement token units
    function lockPositionMargin(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountAssets);
    }

    /// @notice Decreases an account's active-position margin bucket by an exact amount.
    /// @dev Callable only by the engine or its reported settlement sidecar. The settlement balance is unchanged, and
    ///      the call reverts rather than clamping when `amountAssets` exceeds the position-margin bucket. This
    ///      entrypoint does not checkpoint carry.
    /// @param account Account whose position margin should be decreased
    /// @param amountAssets Exact amount to remove in six-decimal settlement token units
    function unlockPositionMargin(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountAssets);
    }

    /// @notice Verifies the planned release source against live custody before unlocking close collateral.
    /// @dev The surrounding engine settlement is atomic. VPI release is separately checked and applied before fees.
    function unlockCloseMargin(
        address account,
        uint256 safeRelease,
        uint256 fromReleased,
        uint256 netRelease,
        uint256 cashChargeAfterVpi,
        uint256 vpiRelease
    ) external onlyOperator {
        uint256 reserve = _spendableActionReserveAssets(account);
        uint256 afterReserve = cashChargeAfterVpi > reserve ? cashChargeAfterVpi - reserve : 0;
        uint256 free = getFreeBuyingPowerAssets(account) + vpiRelease;
        uint256 needed = afterReserve > free ? afterReserve - free : 0;
        uint256 expected = needed < safeRelease ? needed : safeRelease;
        if (fromReleased != expected || netRelease != safeRelease - expected) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.Position, safeRelease);
    }

    /// @notice Locks free settlement as committed-order margin and records it against a unique order id.
    /// @dev Callable only by the engine or its reported order router. Checkpoints carry, requires a nonzero amount that
    ///      fits `uint96`, and permanently prevents reuse of an id once any record exists. No tokens move.
    /// @param account Account whose committed-order margin backs the reservation
    /// @param orderId Router order id receiving the reservation
    /// @param amountAssets Amount to reserve in six-decimal settlement token units
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountAssets
    ) external onlyEngineOrOrderRouter {
        if (orderId == 0 || orderReservations[orderId].status != IMarginClearinghouse.ReservationStatus.None) {
            revert MarginClearinghouse__ReservationAlreadyExists();
        }
        if (amountAssets == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountAssets);
        uint96 amount96 = _toUint96(amountAssets);
        uint64 previousOrderId = reservationQueues[account].tail;
        orderReservations[orderId] = IMarginClearinghouse.OrderReservation({
            previousOrderId: previousOrderId,
            nextOrderId: 0,
            account: account,
            bucket: IMarginClearinghouse.ReservationBucket.CommittedOrder,
            status: IMarginClearinghouse.ReservationStatus.Active,
            originalAmountAssets: amount96,
            remainingAmountAssets: amount96
        });
        if (previousOrderId == 0) {
            reservationQueues[account].head = orderId;
        } else {
            orderReservations[previousOrderId].nextOrderId = orderId;
        }
        reservationQueues[account].tail = orderId;
        activeCommittedOrderReservationAssets[account] += amountAssets;
        reservationQueues[account].count += 1;

        emit ReservationCreated(orderId, account, IMarginClearinghouse.ReservationBucket.CommittedOrder, amountAssets);
    }

    /// @notice Releases an order reservation during terminal Router cleanup if it remains active.
    /// @dev Callable only by the Router currently reported by the configured Engine. Unknown and terminal ids return
    ///      zero. This path deliberately skips the carry checkpoint and only releases locked classification; it does
    ///      not change settlement balance or move tokens.
    /// @param orderId Order reservation id to release
    /// @return releasedAssets Remaining reservation amount released, or zero when the reservation is not active
    function releaseOrderReservationForTerminalCleanup(
        uint64 orderId
    ) external onlyOrderRouter returns (uint256 releasedAssets) {
        IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderId];
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            return 0;
        }

        releasedAssets = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.account, releasedAssets);
    }

    /// @notice Releases risk-off order margin and refundable bounty classifications back to free settlement.
    /// @dev Callable only by the Engine-reported order router after it has taken the invalidated bounty records from the
    ///      clearinghouse ledger. Unknown and terminal reservation ids are tolerated, but every existing record must belong
    ///      to `account`. This incident path deliberately skips the Engine carry checkpoint: settlement balance, token
    ///      custody, PnL pledge, and carry state remain unchanged. The exact bounty release must leave enough reserved
    ///      settlement to protect negative-VPI backing and all remaining clearinghouse bounty reservations.
    /// @param account Account receiving the released margin classifications
    /// @param orderIds Order reservation ids invalidated by the risk-off cutoff
    /// @param refundableBountyAssets Exact invalidated order and attached-protection bounties to unlock
    /// @return releasedMarginAssets Aggregate remaining committed-order margin released
    function releaseInvalidatedOrderReserves(
        address account,
        uint64[] calldata orderIds,
        uint256 refundableBountyAssets
    ) external onlyOrderRouter returns (uint256 releasedMarginAssets) {
        for (uint256 i = 0; i < orderIds.length; ++i) {
            uint64 orderId = orderIds[i];
            IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderId];
            IMarginClearinghouse.ReservationStatus status = reservation.status;
            if (status == IMarginClearinghouse.ReservationStatus.None) {
                continue;
            }
            if (reservation.account != account) {
                revert MarginClearinghouse__ReservationAccountMismatch(orderId, account, reservation.account);
            }
            if (status != IMarginClearinghouse.ReservationStatus.Active) {
                continue;
            }

            uint256 releasedAssets = _releaseReservation(reservation, true);
            releasedMarginAssets += releasedAssets;
            emit ReservationReleased(orderId, account, releasedAssets);
        }

        if (refundableBountyAssets > 0) {
            _requireActionReserveDecreaseAboveProtectedFloor(account, refundableBountyAssets);
            _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, refundableBountyAssets);
        }
        emit RiskOffOrderReservesRefunded(account, releasedMarginAssets, refundableBountyAssets);
    }

    /// @notice Releases a settled order or protection-trigger bounty back to the same account that funded it.
    /// @dev Callable only by the Engine-reported Router. Unlike the general Engine bounty-credit path, this exact
    ///      self-transfer changes only the reserved classification and deliberately skips carry checkpointing. The
    ///      Router or its protection Book must first take the clearinghouse bounty record so the protected-reserve
    ///      floor remains exact. Atomic protection cancellation uses this before bounded close carry collection.
    /// @param account Account whose bounty classification is released to free settlement.
    /// @param executionBountyAssets Exact bounty amount in six-decimal settlement token units.
    function releaseReservedExecutionBountyToSource(
        address account,
        uint256 executionBountyAssets
    ) external onlyOrderRouter {
        if (executionBountyAssets == 0) {
            return;
        }
        _requireActionReserveDecreaseAboveProtectedFloor(account, executionBountyAssets);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, executionBountyAssets);
    }

    /// @dev The clearinghouse owns FIFO traversal; every active reservation consumed must belong to `account`.
    function _consumeAccountOrderReservations(
        address account,
        uint256 amountAssets,
        bool consumeBuckets
    ) internal returns (uint256 consumedAssets) {
        if (amountAssets == 0) {
            return 0;
        }

        uint64[] memory reservationIds = _activeMarginReservationIds(account);
        uint256 remainingAssets = amountAssets;
        for (uint256 i = 0; i < reservationIds.length && remainingAssets > 0; i++) {
            IMarginClearinghouse.OrderReservation storage reservation = orderReservations[reservationIds[i]];
            if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
                continue;
            }
            if (reservation.account != account) {
                revert MarginClearinghouse__ReservationAccountMismatch(reservationIds[i], account, reservation.account);
            }

            uint256 reservationConsumedAssets = remainingAssets > reservation.remainingAmountAssets
                ? reservation.remainingAmountAssets
                : remainingAssets;
            if (reservationConsumedAssets == 0) {
                continue;
            }

            _consumeReservation(
                reservation, reservationConsumedAssets, consumeBuckets, IMarginClearinghouse.ReservationStatus.Consumed
            );

            remainingAssets -= reservationConsumedAssets;
            consumedAssets += reservationConsumedAssets;
            emit ReservationConsumed(
                reservationIds[i], account, reservationConsumedAssets, reservation.remainingAmountAssets
            );
        }
    }

    function _releaseReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        bool consumeBuckets
    ) internal returns (uint256 releasedAssets) {
        releasedAssets = reservation.remainingAmountAssets;
        if (releasedAssets > 0) {
            _consumeReservation(
                reservation, releasedAssets, consumeBuckets, IMarginClearinghouse.ReservationStatus.Released
            );
        } else {
            _closeReservation(reservation, IMarginClearinghouse.ReservationStatus.Released);
        }
    }

    function _consumeReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        uint256 amountAssets,
        bool consumeBuckets,
        IMarginClearinghouse.ReservationStatus terminalStatus
    ) internal {
        reservation.remainingAmountAssets -= _toUint96(amountAssets);
        if (consumeBuckets) {
            _consumeReservationBucket(reservation.account, reservation.bucket, amountAssets);
        }
        _decreaseActiveReservation(reservation.account, amountAssets);

        if (reservation.remainingAmountAssets == 0) {
            _closeReservation(reservation, terminalStatus);
        }
    }

    function _decreaseActiveReservation(
        address account,
        uint256 amountAssets
    ) internal {
        activeCommittedOrderReservationAssets[account] -= amountAssets;
    }

    /// @notice Encumbers free settlement in the reserved-settlement bucket.
    /// @dev Callable only by the engine, its reported router, or the router's immutable position-protection book.
    ///      Checkpoints carry before increasing the bucket. The settlement balance is unchanged, and insufficient
    ///      free settlement reverts.
    /// @param account Account whose settlement should be reserved
    /// @param amountAssets Amount to reserve in six-decimal settlement token units
    function lockReservedSettlement(
        address account,
        uint256 amountAssets
    ) external onlyReservedSettlementLocker {
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
    }

    /// @notice Decreases the reserved-settlement bucket, making the amount free settlement.
    /// @dev Callable only by the engine, its reported router or settlement sidecar, or the router's immutable
    ///      position-protection book. Checkpoints carry and reverts rather than clamping on bucket underflow. The
    ///      settlement balance is unchanged.
    /// @param account Account whose reserved settlement should be unlocked
    /// @param amountAssets Exact amount to unlock in six-decimal settlement token units
    function unlockReservedSettlement(
        address account,
        uint256 amountAssets
    ) external onlyReservedSettlementOperator {
        _checkpointCarryBeforeMarginChange(account);
        _requireActionReserveDecreaseAboveProtectedFloor(account, amountAssets);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
    }

    /// @notice Locks free settlement into the action reserve and its mandatory negative-VPI sub-ledger.
    /// @dev The sub-ledger is a floor inside `reservedSettlementAssets`, not an additional locked bucket.
    function lockVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        if (amountAssets == 0) {
            return;
        }
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
        vpiRebateReserveBalances[account] += amountAssets;
    }

    /// @notice Reclassifies newly locked PnL pledge into mandatory negative-VPI backing without moving cash.
    function reclassifyPnlPledgeToVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        if (amountAssets == 0) {
            return;
        }
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, amountAssets);
        reservedSettlementAssets[account] += amountAssets;
        vpiRebateReserveBalances[account] += amountAssets;
        emit MarginLocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
    }

    /// @notice Releases no-longer-required negative-VPI backing into free settlement.
    function releaseVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        if (amountAssets == 0) {
            return;
        }
        if (vpiRebateReserveBalances[account] < amountAssets) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        vpiRebateReserveBalances[account] -= amountAssets;
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
    }

    /// @notice Returns reserved negative-VPI backing to the LP pool as cash recovery.
    function consumeVpiRebateReserve(
        address account,
        address recipient,
        uint256 amountAssets
    ) external onlyOperator {
        if (amountAssets == 0) {
            return;
        }
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (
            vpiRebateReserveBalances[account] < amountAssets || reservedSettlementAssets[account] < amountAssets
                || settlementBalances[account] < amountAssets
        ) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        vpiRebateReserveBalances[account] -= amountAssets;
        reservedSettlementAssets[account] -= amountAssets;
        settlementBalances[account] -= amountAssets;
        IERC20(settlementAsset).safeTransfer(recipient, amountAssets);
        emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountAssets);
        emit AssetSeized(account, settlementAsset, amountAssets, recipient);
    }

    /// @notice Collects an action charge from spendable action reserve, free settlement, then committed order margin.
    /// @dev Negative-VPI backing and clearinghouse-attributed execution bounties remain protected in the shared action-reserve
    ///      bucket. The caller supplies the exact planned reserve and committed-margin split so a state mismatch
    ///      reverts. Committed order margin is consumed in clearinghouse FIFO order. Locked PnL pledge and liquidation
    ///      reserve are never reachable here. Full-close settlement releases their post-carry, post-price-loss surplus
    ///      into free settlement before this call; any charge above eligible value is waived.
    function consumeActionCharge(
        address account,
        uint256 chargeAssets,
        uint256 actionReserveConsumedAssets,
        uint256 actionCommittedMarginConsumedAssets,
        address recipient,
        address protocolTreasury,
        uint256 protocolFeeAssets
    ) external onlyOperator returns (uint256 collectedAssets, uint256 protocolFeeCreditedAssets) {
        collectedAssets = _validateActionChargeConsumption(
            account, chargeAssets, actionReserveConsumedAssets, actionCommittedMarginConsumedAssets
        );
        if (collectedAssets == 0) {
            return (0, 0);
        }

        if (actionReserveConsumedAssets > 0) {
            reservedSettlementAssets[account] -= actionReserveConsumedAssets;
            emit MarginUnlocked(
                account, IMarginClearinghouse.MarginBucket.ReservedSettlement, actionReserveConsumedAssets
            );
        }
        if (actionCommittedMarginConsumedAssets > 0) {
            uint256 consumedCommittedMarginAssets =
                _consumeAccountOrderReservations(account, actionCommittedMarginConsumedAssets, true);
            if (consumedCommittedMarginAssets != actionCommittedMarginConsumedAssets) {
                revert MarginClearinghouse__IncompleteReservationCoverage();
            }
        }

        protocolFeeCreditedAssets =
            _routeSettlementDebit(account, collectedAssets, recipient, protocolTreasury, protocolFeeAssets);
    }

    function _validateActionChargeConsumption(
        address account,
        uint256 chargeAssets,
        uint256 actionReserveConsumedAssets,
        uint256 actionCommittedMarginConsumedAssets
    ) private view returns (uint256 collectedAssets) {
        uint256 actionReserveAvailableAssets = _spendableActionReserveAssets(account);
        uint256 freeSettlementAvailableAssets = getFreeBuyingPowerAssets(account);
        uint256 eligibleAssets =
            actionReserveAvailableAssets + freeSettlementAvailableAssets + committedOrderMarginAssets[account];
        collectedAssets = chargeAssets < eligibleAssets ? chargeAssets : eligibleAssets;

        uint256 expectedActionReserveConsumedAssets =
            collectedAssets < actionReserveAvailableAssets ? collectedAssets : actionReserveAvailableAssets;
        uint256 chargeAfterReserveAssets = collectedAssets - expectedActionReserveConsumedAssets;
        uint256 expectedCommittedMarginConsumedAssets = chargeAfterReserveAssets > freeSettlementAvailableAssets
            ? chargeAfterReserveAssets - freeSettlementAvailableAssets
            : 0;
        if (
            actionReserveConsumedAssets != expectedActionReserveConsumedAssets
                || actionCommittedMarginConsumedAssets != expectedCommittedMarginConsumedAssets
        ) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
    }

    function _spendableActionReserveAssets(
        address account
    ) private view returns (uint256) {
        uint256 actionReserveBalanceAssets = reservedSettlementAssets[account];
        uint256 protectedActionReserveAssets =
            totalBountyReservationsAssets[account] + vpiRebateReserveBalances[account];
        if (actionReserveBalanceAssets < protectedActionReserveAssets) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        return actionReserveBalanceAssets - protectedActionReserveAssets;
    }

    /// @notice Releases liquidation reserve back to free settlement without debiting custody.
    function releaseLiquidationReserve(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.LiquidationReserve, amountAssets);
    }

    /// @notice Reclassifies PnL pledge as liquidation reserve; total locked settlement is unchanged.
    function reclassifyPnlPledgeToLiquidationReserve(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        _reclassifyMargin(
            account,
            IMarginClearinghouse.MarginBucket.Position,
            IMarginClearinghouse.MarginBucket.LiquidationReserve,
            amountAssets
        );
    }

    /// @notice Applies a signed delta to an account's internal settlement balance.
    /// @dev Callable only by the engine or its reported settlement sidecar. Positive values credit and negative values
    ///      debit; zero is a no-op. This accounting mutation does not transfer tokens, alter locked buckets, or
    ///      checkpoint carry. A debit larger than free settlement reverts.
    /// @param account Account to settle
    /// @param amount Signed delta in six-decimal settlement token units; positive credits and negative debits
    function settleAssets(
        address account,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            _creditSettlementAssets(account, uint256(amount));
        } else if (amount < 0) {
            _debitSettlementAssets(account, uint256(-amount));
        }
    }

    /// @notice Credits settlement already transferred into custody and classifies it as PnL pledge.
    function creditPnlPledge(
        address account,
        uint256 amountAssets
    ) external onlyOperator {
        _creditPnlPledge(account, amountAssets);
    }

    function _creditPnlPledge(
        address account,
        uint256 amountAssets
    ) internal {
        if (amountAssets == 0) {
            return;
        }

        _creditSettlementAssets(account, amountAssets);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountAssets);
    }

    /// @notice Applies an open/increase cost, updates position margin, and routes the collected settlement debit.
    /// @dev Callable only by the engine or its reported settlement sidecar. Positive `tradeCostAssets` debits internal
    ///      settlement and transfers the non-fee portion to `recipient`; a negative value credits a rebate internally.
    ///      Any protocol fee is capped by the cash debit and credited internally to `protocolFeeAccount`, with no token
    ///      transfer for that portion. The function does not checkpoint carry.
    /// @param account Account whose settlement and position-margin bucket are mutated
    /// @param marginDeltaAssets Margin supplied with the order, in six-decimal settlement token units
    /// @param tradeCostAssets Signed six-decimal settlement token cost; positive is a debit and negative is a rebate
    /// @param recipient External recipient of the collected debit after any internal protocol-fee credit
    /// @param protocolFeeAccount Clearinghouse account credited with the protocol-fee portion; zero disables the credit
    /// @param protocolFeeAssets Requested protocol-fee portion in six-decimal settlement token units
    /// @return netMarginChangeAssets Nonnegative new PnL pledge left after this action's positive cost, in settlement token
    /// @return protocolFeeCreditedAssets Amount of the debit credited internally to `protocolFeeAccount`
    function applyOpenCost(
        address account,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeAssets
    ) external onlyOperator returns (int256 netMarginChangeAssets, uint256 protocolFeeCreditedAssets) {
        return
            _applyOpenCost(
                account, marginDeltaAssets, tradeCostAssets, recipient, protocolFeeAccount, protocolFeeAssets
            );
    }

    function _applyOpenCost(
        address account,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeAssets
    ) internal returns (int256 netMarginChangeAssets, uint256 protocolFeeCreditedAssets) {
        MarginClearinghouseAccountingLib.OpenCostPlan memory plan =
            MarginClearinghouseAccountingLib.planOpenCostApplication(
                _buildAccountAssetBuckets(account), marginDeltaAssets, tradeCostAssets
            );

        if (plan.insufficientFreeEquity) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }

        netMarginChangeAssets = plan.netMarginChangeAssets;
        if (plan.settlementCreditAssets > 0) {
            _creditSettlementAssets(account, plan.settlementCreditAssets);
        }

        if (plan.positionMarginLockedAssets > 0) {
            _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginLockedAssets);
        }

        if (plan.settlementDebitAssets > 0) {
            protocolFeeCreditedAssets = _routeSettlementDebit(
                account, plan.settlementDebitAssets, recipient, protocolFeeAccount, protocolFeeAssets
            );
        }
    }

    /// @notice Collects carry from canonical active position margin first, then free settlement.
    /// @dev Callable only by the engine or its reported settlement sidecar. Consumption is planned from canonical
    ///      stored buckets. Other locked buckets and trader claims remain protected; the caller retains uncovered
    ///      carry until subsequent collection or terminal recovery/waiver.
    /// @param account Account paying the loss
    /// @param lossAssets Loss to collect in six-decimal settlement token units
    /// @param recipient External recipient of the settlement tokens collected
    /// @return marginConsumedAssets Active position margin consumed in six-decimal settlement token units
    /// @return freeSettlementConsumedAssets Free settlement consumed in six-decimal settlement token units
    /// @return uncoveredAssets Requested loss left uncovered in six-decimal settlement token units
    function consumeSettlementLoss(
        address account,
        uint256 lossAssets,
        address recipient
    )
        external
        onlyOperator
        returns (uint256 marginConsumedAssets, uint256 freeSettlementConsumedAssets, uint256 uncoveredAssets)
    {
        if (lossAssets == 0) {
            return (0, 0, 0);
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            _planCarryLossConsumption(account, lossAssets);
        freeSettlementConsumedAssets = consumption.freeSettlementConsumedAssets;
        marginConsumedAssets = consumption.activeMarginConsumedAssets;
        uncoveredAssets = consumption.uncoveredAssets;
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyCarryLossMutation(consumption);

        if (mutation.positionMarginUnlockedAssets > 0) {
            _consumeLockedMargin(
                account, IMarginClearinghouse.MarginBucket.Position, mutation.positionMarginUnlockedAssets
            );
        }

        uint256 totalConsumedAssets = mutation.settlementDebitAssets;
        if (totalConsumedAssets == 0) {
            return (marginConsumedAssets, freeSettlementConsumedAssets, uncoveredAssets);
        }

        settlementBalances[account] -= totalConsumedAssets;
        IERC20(settlementAsset).safeTransfer(recipient, totalConsumedAssets);
        emit AssetSeized(account, settlementAsset, totalConsumedAssets, recipient);
    }

    /// @notice Collects position price loss from the dedicated PnL pledge and no other settlement source.
    function consumePnlPledgeLoss(
        address account,
        uint256 priceLossAssets,
        address recipient
    ) external onlyOperator returns (uint256 consumedAssets, uint256 shortfallAssets) {
        return _consumePnlPledgeLoss(account, priceLossAssets, 0, recipient);
    }

    function _consumePnlPledgeLoss(
        address account,
        uint256 priceLossAssets,
        uint256 protectedPnlPledgeAssets,
        address recipient
    ) internal returns (uint256 consumedAssets, uint256 shortfallAssets) {
        uint256 pledgeAssets = positionMarginAssets[account];
        uint256 consumablePledgeAssets =
            pledgeAssets > protectedPnlPledgeAssets ? pledgeAssets - protectedPnlPledgeAssets : 0;
        consumedAssets = priceLossAssets < consumablePledgeAssets ? priceLossAssets : consumablePledgeAssets;
        shortfallAssets = priceLossAssets - consumedAssets;
        if (consumedAssets == 0) {
            return (0, shortfallAssets);
        }
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, consumedAssets);
        settlementBalances[account] -= consumedAssets;
        IERC20(settlementAsset).safeTransfer(recipient, consumedAssets);
        emit AssetSeized(account, settlementAsset, consumedAssets, recipient);
    }

    /// @notice Applies an engine-planned isolated full-liquidation settlement.
    /// @dev The pool transfer contains price PnL collected from pledge plus the LP fee collected from liquidation
    ///      reserve. Keeper and protocol allocations also consume liquidation reserve. Every other bucket is protected.
    /// @param account Liquidated account
    /// @param plan Liquidation settlement plan whose amounts use six-decimal settlement token units
    /// @param recipient External recipient of `plan.settlementSeizedAssets`; required when that amount is nonzero
    /// @param keeper Clearinghouse account credited with the bounty; required when the bounty is nonzero
    /// @param keeperBountyAssets Bounty debited from `account` and credited to `keeper`, in six-decimal settlement token units
    /// @param protocolFeeAccount Clearinghouse account credited with the liquidation protocol fee
    /// @param protocolFeeAssets Protocol fee debited from `account` and credited internally, in six-decimal settlement token units
    /// @param lpLiquidationFeeAssets LP fee included in `plan.settlementSeizedAssets`
    /// @return seizedAssets Amount transferred to `recipient` in six-decimal settlement token units
    function applyLiquidationSettlementPlan(
        address account,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        address recipient,
        address keeper,
        uint256 keeperBountyAssets,
        address protocolFeeAccount,
        uint256 protocolFeeAssets,
        uint256 lpLiquidationFeeAssets
    ) external onlyOperator returns (uint256 seizedAssets) {
        LiquidationSettlementExecution memory execution;
        execution.recipient = recipient;
        execution.keeper = keeper;
        execution.keeperBountyAssets = keeperBountyAssets;
        execution.protocolFeeAccount = protocolFeeAccount;
        execution.protocolFeeAssets = protocolFeeAssets;
        execution.lpLiquidationFeeAssets = lpLiquidationFeeAssets;
        return _applyLiquidationSettlementPlan(account, plan, execution);
    }

    function _applyLiquidationSettlementPlan(
        address account,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        LiquidationSettlementExecution memory execution
    ) internal returns (uint256 seizedAssets) {
        seizedAssets = plan.settlementSeizedAssets;
        uint256 pledgeBeforeAssets = positionMarginAssets[account];
        if (seizedAssets < execution.lpLiquidationFeeAssets) {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
        uint256 priceSeizureAssets = seizedAssets - execution.lpLiquidationFeeAssets;
        if (
            priceSeizureAssets > pledgeBeforeAssets || plan.positionMarginUnlockedAssets != pledgeBeforeAssets
                || plan.otherLockedMarginUnlockedAssets != 0
        ) {
            revert MarginClearinghouse__InvalidMarginBucket();
        }

        uint256 liquidationChargeAssets =
            execution.keeperBountyAssets + execution.protocolFeeAssets + execution.lpLiquidationFeeAssets;
        if (liquidationReserveBalances[account] < liquidationChargeAssets) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        if (liquidationChargeAssets > 0) {
            liquidationReserveBalances[account] -= liquidationChargeAssets;
            emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.LiquidationReserve, liquidationChargeAssets);
        }

        if (plan.positionMarginUnlockedAssets > 0) {
            _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedAssets);
        }
        uint256 settlementDebitAssets = priceSeizureAssets + liquidationChargeAssets;
        if (settlementDebitAssets > 0) {
            if (settlementBalances[account] < settlementDebitAssets) {
                revert MarginClearinghouse__InsufficientAssetToSeize();
            }
            settlementBalances[account] -= settlementDebitAssets;
            if (settlementBalances[account] < _totalLockedMarginAssets(account)) {
                revert MarginClearinghouse__InsufficientAssetToSeize();
            }
        }
        if (seizedAssets > 0) {
            if (execution.recipient == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            IERC20(settlementAsset).safeTransfer(execution.recipient, plan.settlementSeizedAssets);
            emit AssetSeized(account, settlementAsset, plan.settlementSeizedAssets, execution.recipient);
        }
        if (execution.keeperBountyAssets > 0) {
            if (execution.keeper == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            settlementBalances[execution.keeper] += execution.keeperBountyAssets;
            emit ReservedSettlementTransferred(account, execution.keeper, execution.keeperBountyAssets);
        }
        if (execution.protocolFeeAssets > 0) {
            if (execution.protocolFeeAccount == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            settlementBalances[execution.protocolFeeAccount] += execution.protocolFeeAssets;
            emit AssetSeized(account, settlementAsset, execution.protocolFeeAssets, execution.protocolFeeAccount);
        }

        uint256 releasedLiquidationReserveAssets = liquidationReserveBalances[account];
        if (releasedLiquidationReserveAssets > 0) {
            liquidationReserveBalances[account] = 0;
            emit MarginUnlocked(
                account, IMarginClearinghouse.MarginBucket.LiquidationReserve, releasedLiquidationReserveAssets
            );
        }
    }

    function _buildAccountAssetBuckets(
        address account
    ) internal view returns (IMarginClearinghouse.AccountAssetBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildIsolatedAccountAssetBuckets(
            settlementBalances[account],
            positionMarginAssets[account],
            liquidationReserveBalances[account],
            committedOrderMarginAssets[account],
            reservedSettlementAssets[account]
        );
    }

    function _planCarryLossConsumption(
        address account,
        uint256 lossAssets
    ) internal view returns (MarginClearinghouseAccountingLib.SettlementConsumption memory consumption) {
        return MarginClearinghouseAccountingLib.planCarryLossConsumption(_buildAccountAssetBuckets(account), lossAssets);
    }

    function _routeSettlementDebit(
        address account,
        uint256 amountAssets,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeAssets
    ) internal returns (uint256 protocolFeeCreditedAssets) {
        settlementBalances[account] -= amountAssets;

        if (protocolFeeAccount != address(0) && protocolFeeAssets > 0) {
            protocolFeeCreditedAssets = protocolFeeAssets < amountAssets ? protocolFeeAssets : amountAssets;
            settlementBalances[protocolFeeAccount] += protocolFeeCreditedAssets;
            emit AssetSeized(account, settlementAsset, protocolFeeCreditedAssets, protocolFeeAccount);
        }

        uint256 recipientTransferAssets = amountAssets - protocolFeeCreditedAssets;
        if (recipientTransferAssets > 0) {
            IERC20(settlementAsset).safeTransfer(recipient, recipientTransferAssets);
            emit AssetSeized(account, settlementAsset, recipientTransferAssets, recipient);
        }
    }

    function _creditSettlementAssets(
        address account,
        uint256 amountAssets
    ) internal {
        settlementBalances[account] += amountAssets;
    }

    function _checkpointCarryBeforeMarginChange(
        address account
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        _realizeOrCheckpointCarryBeforeMarginChange(account);
    }

    function _realizeOrCheckpointCarryBeforeMarginChange(
        address account
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        ICfdEngineCore(engine_).realizeCarryBeforeMarginChange(account);
    }

    function _isOrderRouter(
        address engine_,
        address caller
    ) internal view returns (bool) {
        try ICfdEngineCore(engine_).orderRouter() returns (address router_) {
            return router_ != address(0) && caller == router_;
        } catch {
            return false;
        }
    }

    function _isSettlementSidecar(
        address engine_,
        address caller
    ) internal view returns (bool) {
        try ICfdEngineCore(engine_).settlementSidecar() returns (address settlementSidecar_) {
            return settlementSidecar_ != address(0) && caller == settlementSidecar_;
        } catch {
            return false;
        }
    }

    function _isPositionProtectionBook(
        address engine_,
        address caller
    ) internal view returns (bool) {
        try ICfdEngineCore(engine_).orderRouter() returns (address router_) {
            if (router_ == address(0) || router_.code.length == 0) {
                return false;
            }
            try IPositionProtectionBookSource(router_).positionProtectionBook() returns (address book_) {
                return book_ != address(0) && caller == book_;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function _debitSettlementAssets(
        address account,
        uint256 amountAssets
    ) internal {
        if (settlementBalances[account] < amountAssets) {
            revert MarginClearinghouse__InsufficientAssetsForSettlement();
        }
        if (getFreeBuyingPowerAssets(account) < amountAssets) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        settlementBalances[account] -= amountAssets;
    }

    function _lockMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountAssets
    ) internal {
        if (getFreeBuyingPowerAssets(account) < amountAssets) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        _setBucketStorage(bucket, account, _bucketStorage(bucket, account) + amountAssets);
        emit MarginLocked(account, bucket, amountAssets);
    }

    function _unlockMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountAssets
    ) internal {
        _consumeLockedMargin(account, bucket, amountAssets);
    }

    function _reclassifyMargin(
        address account,
        IMarginClearinghouse.MarginBucket from,
        IMarginClearinghouse.MarginBucket to,
        uint256 amountAssets
    ) internal {
        if (amountAssets == 0) {
            return;
        }
        _consumeLockedMargin(account, from, amountAssets);
        _setBucketStorage(to, account, _bucketStorage(to, account) + amountAssets);
        emit MarginLocked(account, to, amountAssets);
    }

    function _consumeReservationBucket(
        address account,
        IMarginClearinghouse.ReservationBucket bucket,
        uint256 amountAssets
    ) internal {
        if (bucket == IMarginClearinghouse.ReservationBucket.CommittedOrder) {
            _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountAssets);
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _closeReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        IMarginClearinghouse.ReservationStatus terminalStatus
    ) internal {
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            revert MarginClearinghouse__ReservationNotActive();
        }
        uint64 previousOrderId = reservation.previousOrderId;
        uint64 nextOrderId = reservation.nextOrderId;
        if (previousOrderId == 0) {
            reservationQueues[reservation.account].head = nextOrderId;
        } else {
            orderReservations[previousOrderId].nextOrderId = nextOrderId;
        }
        if (nextOrderId == 0) {
            reservationQueues[reservation.account].tail = previousOrderId;
        } else {
            orderReservations[nextOrderId].previousOrderId = previousOrderId;
        }
        reservation.previousOrderId = 0;
        reservation.nextOrderId = 0;
        reservation.status = terminalStatus;
        reservation.remainingAmountAssets = 0;
        reservationQueues[reservation.account].count -= 1;
    }

    function marginReservationHead(
        address account
    ) external view returns (uint64) {
        return reservationQueues[account].head;
    }

    function marginReservationTail(
        address account
    ) external view returns (uint64) {
        return reservationQueues[account].tail;
    }

    /// @notice Returns the clearinghouse-owned active committed-margin FIFO, excluding exhausted records.
    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory) {
        return _activeMarginReservationIds(account);
    }

    function _activeMarginReservationIds(
        address account
    ) internal view returns (uint64[] memory ids) {
        ids = new uint64[](reservationQueues[account].count);
        uint64 cursor = reservationQueues[account].head;
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = cursor;
            cursor = orderReservations[cursor].nextOrderId;
        }
    }

    function recordBountyReservation(
        address account,
        IMarginClearinghouse.BountyKind kind,
        uint64 id,
        uint256 amountAssets
    ) external {
        _requireBountyOwner(kind);
        _recordBountyReservation(account, kind, id, amountAssets);
    }

    function _recordBountyReservation(
        address account,
        IMarginClearinghouse.BountyKind kind,
        uint64 id,
        uint256 amountAssets
    ) private {
        IMarginClearinghouse.BountyReservation storage reservation = bountyReservations[kind][id];
        if (account == address(0) || id == 0 || reservation.state != IMarginClearinghouse.BountyReservationState.None) {
            revert MarginClearinghouse__InvalidBountyReservation();
        }
        if (
            vpiRebateReserveBalances[account] + totalBountyReservationsAssets[account] + amountAssets
                > reservedSettlementAssets[account]
        ) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        reservation.account = account;
        reservation.amountAssets = _toUint96(amountAssets);
        reservation.state = IMarginClearinghouse.BountyReservationState.Active;
        reservation.freeFundedAssets = _toUint96(amountAssets);
        totalBountyReservationsAssets[account] += amountAssets;
        emit BountyReservationUpdated(kind, id, account, amountAssets);
    }

    event LedgerInvariantViolation(address indexed account, uint64 indexed orderId);

    function recoverExpiredBounty(
        address account,
        uint64 orderId,
        uint256 expectedFreeAssets
    ) external returns (IMarginClearinghouse.BountyRecovery memory result) {
        _requireBountyOwner(IMarginClearinghouse.BountyKind.Order);
        IMarginClearinghouse.BountyReservation storage reservation =
            bountyReservations[IMarginClearinghouse.BountyKind.Order][orderId];
        if (reservation.state != IMarginClearinghouse.BountyReservationState.Active) {
            result.discrepancy = 1;
            return result;
        }
        if (reservation.account != account) {
            result.discrepancy = 2;
            return result;
        }
        uint256 amount = reservation.amountAssets;
        if (
            reservation.freeFundedAssets != amount || reservation.freeFundedAssets != expectedFreeAssets
                || totalBountyReservationsAssets[account] < amount
                || vpiRebateReserveBalances[account] + totalBountyReservationsAssets[account]
                    > reservedSettlementAssets[account]
                || getAccountAssetBuckets(account).totalLockedMarginAssets > settlementBalances[account]
        ) {
            reservation.state = IMarginClearinghouse.BountyReservationState.Quarantined;
            result.discrepancy = 4;
            emit LedgerInvariantViolation(account, orderId);
            return result;
        }
        result.freeAssets = reservation.freeFundedAssets;
        result.discrepancy = 3;
        totalBountyReservationsAssets[account] -= amount;
        reservation.amountAssets = 0;
        reservation.state = IMarginClearinghouse.BountyReservationState.Settled;
        emit BountyReservationUpdated(IMarginClearinghouse.BountyKind.Order, orderId, account, 0);
    }

    function validateBountyReservation(
        address account,
        IMarginClearinghouse.BountyKind kind,
        uint64 id,
        uint256 entitlementAssets
    ) external view {
        IMarginClearinghouse.BountyReservation storage reservation = bountyReservations[kind][id];
        if (
            reservation.account != account || reservation.state != IMarginClearinghouse.BountyReservationState.Active
                || reservation.amountAssets != entitlementAssets || reservation.freeFundedAssets != entitlementAssets
                || totalBountyReservationsAssets[account] < entitlementAssets
        ) {
            revert MarginClearinghouse__InvalidBountyReservation();
        }
        _spendableActionReserveAssets(account);
        if (getAccountAssetBuckets(account).totalLockedMarginAssets > settlementBalances[account]) {
            revert MarginClearinghouse__InsufficientAssetsForSettlement();
        }
    }

    /// @notice Takes a complete bounty classification for terminal payout/refund; the action reserve remains locked.
    /// @dev The trusted owner completes the existing payout/refund in the same atomic transition. Other reservations
    ///      and the VPI floor remain protected throughout that transition.
    function takeBountyReservation(
        address account,
        IMarginClearinghouse.BountyKind kind,
        uint64 id
    ) external returns (uint256 amountAssets) {
        _requireBountyOwner(kind);
        IMarginClearinghouse.BountyReservation storage reservation = bountyReservations[kind][id];
        if (reservation.account != address(0) && reservation.account != account) {
            revert MarginClearinghouse__ReservationAccountMismatch(id, account, reservation.account);
        }
        if (reservation.state != IMarginClearinghouse.BountyReservationState.Active) {
            return 0;
        }
        amountAssets = reservation.amountAssets;
        if (totalBountyReservationsAssets[account] < amountAssets) {
            revert MarginClearinghouse__InvalidBountyReservation();
        }
        reservation.amountAssets = 0;
        reservation.state = IMarginClearinghouse.BountyReservationState.Settled;
        totalBountyReservationsAssets[account] -= amountAssets;
        if (amountAssets != 0) {
            emit BountyReservationUpdated(kind, id, account, 0);
        }
    }

    function getBountyReservation(
        IMarginClearinghouse.BountyKind kind,
        uint64 id
    ) external view returns (IMarginClearinghouse.BountyReservation memory) {
        return bountyReservations[kind][id];
    }

    function _requireBountyOwner(
        IMarginClearinghouse.BountyKind kind
    ) internal view {
        address engine_ = engine;
        if (
            engine_ == address(0)
                || (kind == IMarginClearinghouse.BountyKind.Order
                        ? !_isOrderRouter(engine_, msg.sender)
                        : !_isPositionProtectionBook(engine_, msg.sender))
        ) {
            revert MarginClearinghouse__NotOperator();
        }
    }

    /// @dev Reverts if a generic action-reserve decrease would consume negative-VPI backing or a queued bounty.
    function _requireActionReserveDecreaseAboveProtectedFloor(
        address account,
        uint256 amountAssets
    ) internal view {
        uint256 currentReserveAssets = reservedSettlementAssets[account];
        if (amountAssets > currentReserveAssets) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        uint256 protectedFloorAssets = vpiRebateReserveBalances[account] + totalBountyReservationsAssets[account];
        if (currentReserveAssets - amountAssets < protectedFloorAssets) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
    }

    function _consumeLockedMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountAssets
    ) internal {
        if (amountAssets == 0) {
            return;
        }
        uint256 currentBucket = _bucketStorage(bucket, account);
        if (currentBucket < amountAssets) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        _setBucketStorage(bucket, account, currentBucket - amountAssets);
        emit MarginUnlocked(account, bucket, amountAssets);
    }

    function _bucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        address account
    ) internal view returns (uint256 bucketValue) {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            return positionMarginAssets[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            return committedOrderMarginAssets[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            return reservedSettlementAssets[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.LiquidationReserve) {
            return liquidationReserveBalances[account];
        }
        revert MarginClearinghouse__InvalidMarginBucket();
    }

    function _setBucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        address account,
        uint256 amountAssets
    ) internal {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            positionMarginAssets[account] = amountAssets;
        } else if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            committedOrderMarginAssets[account] = amountAssets;
        } else if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            reservedSettlementAssets[account] = amountAssets;
        } else if (bucket == IMarginClearinghouse.MarginBucket.LiquidationReserve) {
            liquidationReserveBalances[account] = amountAssets;
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _totalLockedMarginAssets(
        address account
    ) internal view returns (uint256) {
        return positionMarginAssets[account] + liquidationReserveBalances[account] + committedOrderMarginAssets[account]
            + reservedSettlementAssets[account];
    }

    /// @notice Moves already-reserved settlement value between two internal clearinghouse accounts.
    /// @dev Callable only by the configured engine. Decreases the source's reserved bucket and settlement balance, then
    ///      credits the recipient's settlement balance; no ERC-20 transfer occurs. The recipient must be nonzero even
    ///      when `amount` is zero; zero otherwise is a no-op. A nonzero transfer requires sufficient source reserved
    ///      margin and settlement balance.
    /// @param account Source account whose reserved settlement and balance are debited
    /// @param recipient Destination account receiving an internal settlement credit
    /// @param amount Amount to move in six-decimal settlement token units
    function transferReservedSettlement(
        address account,
        address recipient,
        uint256 amount
    ) external onlyEngine {
        _transferActionReserve(account, recipient, amount);
    }

    function _transferActionReserve(
        address account,
        address recipient,
        uint256 amount
    ) internal {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (amount == 0) {
            return;
        }
        if (reservedSettlementAssets[account] < amount || settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        _requireActionReserveDecreaseAboveProtectedFloor(account, amount);

        reservedSettlementAssets[account] -= amount;
        settlementBalances[account] -= amount;
        settlementBalances[recipient] += amount;

        emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amount);
        emit ReservedSettlementTransferred(account, recipient, amount);
    }

    /// @notice Returns an account's internal settlement settlement token balance.
    /// @dev Does not include unrealized PnL or apply engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Account balance in six-decimal settlement token units
    function balanceAssets(
        address account
    ) external view returns (uint256) {
        return settlementBalances[account];
    }

    /// @notice Returns the total locked settlement token margin across all buckets for an account.
    /// @param account Account to inspect
    /// @return Sum of position, liquidation-reserve, committed-order, and reserved-settlement margin in settlement token units
    function lockedMarginAssets(
        address account
    ) external view returns (uint256) {
        return _totalLockedMarginAssets(account);
    }

    /// @notice Returns the typed locked-margin buckets for an account.
    /// @dev Every field uses six-decimal settlement token units. The total includes liquidation reserve, which has no separate
    ///      field in this legacy struct; use `getPnlIsolationBuckets` for the complete typed breakdown.
    /// @param account Account to inspect
    /// @return buckets Position, committed-order, reserved-settlement, and total locked amounts
    function getLockedMarginBuckets(
        address account
    ) external view returns (IMarginClearinghouse.LockedMarginBuckets memory buckets) {
        buckets.positionMarginAssets = positionMarginAssets[account];
        buckets.committedOrderMarginAssets = committedOrderMarginAssets[account];
        buckets.reservedSettlementAssets = reservedSettlementAssets[account];
        buckets.totalLockedMarginAssets = _totalLockedMarginAssets(account);
    }

    /// @notice Returns the reservation record for a specific order id.
    /// @dev Amount fields use six-decimal settlement token units but are stored as `uint96`. An unused id returns the default record.
    /// @param orderId Order reservation id to inspect
    /// @return reservation Account, bucket, status, original amount, and remaining amount
    function getOrderReservation(
        uint64 orderId
    ) external view returns (IMarginClearinghouse.OrderReservation memory reservation) {
        return orderReservations[orderId];
    }

    /// @notice Returns the aggregate active reservation summary for an account.
    /// @dev The margin amount uses six-decimal settlement token units and equals the sum of active reservation remainders.
    /// @param account Account to inspect
    /// @return summary Aggregate remaining committed-order margin and number of active reservations
    function getAccountReservationSummary(
        address account
    ) external view returns (IMarginClearinghouse.AccountReservationSummary memory summary) {
        summary.activeCommittedOrderMarginAssets = activeCommittedOrderReservationAssets[account];
        summary.activeReservationCount = reservationQueues[account].count;
    }

    function _toUint96(
        uint256 value
    ) internal pure returns (uint96) {
        if (value > type(uint96).max) {
            revert MarginClearinghouse__AmountOverflow();
        }
        return uint96(value);
    }

}
