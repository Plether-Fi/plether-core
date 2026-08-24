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
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "@plether/perps/interfaces/IWithdrawGuard.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

interface IPositionProtectionBookSource {

    function positionProtectionBook() external view returns (address);

}

/// @title MarginClearinghouse
/// @notice Custodies settlement USDC and maintains the margin buckets used by Plether perpetual accounts.
/// @dev Account ids are addresses. A settlement balance is an internal claim on this contract's USDC custody;
///      PnL pledge, liquidation reserve, committed-order margin, and action reserve are encumbrances within that
///      balance, not separate token balances. The contract assumes a standard six-decimal USDC implementation and
///      does not support fee-on-transfer accounting. The deployer owns the one-time engine wiring through
///      `Ownable2Step`.
/// @custom:security-contact contact@plether.com
contract MarginClearinghouse is IMarginAccount, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    struct LiquidationSettlementExecution {
        address recipient;
        address keeper;
        uint256 keeperBountyUsdc;
        address protocolFeeAccount;
        uint256 protocolFeeUsdc;
        uint256 lpLiquidationFeeUsdc;
    }

    mapping(address => uint256) internal settlementBalances;

    mapping(address => uint256) internal positionMarginUsdc;
    mapping(address => uint256) internal committedOrderMarginUsdc;
    mapping(address => uint256) internal reservedSettlementUsdc;
    /// @dev Mandatory negative-lifetime-VPI floor contained inside `reservedSettlementUsdc`; never counted twice.
    mapping(address => uint256) internal vpiRebateReserveBalances;
    mapping(address => uint256) internal liquidationReserveBalances;
    mapping(uint64 => IMarginClearinghouse.OrderReservation) internal orderReservations;
    mapping(address => uint256) internal activeCommittedOrderReservationUsdc;
    mapping(address => uint256) internal activeReservationCount;

    /// @notice Settlement ERC-20 whose native units are used for every balance and margin amount.
    /// @dev Expected to be six-decimal USDC; the constructor does not inspect the token contract or its decimals.
    address public immutable settlementAsset;

    /// @notice Engine authorized to operate account balances and margin buckets.
    /// @dev Zero until `setEngine` is called. Some operations also authorize the engine-reported order router or
    ///      settlement sidecar, as documented on those entrypoints.
    address public engine;

    /// @notice The caller is not the engine or the engine-derived integration authorized for the operation.
    error MarginClearinghouse__NotOperator();

    /// @notice A user attempted to deposit to or withdraw from an account other than its own address.
    error MarginClearinghouse__NotAccountOwner();

    /// @notice An operation that requires a nonzero amount received zero.
    error MarginClearinghouse__ZeroAmount();

    /// @notice The account's settlement balance cannot cover a requested user withdrawal.
    error MarginClearinghouse__InsufficientBalance();

    /// @notice Free settlement equity cannot cover a lock or would fall below locked margin after withdrawal.
    error MarginClearinghouse__InsufficientFreeEquity();

    /// @notice The account's settlement balance cannot cover a settlement debit or its remaining locked margin.
    error MarginClearinghouse__InsufficientUsdcForSettlement();

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

    /// @notice Aggregate committed-margin mutation was attempted while per-order reservations remain active.
    error MarginClearinghouse__ReservationLedgerActive();

    /// @notice The owner attempted to replace the already configured engine.
    error MarginClearinghouse__EngineAlreadySet();

    /// @notice A required engine, recipient, or keeper address is zero.
    error MarginClearinghouse__ZeroAddress();

    /// @notice A typed locked-margin bucket cannot cover the requested decrease.
    error MarginClearinghouse__InsufficientBucketMargin();

    /// @notice A reservation amount cannot be represented by the reservation ledger's `uint96` fields.
    error MarginClearinghouse__AmountOverflow();

    /// @notice Planned action-reserve consumption does not match the reserve available above queued bounties.
    error MarginClearinghouse__ActionReserveMismatch();

    /// @notice Emitted after settlement tokens are transferred in and credited to an account.
    /// @param account Account credited with the deposit
    /// @param asset Settlement token transferred in
    /// @param amount Amount transferred and credited, in the token's native units
    event Deposit(address indexed account, address indexed asset, uint256 amount);

    /// @notice Emitted after settlement tokens are debited from an account and transferred to its owner.
    /// @param account Account debited by the withdrawal
    /// @param asset Settlement token transferred out
    /// @param amount Amount debited and transferred, in the token's native units
    event Withdraw(address indexed account, address indexed asset, uint256 amount);

    /// @notice Emitted when an account's typed locked-margin bucket increases.
    /// @dev Locking is an internal reclassification and does not itself move settlement tokens.
    /// @param account Account whose locked bucket increased
    /// @param bucket Locked-margin bucket that increased
    /// @param amountUsdc Increase in six-decimal USDC units
    event MarginLocked(address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc);

    /// @notice Emitted when an account's typed locked-margin bucket decreases.
    /// @dev The decrease may release funds or accompany a settlement debit; the event alone does not imply that
    ///      the amount became withdrawable.
    /// @param account Account whose locked bucket decreased
    /// @param bucket Locked-margin bucket that decreased
    /// @param amountUsdc Decrease in six-decimal USDC units
    event MarginUnlocked(address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc);

    /// @notice Emitted when committed-order margin is locked against a new order id.
    /// @param orderId Order id assigned the reservation
    /// @param account Account whose committed-order margin backs the reservation
    /// @param bucket Reservation bucket used by the record
    /// @param amountUsdc Original reserved amount in six-decimal USDC units
    event ReservationCreated(
        uint64 indexed orderId,
        address indexed account,
        IMarginClearinghouse.ReservationBucket indexed bucket,
        uint256 amountUsdc
    );

    /// @notice Emitted when all or part of an active order reservation is consumed.
    /// @param orderId Order id whose reservation was consumed
    /// @param account Account that owns the reservation
    /// @param amountUsdc Amount consumed in six-decimal USDC units
    /// @param remainingAmountUsdc Amount still active after consumption, in six-decimal USDC units
    event ReservationConsumed(
        uint64 indexed orderId, address indexed account, uint256 amountUsdc, uint256 remainingAmountUsdc
    );

    /// @notice Emitted when the remaining amount of an active reservation is released.
    /// @param orderId Order id whose reservation was released
    /// @param account Account that owns the reservation
    /// @param amountUsdc Amount released from committed-order margin, in six-decimal USDC units
    event ReservationReleased(uint64 indexed orderId, address indexed account, uint256 amountUsdc);

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
    /// @param amountUsdc Amount transferred in six-decimal USDC units
    event ReservedSettlementTransferred(address indexed account, address indexed recipient, uint256 amountUsdc);

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

    /// @dev Restricts reserved-settlement locks to the engine, its router, or that router's immutable book.
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

    /// @dev Restricts reserved-settlement unlocks to the engine, its router/sidecar, or that router's immutable book.
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

    /// @dev Restricts calls to the engine, its settlement sidecar, or its order router.
    modifier onlyEngineIntegration() {
        address engine_ = engine;
        if (
            engine_ == address(0)
                || (msg.sender != engine_
                    && !_isSettlementSidecar(engine_, msg.sender)
                    && !_isOrderRouter(engine_, msg.sender))
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
    /// @param _settlementAsset ERC-20 used for settlement custody; expected to be six-decimal USDC
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

    // ==========================================
    // USER ACTIONS
    // ==========================================

    /// @notice Transfers settlement USDC from the caller and credits the caller's margin account.
    /// @dev `account` must equal `msg.sender` and `amount` must be nonzero. Requires prior ERC-20 allowance. If the
    ///      engine is configured, the deposit invokes its carry-realization hook after crediting the balance.
    /// @param account Account receiving the deposit; must be the caller's address
    /// @param amount Amount to transfer and credit, in six-decimal USDC units
    function deposit(
        address account,
        uint256 amount
    ) external {
        _deposit(account, msg.sender, amount);
    }

    /// @notice Transfers settlement USDC from the caller into its canonical address-based margin account.
    /// @dev Requires a nonzero amount and prior ERC-20 allowance. If the engine is configured, the deposit invokes
    ///      its carry-realization hook after crediting the balance.
    /// @param amount Amount to transfer and credit, in six-decimal USDC units
    function depositMargin(
        uint256 amount
    ) external nonReentrant {
        _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Debits the caller's margin account and transfers settlement USDC to the caller.
    /// @dev `account` must equal `msg.sender`. Before transfer, the function checkpoints carry, applies the engine's
    ///      withdrawal guard when configured, and verifies the remaining settlement balance covers all locked
    ///      buckets. A zero amount is permitted but still runs those checks and hooks.
    /// @param account Account funding the withdrawal; must be the caller's address
    /// @param amount Amount to debit and transfer, in six-decimal USDC units
    function withdraw(
        address account,
        uint256 amount
    ) external nonReentrant {
        _withdraw(account, msg.sender, amount);
    }

    /// @notice Withdraws settlement USDC from the caller's canonical address-based margin account.
    /// @dev Checkpoints carry, applies the configured engine's withdrawal guard, and verifies the remaining
    ///      settlement balance covers every locked bucket. A zero amount is permitted but still runs the checks.
    /// @param amount Amount to debit and transfer, in six-decimal USDC units
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

        uint256 remainingEquity = getAccountEquityUsdc(account);
        uint256 totalLockedMargin = _totalLockedMarginUsdc(account);
        if (remainingEquity < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[account] < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }

        IERC20(settlementAsset).safeTransfer(owner, amount);
        emit Withdraw(account, settlementAsset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns an account's internal settlement USDC balance.
    /// @dev This clearinghouse-local value does not include unrealized PnL or apply engine withdrawal guards.
    /// @param account Account to inspect
    /// @return totalEquityUsdc Settlement balance in six-decimal USDC units
    function getAccountEquityUsdc(
        address account
    ) public view override returns (uint256 totalEquityUsdc) {
        return settlementBalances[account];
    }

    /// @notice Returns settlement balance not encumbered by any typed locked-margin bucket.
    /// @dev Equals `max(settlement balance - total locked margin, 0)` and excludes unrealized PnL and engine
    ///      withdrawal constraints.
    /// @param account Account to query
    /// @return Unencumbered settlement balance in six-decimal USDC units
    function getFreeBuyingPowerUsdc(
        address account
    ) public view override returns (uint256) {
        uint256 equity = getAccountEquityUsdc(account);
        uint256 encumbered = _totalLockedMarginUsdc(account);
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns the account's settlement balance and its typed locked/free margin breakdown.
    /// @dev `otherLockedMarginUsdc` combines liquidation, committed-order, and action-reserve margin. Every amount is in
    ///      six-decimal USDC units; unrealized PnL and engine withdrawal guards are not included.
    /// @param account Account to inspect
    /// @return buckets Settlement balance, total locked, position locked, other locked, and free settlement amounts
    function getAccountUsdcBuckets(
        address account
    ) public view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = _buildAccountUsdcBuckets(account);
    }

    /// @notice Returns the canonical V2 PnL-isolated settlement classification.
    function getPnlIsolationBuckets(
        address account
    ) public view returns (IMarginClearinghouse.PnlIsolationBuckets memory buckets) {
        buckets.settlementBalanceUsdc = settlementBalances[account];
        buckets.pnlPledgeUsdc = positionMarginUsdc[account];
        buckets.liquidationReserveUsdc = liquidationReserveBalances[account];
        buckets.orderMarginUsdc = committedOrderMarginUsdc[account];
        buckets.actionReserveUsdc = reservedSettlementUsdc[account];
        buckets.vpiRebateReserveUsdc = vpiRebateReserveBalances[account];
        buckets.totalLockedUsdc = _totalLockedMarginUsdc(account);
        buckets.freeSettlementUsdc = buckets.settlementBalanceUsdc > buckets.totalLockedUsdc
            ? buckets.settlementBalanceUsdc - buckets.totalLockedUsdc
            : 0;
    }

    function pnlPledgeUsdc(
        address account
    ) external view returns (uint256) {
        return positionMarginUsdc[account];
    }

    function liquidationReserveUsdc(
        address account
    ) external view returns (uint256) {
        return liquidationReserveBalances[account];
    }

    function orderMarginUsdc(
        address account
    ) external view returns (uint256) {
        return committedOrderMarginUsdc[account];
    }

    function actionReserveUsdc(
        address account
    ) external view returns (uint256) {
        return reservedSettlementUsdc[account];
    }

    function vpiRebateReserveUsdc(
        address account
    ) external view returns (uint256) {
        return vpiRebateReserveBalances[account];
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Encumbers free settlement in the active-position margin bucket.
    /// @dev Callable only by the engine or its reported settlement sidecar. The settlement balance is unchanged;
    ///      the call reverts if free settlement is less than `amountUsdc`. This entrypoint does not checkpoint carry.
    /// @param account Account whose settlement should be encumbered
    /// @param amountUsdc Amount to lock in six-decimal USDC units
    function lockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Decreases an account's active-position margin bucket by an exact amount.
    /// @dev Callable only by the engine or its reported settlement sidecar. The settlement balance is unchanged, and
    ///      the call reverts rather than clamping when `amountUsdc` exceeds the position-margin bucket. This
    ///      entrypoint does not checkpoint carry.
    /// @param account Account whose position margin should be decreased
    /// @param amountUsdc Exact amount to remove in six-decimal USDC units
    function unlockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Encumbers free settlement in the aggregate committed-order margin bucket.
    /// @dev Callable only by the engine or its reported settlement sidecar. This legacy aggregate path checkpoints
    ///      carry and reverts while the account has active per-order reservations. The settlement balance is unchanged.
    /// @param account Account whose settlement should be encumbered
    /// @param amountUsdc Amount to lock in six-decimal USDC units
    function lockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _requireNoActiveReservations(account);
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    /// @notice Locks free settlement as committed-order margin and records it against a unique order id.
    /// @dev Callable only by the engine or its reported order router. Checkpoints carry, requires a nonzero amount that
    ///      fits `uint96`, and permanently prevents reuse of an id once any record exists. No tokens move.
    /// @param account Account whose committed-order margin backs the reservation
    /// @param orderId Router order id receiving the reservation
    /// @param amountUsdc Amount to reserve in six-decimal USDC units
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountUsdc
    ) external onlyEngineOrOrderRouter {
        if (orderReservations[orderId].status != IMarginClearinghouse.ReservationStatus.None) {
            revert MarginClearinghouse__ReservationAlreadyExists();
        }
        if (amountUsdc == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
        uint96 amount96 = _toUint96(amountUsdc);
        orderReservations[orderId] = IMarginClearinghouse.OrderReservation({
            account: account,
            bucket: IMarginClearinghouse.ReservationBucket.CommittedOrder,
            status: IMarginClearinghouse.ReservationStatus.Active,
            originalAmountUsdc: amount96,
            remainingAmountUsdc: amount96
        });
        activeCommittedOrderReservationUsdc[account] += amountUsdc;
        activeReservationCount[account] += 1;

        emit ReservationCreated(orderId, account, IMarginClearinghouse.ReservationBucket.CommittedOrder, amountUsdc);
    }

    /// @notice Decreases the aggregate committed-order margin bucket by an exact amount.
    /// @dev Callable only by the engine or its reported settlement sidecar. This legacy aggregate path checkpoints
    ///      carry and reverts while any per-order reservation is active. It also reverts on bucket underflow; no tokens
    ///      move and the settlement balance is unchanged.
    /// @param account Account whose committed-order margin should be decreased
    /// @param amountUsdc Exact amount to remove in six-decimal USDC units
    function unlockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _requireNoActiveReservations(account);
        _checkpointCarryBeforeMarginChange(account);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    /// @notice Releases all remaining committed-order margin for an active reservation.
    /// @dev Callable only by the engine or its reported settlement sidecar. Checkpoints carry, decreases the locked
    ///      bucket and active aggregates, marks the reservation released, and leaves settlement balance unchanged so
    ///      the released amount becomes free settlement.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc Amount released in six-decimal USDC units
    function releaseOrderReservation(
        uint64 orderId
    ) external onlyOperator returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = _activeReservation(orderId);
        _checkpointCarryBeforeMarginChange(reservation.account);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.account, releasedUsdc);
    }

    /// @notice Releases all remaining committed-order margin if the reservation is still active.
    /// @dev Callable only by the engine or its reported order router. An inactive or unknown id returns zero without
    ///      checkpointing carry or mutating state. An active release updates the bucket, aggregates, and terminal status
    ///      without changing settlement balance.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc Amount released in six-decimal USDC units, or zero if not active
    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external onlyEngineOrOrderRouter returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderId];
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            return 0;
        }

        _checkpointCarryBeforeMarginChange(reservation.account);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.account, releasedUsdc);
    }

    /// @notice Consumes up to a requested amount from one active order reservation.
    /// @dev Callable only by the engine or its reported settlement sidecar. Consumption decreases committed-order
    ///      locked margin and active reservation aggregates but does not debit settlement balance or move tokens. The
    ///      reservation becomes `Consumed` when exhausted; an inactive id reverts.
    /// @param orderId Order reservation id to consume
    /// @param amountUsdc Maximum amount to consume in six-decimal USDC units
    /// @return consumedUsdc Amount consumed, capped by the reservation's remainder, in six-decimal USDC units
    function consumeOrderReservation(
        uint64 orderId,
        uint256 amountUsdc
    ) external onlyOperator returns (uint256 consumedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = _activeReservation(orderId);
        consumedUsdc = amountUsdc > reservation.remainingAmountUsdc ? reservation.remainingAmountUsdc : amountUsdc;
        if (consumedUsdc == 0) {
            return 0;
        }

        _consumeReservation(reservation, consumedUsdc, true, IMarginClearinghouse.ReservationStatus.Consumed);

        emit ReservationConsumed(orderId, reservation.account, consumedUsdc, reservation.remainingAmountUsdc);
    }

    /// @notice Atomically promotes exact pending-order margin into live-position PnL pledge.
    /// @dev Settlement custody and total locked settlement are unchanged. The exact amount must fit within the active
    ///      reservation; unlike the legacy consumption entrypoint, this function never clamps an oversized request.
    function promoteOrderReservationToPnlPledge(
        uint64 orderId,
        uint256 amountUsdc
    ) external onlyOperator {
        IMarginClearinghouse.OrderReservation storage reservation = _activeReservation(orderId);
        if (amountUsdc > reservation.remainingAmountUsdc) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        if (amountUsdc == 0) {
            return;
        }

        address account = reservation.account;
        _consumeReservation(reservation, amountUsdc, true, IMarginClearinghouse.ReservationStatus.Consumed);
        positionMarginUsdc[account] += amountUsdc;

        emit ReservationConsumed(orderId, account, amountUsdc, reservation.remainingAmountUsdc);
        emit MarginLocked(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Consumes an account's active order reservations in router-reported FIFO order.
    /// @dev Callable only by the engine or its reported settlement sidecar. The function queries the configured order
    ///      router for reservation ids, skips inactive records, and may return less than requested. Consumption reduces
    ///      committed-order locks and reservation aggregates but does not debit settlement balance or move tokens.
    /// @param account Account whose active reservations should be consumed
    /// @param amountUsdc Maximum amount to consume in six-decimal USDC units
    /// @return consumedUsdc Amount consumed in six-decimal USDC units
    function consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc
    ) external onlyOperator returns (uint256 consumedUsdc) {
        return _consumeAccountOrderReservations(account, amountUsdc, true);
    }

    /// @notice Consumes active order reservations in the exact order supplied until the requested amount is exhausted.
    /// @dev Callable only by the engine or its reported settlement sidecar. Inactive ids are skipped and ids are not
    ///      required to belong to one account. Consumption decreases each reservation's committed-order bucket and
    ///      aggregates without debiting settlement balance or moving tokens; the return may be less than requested.
    /// @param orderIds Reservation order ids to inspect and consume in supplied order
    /// @param amountUsdc Maximum aggregate amount to consume in six-decimal USDC units
    /// @return consumedUsdc Aggregate amount consumed in six-decimal USDC units
    function consumeOrderReservationsById(
        uint64[] calldata orderIds,
        uint256 amountUsdc
    ) external onlyOperator returns (uint256 consumedUsdc) {
        return _consumeOrderReservationsById(orderIds, amountUsdc);
    }

    function _consumeOrderReservationsById(
        uint64[] memory orderIds,
        uint256 amountUsdc
    ) internal returns (uint256 consumedUsdc) {
        if (amountUsdc == 0) {
            return 0;
        }

        uint256 remainingUsdc = amountUsdc;
        for (uint256 i = 0; i < orderIds.length && remainingUsdc > 0; i++) {
            IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderIds[i]];
            if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
                continue;
            }

            uint256 reservationConsumedUsdc =
                remainingUsdc > reservation.remainingAmountUsdc ? reservation.remainingAmountUsdc : remainingUsdc;
            if (reservationConsumedUsdc == 0) {
                continue;
            }

            _consumeReservation(
                reservation, reservationConsumedUsdc, true, IMarginClearinghouse.ReservationStatus.Consumed
            );

            remainingUsdc -= reservationConsumedUsdc;
            consumedUsdc += reservationConsumedUsdc;
            emit ReservationConsumed(
                orderIds[i], reservation.account, reservationConsumedUsdc, reservation.remainingAmountUsdc
            );
        }
    }

    function _consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc,
        bool consumeBuckets
    ) internal returns (uint256 consumedUsdc) {
        if (amountUsdc == 0) {
            return 0;
        }

        uint64[] memory reservationIds = _activeMarginReservationIds(account);
        uint256 remainingUsdc = amountUsdc;
        for (uint256 i = 0; i < reservationIds.length && remainingUsdc > 0; i++) {
            IMarginClearinghouse.OrderReservation storage reservation = orderReservations[reservationIds[i]];
            if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
                continue;
            }

            uint256 reservationConsumedUsdc =
                remainingUsdc > reservation.remainingAmountUsdc ? reservation.remainingAmountUsdc : remainingUsdc;
            if (reservationConsumedUsdc == 0) {
                continue;
            }

            _consumeReservation(
                reservation, reservationConsumedUsdc, consumeBuckets, IMarginClearinghouse.ReservationStatus.Consumed
            );

            remainingUsdc -= reservationConsumedUsdc;
            consumedUsdc += reservationConsumedUsdc;
            emit ReservationConsumed(
                reservationIds[i], account, reservationConsumedUsdc, reservation.remainingAmountUsdc
            );
        }
    }

    function _releaseReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        bool consumeBuckets
    ) internal returns (uint256 releasedUsdc) {
        releasedUsdc = reservation.remainingAmountUsdc;
        if (releasedUsdc > 0) {
            _consumeReservation(
                reservation, releasedUsdc, consumeBuckets, IMarginClearinghouse.ReservationStatus.Released
            );
        } else {
            _closeReservation(reservation, IMarginClearinghouse.ReservationStatus.Released);
        }
    }

    function _consumeReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        uint256 amountUsdc,
        bool consumeBuckets,
        IMarginClearinghouse.ReservationStatus terminalStatus
    ) internal {
        reservation.remainingAmountUsdc -= _toUint96(amountUsdc);
        if (consumeBuckets) {
            _consumeReservationBucket(reservation.account, reservation.bucket, amountUsdc);
        }
        _decreaseActiveReservation(reservation.account, reservation.bucket, amountUsdc);

        if (reservation.remainingAmountUsdc == 0) {
            _closeReservation(reservation, terminalStatus);
        }
    }

    function _decreaseActiveReservation(
        address account,
        IMarginClearinghouse.ReservationBucket,
        uint256 amountUsdc
    ) internal {
        activeCommittedOrderReservationUsdc[account] -= amountUsdc;
    }

    /// @notice Encumbers free settlement in the reserved-settlement bucket.
    /// @dev Callable only by the engine, its reported router, or the router's immutable position-protection book.
    ///      Checkpoints carry before increasing the bucket. The settlement balance is unchanged, and insufficient
    ///      free settlement reverts.
    /// @param account Account whose settlement should be reserved
    /// @param amountUsdc Amount to reserve in six-decimal USDC units
    function lockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external onlyReservedSettlementLocker {
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Decreases the reserved-settlement bucket, making the amount free settlement.
    /// @dev Callable only by the engine, its reported router or settlement sidecar, or the router's immutable
    ///      position-protection book. Checkpoints carry and reverts rather than clamping on bucket underflow. The
    ///      settlement balance is unchanged.
    /// @param account Account whose reserved settlement should be unlocked
    /// @param amountUsdc Exact amount to unlock in six-decimal USDC units
    function unlockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external onlyReservedSettlementOperator {
        _checkpointCarryBeforeMarginChange(account);
        _requireActionReserveDecreaseAboveProtectedFloor(account, amountUsdc);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Canonical V2 alias that locks free settlement for action charges and execution bounties.
    function lockActionReserve(
        address account,
        uint256 amountUsdc
    ) external onlyEngineIntegration {
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Releases action reserve back to free settlement.
    function releaseActionReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(account);
        _requireActionReserveDecreaseAboveProtectedFloor(account, amountUsdc);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Consumes action reserve into another clearinghouse account without moving tokens.
    function consumeActionReserve(
        address account,
        address recipient,
        uint256 amountUsdc
    ) external onlyEngine {
        _transferActionReserve(account, recipient, amountUsdc);
    }

    /// @notice Locks free settlement into the action reserve and its mandatory negative-VPI sub-ledger.
    /// @dev The sub-ledger is a floor inside `reservedSettlementUsdc`, not an additional locked bucket.
    function lockVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
        vpiRebateReserveBalances[account] += amountUsdc;
    }

    /// @notice Reclassifies newly locked PnL pledge into mandatory negative-VPI backing without moving cash.
    function reclassifyPnlPledgeToVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
        reservedSettlementUsdc[account] += amountUsdc;
        vpiRebateReserveBalances[account] += amountUsdc;
        emit MarginLocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Releases no-longer-required negative-VPI backing into free settlement.
    function releaseVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        if (vpiRebateReserveBalances[account] < amountUsdc) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        vpiRebateReserveBalances[account] -= amountUsdc;
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Returns reserved negative-VPI backing to the LP pool as cash recovery.
    function consumeVpiRebateReserve(
        address account,
        address recipient,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (
            vpiRebateReserveBalances[account] < amountUsdc || reservedSettlementUsdc[account] < amountUsdc
                || settlementBalances[account] < amountUsdc
        ) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        vpiRebateReserveBalances[account] -= amountUsdc;
        reservedSettlementUsdc[account] -= amountUsdc;
        settlementBalances[account] -= amountUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, amountUsdc);
        emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
        emit AssetSeized(account, settlementAsset, amountUsdc, recipient);
    }

    /// @notice Collects an action charge from spendable action reserve, free settlement, then committed order margin.
    /// @dev Negative-VPI backing and router-attributed execution bounties remain protected in the shared action-reserve
    ///      bucket. The caller supplies the exact planned reserve and committed-margin split so a state mismatch
    ///      reverts. Committed order margin is consumed in router-reported FIFO order. PnL pledge and liquidation
    ///      reserve are never reachable, and any charge above eligible value is waived.
    function consumeActionCharge(
        address account,
        uint256 chargeUsdc,
        uint256 actionReserveConsumedUsdc,
        uint256 actionCommittedMarginConsumedUsdc,
        address recipient,
        address protocolTreasury,
        uint256 protocolFeeUsdc
    ) external onlyOperator returns (uint256 collectedUsdc, uint256 protocolFeeCreditedUsdc) {
        collectedUsdc = _validateActionChargeConsumption(
            account, chargeUsdc, actionReserveConsumedUsdc, actionCommittedMarginConsumedUsdc
        );
        if (collectedUsdc == 0) {
            return (0, 0);
        }

        if (actionReserveConsumedUsdc > 0) {
            reservedSettlementUsdc[account] -= actionReserveConsumedUsdc;
            emit MarginUnlocked(
                account, IMarginClearinghouse.MarginBucket.ReservedSettlement, actionReserveConsumedUsdc
            );
        }
        if (actionCommittedMarginConsumedUsdc > 0) {
            uint256 consumedCommittedMarginUsdc =
                _consumeAccountOrderReservations(account, actionCommittedMarginConsumedUsdc, true);
            if (consumedCommittedMarginUsdc != actionCommittedMarginConsumedUsdc) {
                revert MarginClearinghouse__IncompleteReservationCoverage();
            }
        }

        protocolFeeCreditedUsdc =
            _routeSettlementDebit(account, collectedUsdc, recipient, protocolTreasury, protocolFeeUsdc);
    }

    function _validateActionChargeConsumption(
        address account,
        uint256 chargeUsdc,
        uint256 actionReserveConsumedUsdc,
        uint256 actionCommittedMarginConsumedUsdc
    ) private view returns (uint256 collectedUsdc) {
        uint256 actionReserveAvailableUsdc = _spendableActionReserveUsdc(account);
        uint256 freeSettlementAvailableUsdc = getFreeBuyingPowerUsdc(account);
        uint256 eligibleUsdc =
            actionReserveAvailableUsdc + freeSettlementAvailableUsdc + committedOrderMarginUsdc[account];
        collectedUsdc = chargeUsdc < eligibleUsdc ? chargeUsdc : eligibleUsdc;

        uint256 expectedActionReserveConsumedUsdc =
            collectedUsdc < actionReserveAvailableUsdc ? collectedUsdc : actionReserveAvailableUsdc;
        uint256 chargeAfterReserveUsdc = collectedUsdc - expectedActionReserveConsumedUsdc;
        uint256 expectedCommittedMarginConsumedUsdc = chargeAfterReserveUsdc > freeSettlementAvailableUsdc
            ? chargeAfterReserveUsdc - freeSettlementAvailableUsdc
            : 0;
        if (
            actionReserveConsumedUsdc != expectedActionReserveConsumedUsdc
                || actionCommittedMarginConsumedUsdc != expectedCommittedMarginConsumedUsdc
        ) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
    }

    function _spendableActionReserveUsdc(
        address account
    ) private view returns (uint256) {
        uint256 actionReserveBalanceUsdc = reservedSettlementUsdc[account];
        uint256 protectedActionReserveUsdc = _activeExecutionBountyUsdc(account) + vpiRebateReserveBalances[account];
        if (actionReserveBalanceUsdc < protectedActionReserveUsdc) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        return actionReserveBalanceUsdc - protectedActionReserveUsdc;
    }

    /// @notice Locks free settlement exclusively for keeper and protocol liquidation charges.
    function lockLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external onlyEngineIntegration {
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.LiquidationReserve, amountUsdc);
    }

    /// @notice Releases liquidation reserve back to free settlement without debiting custody.
    function releaseLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.LiquidationReserve, amountUsdc);
    }

    /// @notice Reclassifies PnL pledge as liquidation reserve; total locked settlement is unchanged.
    function reclassifyPnlPledgeToLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _reclassifyMargin(
            account,
            IMarginClearinghouse.MarginBucket.Position,
            IMarginClearinghouse.MarginBucket.LiquidationReserve,
            amountUsdc
        );
    }

    /// @notice Reclassifies liquidation reserve as PnL pledge; total locked settlement is unchanged.
    function reclassifyLiquidationReserveToPnlPledge(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _reclassifyMargin(
            account,
            IMarginClearinghouse.MarginBucket.LiquidationReserve,
            IMarginClearinghouse.MarginBucket.Position,
            amountUsdc
        );
    }

    /// @notice Applies a signed delta to an account's internal settlement balance.
    /// @dev Callable only by the engine or its reported settlement sidecar. Positive values credit and negative values
    ///      debit; zero is a no-op. This accounting mutation does not transfer tokens, alter locked buckets, or
    ///      checkpoint carry. A debit larger than free settlement reverts.
    /// @param account Account to settle
    /// @param amount Signed delta in six-decimal USDC units; positive credits and negative debits
    function settleUsdc(
        address account,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            _creditSettlementUsdc(account, uint256(amount));
        } else if (amount < 0) {
            _debitSettlementUsdc(account, uint256(-amount));
        }
    }

    /// @notice Credits internal settlement balance and locks the same amount as active-position margin.
    /// @dev Callable only by the engine or its reported settlement sidecar. This is an accounting-only mutation: no
    ///      tokens move and carry is not checkpointed. A zero amount is a no-op.
    /// @param account Account receiving the settlement credit and position margin lock
    /// @param amountUsdc Amount to credit and lock in six-decimal USDC units
    function creditSettlementAndLockMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _creditPnlPledge(account, amountUsdc);
    }

    /// @notice Credits settlement already transferred into custody and classifies it as PnL pledge.
    function creditPnlPledge(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _creditPnlPledge(account, amountUsdc);
    }

    function _creditPnlPledge(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        _creditSettlementUsdc(account, amountUsdc);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Applies an open/increase cost, updates position margin, and routes the collected settlement debit.
    /// @dev Callable only by the engine or its reported settlement sidecar. Positive `tradeCostUsdc` debits internal
    ///      settlement and transfers the non-fee portion to `recipient`; a negative value credits a rebate internally.
    ///      Any protocol fee is capped by the cash debit and credited internally to `protocolFeeAccount`, with no token
    ///      transfer for that portion. The function does not checkpoint carry.
    /// @param account Account whose settlement and position-margin bucket are mutated
    /// @param marginDeltaUsdc Margin supplied with the order, in six-decimal USDC units
    /// @param tradeCostUsdc Signed six-decimal USDC cost; positive is a debit and negative is a rebate
    /// @param recipient External recipient of the collected debit after any internal protocol-fee credit
    /// @param protocolFeeAccount Clearinghouse account credited with the protocol-fee portion; zero disables the credit
    /// @param protocolFeeUsdc Requested protocol-fee portion in six-decimal USDC units
    /// @return netMarginChangeUsdc Nonnegative new PnL pledge left after this action's positive cost, in USDC
    /// @return protocolFeeCreditedUsdc Amount of the debit credited internally to `protocolFeeAccount`
    function applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) external onlyOperator returns (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc) {
        return _applyOpenCost(account, marginDeltaUsdc, tradeCostUsdc, recipient, protocolFeeAccount, protocolFeeUsdc);
    }

    function _applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) internal returns (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc) {
        MarginClearinghouseAccountingLib.OpenCostPlan memory plan =
            MarginClearinghouseAccountingLib.planOpenCostApplication(
                _buildAccountUsdcBuckets(account), marginDeltaUsdc, tradeCostUsdc
            );

        if (plan.insufficientPositionMargin) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        if (plan.insufficientFreeEquity) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }

        netMarginChangeUsdc = plan.netMarginChangeUsdc;
        if (plan.settlementCreditUsdc > 0) {
            _creditSettlementUsdc(account, plan.settlementCreditUsdc);
        }

        if (plan.positionMarginUnlockedUsdc > 0) {
            _unlockMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedUsdc);
        }

        if (plan.positionMarginLockedUsdc > 0) {
            _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginLockedUsdc);
        }

        if (plan.settlementDebitUsdc > 0) {
            protocolFeeCreditedUsdc = _routeSettlementDebit(
                account, plan.settlementDebitUsdc, recipient, protocolFeeAccount, protocolFeeUsdc
            );
        }
    }

    /// @notice Collects a non-price settlement charge from free settlement only.
    /// @dev Callable only by the engine or its reported settlement sidecar. The unnamed second argument is the legacy
    ///      locked-position-margin hint, retained for ABI compatibility and ignored by this implementation; consumption
    ///      is planned from canonical stored buckets. PnL pledge and every reserve bucket remain protected, and any
    ///      uncovered amount is returned for the caller to waive.
    /// @param account Account paying the loss
    /// @param lossUsdc Loss to collect in six-decimal USDC units
    /// @param recipient External recipient of the settlement tokens collected
    /// @return marginConsumedUsdc Always zero under PnL-isolated accounting
    /// @return freeSettlementConsumedUsdc Free settlement consumed in six-decimal USDC units
    /// @return uncoveredUsdc Requested loss left uncovered in six-decimal USDC units
    function consumeSettlementLoss(
        address account,
        uint256,
        uint256 lossUsdc,
        address recipient
    )
        external
        onlyOperator
        returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc)
    {
        if (lossUsdc == 0) {
            return (0, 0, 0);
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            _planCarryLossConsumption(account, lossUsdc);
        freeSettlementConsumedUsdc = consumption.freeSettlementConsumedUsdc;
        marginConsumedUsdc = consumption.activeMarginConsumedUsdc;
        uncoveredUsdc = consumption.uncoveredUsdc;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildAccountUsdcBuckets(account);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyCarryLossMutation(buckets, consumption);

        if (mutation.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(
                account, IMarginClearinghouse.MarginBucket.Position, mutation.positionMarginUnlockedUsdc
            );
        }

        uint256 totalConsumedUsdc = mutation.settlementDebitUsdc;
        if (totalConsumedUsdc == 0) {
            return (marginConsumedUsdc, freeSettlementConsumedUsdc, uncoveredUsdc);
        }

        settlementBalances[account] -= totalConsumedUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, totalConsumedUsdc);
        emit AssetSeized(account, settlementAsset, totalConsumedUsdc, recipient);
    }

    /// @notice Collects position price loss from the dedicated PnL pledge and no other settlement source.
    function consumePnlPledgeLoss(
        address account,
        uint256 priceLossUsdc,
        address recipient
    ) external onlyOperator returns (uint256 consumedUsdc, uint256 shortfallUsdc) {
        return _consumePnlPledgeLoss(account, priceLossUsdc, 0, recipient);
    }

    function _consumePnlPledgeLoss(
        address account,
        uint256 priceLossUsdc,
        uint256 protectedPnlPledgeUsdc,
        address recipient
    ) internal returns (uint256 consumedUsdc, uint256 shortfallUsdc) {
        uint256 pledgeUsdc = positionMarginUsdc[account];
        uint256 consumablePledgeUsdc = pledgeUsdc > protectedPnlPledgeUsdc ? pledgeUsdc - protectedPnlPledgeUsdc : 0;
        consumedUsdc = priceLossUsdc < consumablePledgeUsdc ? priceLossUsdc : consumablePledgeUsdc;
        shortfallUsdc = priceLossUsdc - consumedUsdc;
        if (consumedUsdc == 0) {
            return (0, shortfallUsdc);
        }
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, consumedUsdc);
        settlementBalances[account] -= consumedUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, consumedUsdc);
        emit AssetSeized(account, settlementAsset, consumedUsdc, recipient);
    }

    /// @notice Legacy partial-close entrypoint that collects price loss from PnL pledge only.
    /// @dev The residual pledge is protected by `protectedLockedMarginUsdc`. The deprecated reservation and other-lock
    ///      arguments are ignored, and a nonzero protocol fee reverts because fees use the action-charge path.
    /// @param account Account paying the close loss
    /// @param reservationOrderIds Deprecated and ignored
    /// @param lossUsdc Maximum loss to collect in six-decimal USDC units
    /// @param protectedLockedMarginUsdc Position margin that must remain protected, in six-decimal USDC units
    /// @param includeOtherLockedMargin Deprecated and ignored
    /// @param recipient External recipient of collected price-loss cash
    /// @param protocolFeeAccount Deprecated and ignored
    /// @param protocolFeeUsdc Must be zero; action fees use `consumeActionCharge`
    /// @return seizedUsdc PnL pledge collected and transferred
    /// @return shortfallUsdc Requested loss left uncovered in six-decimal USDC units
    /// @return protocolFeeCreditedUsdc Always zero
    function consumeCloseLoss(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc) {
        return _consumeCloseLoss(
            account,
            reservationOrderIds,
            lossUsdc,
            protectedLockedMarginUsdc,
            includeOtherLockedMargin,
            recipient,
            protocolFeeAccount,
            protocolFeeUsdc
        );
    }

    function _consumeCloseLoss(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) internal returns (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc) {
        reservationOrderIds;
        includeOtherLockedMargin;
        protocolFeeAccount;
        if (protocolFeeUsdc != 0) {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
        (seizedUsdc, shortfallUsdc) = _consumePnlPledgeLoss(account, lossUsdc, protectedLockedMarginUsdc, recipient);
        protocolFeeCreditedUsdc = 0;
    }

    function _buildCloseLossBuckets(
        address account,
        bool includeOtherLockedMargin
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        uint256 reservedUsdc = reservedSettlementUsdc[account] + liquidationReserveBalances[account];
        uint256 settlementAvailableUsdc =
            settlementBalances[account] > reservedUsdc ? settlementBalances[account] - reservedUsdc : 0;

        if (includeOtherLockedMargin) {
            return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                settlementAvailableUsdc, positionMarginUsdc[account], committedOrderMarginUsdc[account], 0
            );
        }

        return MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
            settlementAvailableUsdc, positionMarginUsdc[account], committedOrderMarginUsdc[account], 0
        );
    }

    /// @notice Applies an engine-planned isolated full-liquidation settlement.
    /// @dev The pool transfer contains price PnL collected from pledge plus the LP fee collected from liquidation
    ///      reserve. Keeper and protocol allocations also consume liquidation reserve. Every other bucket is protected.
    /// @param account Liquidated account
    /// @param reservationOrderIds Active reservation ids allowed to cover committed-order margin consumption
    /// @param plan Liquidation settlement plan whose amounts use six-decimal USDC units
    /// @param recipient External recipient of `plan.settlementSeizedUsdc`; required when that amount is nonzero
    /// @param keeper Clearinghouse account credited with the bounty; required when the bounty is nonzero
    /// @param keeperBountyUsdc Bounty debited from `account` and credited to `keeper`, in six-decimal USDC units
    /// @param protocolFeeAccount Clearinghouse account credited with the liquidation protocol fee
    /// @param protocolFeeUsdc Protocol fee debited from `account` and credited internally, in six-decimal USDC units
    /// @param lpLiquidationFeeUsdc LP fee included in `plan.settlementSeizedUsdc`
    /// @return seizedUsdc Amount transferred to `recipient` in six-decimal USDC units
    function applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        address recipient,
        address keeper,
        uint256 keeperBountyUsdc,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc,
        uint256 lpLiquidationFeeUsdc
    ) external onlyOperator returns (uint256 seizedUsdc) {
        LiquidationSettlementExecution memory execution;
        execution.recipient = recipient;
        execution.keeper = keeper;
        execution.keeperBountyUsdc = keeperBountyUsdc;
        execution.protocolFeeAccount = protocolFeeAccount;
        execution.protocolFeeUsdc = protocolFeeUsdc;
        execution.lpLiquidationFeeUsdc = lpLiquidationFeeUsdc;
        return _applyLiquidationSettlementPlan(account, reservationOrderIds, plan, execution);
    }

    function _applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        LiquidationSettlementExecution memory execution
    ) internal returns (uint256 seizedUsdc) {
        seizedUsdc = plan.settlementSeizedUsdc;
        uint256 pledgeBeforeUsdc = positionMarginUsdc[account];
        if (seizedUsdc < execution.lpLiquidationFeeUsdc) {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
        uint256 priceSeizureUsdc = seizedUsdc - execution.lpLiquidationFeeUsdc;
        if (
            priceSeizureUsdc > pledgeBeforeUsdc || plan.positionMarginUnlockedUsdc != pledgeBeforeUsdc
                || plan.otherLockedMarginUnlockedUsdc != 0
        ) {
            revert MarginClearinghouse__InvalidMarginBucket();
        }

        uint256 liquidationChargeUsdc =
            execution.keeperBountyUsdc + execution.protocolFeeUsdc + execution.lpLiquidationFeeUsdc;
        if (liquidationReserveBalances[account] < liquidationChargeUsdc) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        if (liquidationChargeUsdc > 0) {
            liquidationReserveBalances[account] -= liquidationChargeUsdc;
            emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.LiquidationReserve, liquidationChargeUsdc);
        }

        if (plan.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedUsdc);
        }
        reservationOrderIds;

        uint256 settlementDebitUsdc = priceSeizureUsdc + liquidationChargeUsdc;
        if (settlementDebitUsdc > 0) {
            if (settlementBalances[account] < settlementDebitUsdc) {
                revert MarginClearinghouse__InsufficientAssetToSeize();
            }
            settlementBalances[account] -= settlementDebitUsdc;
            if (settlementBalances[account] < _totalLockedMarginUsdc(account)) {
                revert MarginClearinghouse__InsufficientAssetToSeize();
            }
        }
        if (seizedUsdc > 0) {
            if (execution.recipient == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            IERC20(settlementAsset).safeTransfer(execution.recipient, plan.settlementSeizedUsdc);
            emit AssetSeized(account, settlementAsset, plan.settlementSeizedUsdc, execution.recipient);
        }
        if (execution.keeperBountyUsdc > 0) {
            if (execution.keeper == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            settlementBalances[execution.keeper] += execution.keeperBountyUsdc;
            emit ReservedSettlementTransferred(account, execution.keeper, execution.keeperBountyUsdc);
        }
        if (execution.protocolFeeUsdc > 0) {
            if (execution.protocolFeeAccount == address(0)) {
                revert MarginClearinghouse__ZeroAddress();
            }
            settlementBalances[execution.protocolFeeAccount] += execution.protocolFeeUsdc;
            emit AssetSeized(account, settlementAsset, execution.protocolFeeUsdc, execution.protocolFeeAccount);
        }

        uint256 releasedLiquidationReserveUsdc = liquidationReserveBalances[account];
        if (releasedLiquidationReserveUsdc > 0) {
            liquidationReserveBalances[account] = 0;
            emit MarginUnlocked(
                account, IMarginClearinghouse.MarginBucket.LiquidationReserve, releasedLiquidationReserveUsdc
            );
        }
    }

    function _buildAccountUsdcBuckets(
        address account
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
            settlementBalances[account],
            positionMarginUsdc[account],
            liquidationReserveBalances[account],
            committedOrderMarginUsdc[account],
            reservedSettlementUsdc[account]
        );
    }

    function _planCarryLossConsumption(
        address account,
        uint256 lossUsdc
    ) internal view returns (MarginClearinghouseAccountingLib.SettlementConsumption memory consumption) {
        return MarginClearinghouseAccountingLib.planCarryLossConsumption(_buildAccountUsdcBuckets(account), lossUsdc);
    }

    function _routeSettlementDebit(
        address account,
        uint256 amountUsdc,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) internal returns (uint256 protocolFeeCreditedUsdc) {
        settlementBalances[account] -= amountUsdc;

        if (protocolFeeAccount != address(0) && protocolFeeUsdc > 0) {
            protocolFeeCreditedUsdc = protocolFeeUsdc < amountUsdc ? protocolFeeUsdc : amountUsdc;
            settlementBalances[protocolFeeAccount] += protocolFeeCreditedUsdc;
            emit AssetSeized(account, settlementAsset, protocolFeeCreditedUsdc, protocolFeeAccount);
        }

        uint256 recipientTransferUsdc = amountUsdc - protocolFeeCreditedUsdc;
        if (recipientTransferUsdc > 0) {
            IERC20(settlementAsset).safeTransfer(recipient, recipientTransferUsdc);
            emit AssetSeized(account, settlementAsset, recipientTransferUsdc, recipient);
        }
    }

    function _creditSettlementUsdc(
        address account,
        uint256 amountUsdc
    ) internal {
        settlementBalances[account] += amountUsdc;
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

    function _requireNoActiveReservations(
        address account
    ) internal view {
        if (activeReservationCount[account] != 0) {
            revert MarginClearinghouse__ReservationLedgerActive();
        }
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

    function _debitSettlementUsdc(
        address account,
        uint256 amountUsdc
    ) internal {
        if (settlementBalances[account] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        if (getFreeBuyingPowerUsdc(account) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        settlementBalances[account] -= amountUsdc;
    }

    function _lockMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (getFreeBuyingPowerUsdc(account) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        _setBucketStorage(bucket, account, _bucketStorage(bucket, account) + amountUsdc);
        emit MarginLocked(account, bucket, amountUsdc);
    }

    function _unlockMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        _consumeLockedMargin(account, bucket, amountUsdc);
    }

    function _reclassifyMargin(
        address account,
        IMarginClearinghouse.MarginBucket from,
        IMarginClearinghouse.MarginBucket to,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }
        _consumeLockedMargin(account, from, amountUsdc);
        _setBucketStorage(to, account, _bucketStorage(to, account) + amountUsdc);
        emit MarginLocked(account, to, amountUsdc);
    }

    /// @dev Consumes non-position locked margin by priority: committed-order margin first, then reserved settlement.
    ///      Queued order margin is released before reserved settlement because failed/cancelled order intents are softer
    ///      obligations than explicitly reserved settlement buckets.
    function _consumeOtherLockedMargin(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        uint256 committedConsumedUsdc =
            amountUsdc > committedOrderMarginUsdc[account] ? committedOrderMarginUsdc[account] : amountUsdc;
        if (committedConsumedUsdc > 0) {
            committedOrderMarginUsdc[account] -= committedConsumedUsdc;
            emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.CommittedOrder, committedConsumedUsdc);
        }

        uint256 remainingUsdc = amountUsdc - committedConsumedUsdc;
        if (remainingUsdc > 0) {
            _requireActionReserveDecreaseAboveProtectedFloor(account, remainingUsdc);
            if (reservedSettlementUsdc[account] < remainingUsdc) {
                revert MarginClearinghouse__InsufficientBucketMargin();
            }
            reservedSettlementUsdc[account] -= remainingUsdc;
            emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, remainingUsdc);
        }
    }

    function _consumeOtherLockedMarginViaReservations(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 amountUsdc
    ) internal {
        uint256 consumedReservationUsdc = _consumeOrderReservationsById(reservationOrderIds, amountUsdc);
        account;
        if (consumedReservationUsdc != amountUsdc) {
            revert MarginClearinghouse__IncompleteReservationCoverage();
        }
    }

    function _consumeReservationBucket(
        address account,
        IMarginClearinghouse.ReservationBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (bucket == IMarginClearinghouse.ReservationBucket.CommittedOrder) {
            _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _activeReservation(
        uint64 orderId
    ) internal view returns (IMarginClearinghouse.OrderReservation storage reservation) {
        reservation = orderReservations[orderId];
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            revert MarginClearinghouse__ReservationNotActive();
        }
    }

    function _closeReservation(
        IMarginClearinghouse.OrderReservation storage reservation,
        IMarginClearinghouse.ReservationStatus terminalStatus
    ) internal {
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            revert MarginClearinghouse__ReservationNotActive();
        }
        reservation.status = terminalStatus;
        reservation.remainingAmountUsdc = 0;
        activeReservationCount[reservation.account] -= 1;
    }

    /// @dev The router already maintains the active reservation FIFO for each account, so the
    ///      clearinghouse no longer needs an append-only historical reservation index.
    function _activeMarginReservationIds(
        address account
    ) internal view returns (uint64[] memory reservationIds) {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return new uint64[](0);
        }

        return IOrderRouterAccounting(ICfdEngineCore(engine_).orderRouter()).getMarginReservationIds(account);
    }

    /// @dev Returns the aggregate unpaid execution bounty that must remain in the shared action-reserve bucket.
    function _activeExecutionBountyUsdc(
        address account
    ) internal view returns (uint256) {
        address engine_ = engine;
        if (engine_ == address(0)) {
            revert MarginClearinghouse__NotOperator();
        }

        address router = ICfdEngineCore(engine_).orderRouter();
        if (router == address(0)) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
        return IOrderRouterAccounting(router).getAccountReservations(account).executionBountyUsdc;
    }

    /// @dev Reverts if a generic action-reserve decrease would consume negative-VPI backing or a queued bounty.
    function _requireActionReserveDecreaseAboveProtectedFloor(
        address account,
        uint256 amountUsdc
    ) internal view {
        uint256 currentReserveUsdc = reservedSettlementUsdc[account];
        if (amountUsdc > currentReserveUsdc) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        uint256 protectedFloorUsdc = vpiRebateReserveBalances[account] + _activeExecutionBountyUsdc(account);
        if (currentReserveUsdc - amountUsdc < protectedFloorUsdc) {
            revert MarginClearinghouse__ActionReserveMismatch();
        }
    }

    function _consumeLockedMargin(
        address account,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }
        uint256 currentBucket = _bucketStorage(bucket, account);
        if (currentBucket < amountUsdc) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        _setBucketStorage(bucket, account, currentBucket - amountUsdc);
        emit MarginUnlocked(account, bucket, amountUsdc);
    }

    function _reservePositionMarginAsSettlement(
        address account,
        uint256 amountUsdc
    ) internal {
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
        reservedSettlementUsdc[account] += amountUsdc;
        emit MarginLocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    function _bucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        address account
    ) internal view returns (uint256 bucketValue) {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            return positionMarginUsdc[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            return committedOrderMarginUsdc[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            return reservedSettlementUsdc[account];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.LiquidationReserve) {
            return liquidationReserveBalances[account];
        }
        revert MarginClearinghouse__InvalidMarginBucket();
    }

    function _setBucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        address account,
        uint256 amountUsdc
    ) internal {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            positionMarginUsdc[account] = amountUsdc;
        } else if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            committedOrderMarginUsdc[account] = amountUsdc;
        } else if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            reservedSettlementUsdc[account] = amountUsdc;
        } else if (bucket == IMarginClearinghouse.MarginBucket.LiquidationReserve) {
            liquidationReserveBalances[account] = amountUsdc;
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _totalLockedMarginUsdc(
        address account
    ) internal view returns (uint256) {
        return positionMarginUsdc[account] + liquidationReserveBalances[account] + committedOrderMarginUsdc[account]
            + reservedSettlementUsdc[account];
    }

    /// @notice Locks free settlement as reserved settlement for the engine's fresh close-execution bounty path.
    /// @dev Callable only by the configured engine or its currently reported settlement sidecar after the engine has
    ///      checkpointed carry in its active accounting mutation. This hook deliberately does not call back into the
    ///      engine. The settlement balance is unchanged, and insufficient free settlement reverts.
    /// @param account Account whose free settlement should be reserved
    /// @param amount Amount to reserve in six-decimal USDC units
    function reserveCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external onlyOperator {
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amount);
    }

    /// @notice Locks free settlement as reserved settlement for the engine's stale close-execution bounty path.
    /// @dev Callable only by the configured engine or its currently reported settlement sidecar. This bounded stale
    ///      path deliberately does not checkpoint carry. The settlement balance is unchanged, and insufficient free
    ///      settlement reverts.
    /// @param account Account whose free settlement should be reserved
    /// @param amount Amount to reserve in six-decimal USDC units
    function reserveStaleCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external onlyOperator {
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amount);
    }

    /// @notice Moves already-reserved settlement value between two internal clearinghouse accounts.
    /// @dev Callable only by the configured engine. Decreases the source's reserved bucket and settlement balance, then
    ///      credits the recipient's settlement balance; no ERC-20 transfer occurs. The recipient must be nonzero even
    ///      when `amount` is zero; zero otherwise is a no-op. A nonzero transfer requires sufficient source reserved
    ///      margin and settlement balance.
    /// @param account Source account whose reserved settlement and balance are debited
    /// @param recipient Destination account receiving an internal settlement credit
    /// @param amount Amount to move in six-decimal USDC units
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
        if (reservedSettlementUsdc[account] < amount || settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        _requireActionReserveDecreaseAboveProtectedFloor(account, amount);

        reservedSettlementUsdc[account] -= amount;
        settlementBalances[account] -= amount;
        settlementBalances[recipient] += amount;

        emit MarginUnlocked(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amount);
        emit ReservedSettlementTransferred(account, recipient, amount);
    }

    /// @notice Retired fresh position-margin close-bounty selector; every authorized call reverts.
    /// @dev V2 close bounties are backed exclusively by free settlement so PnL pledge remains isolated.
    function reserveCloseExecutionBountyFromPositionMargin(
        address,
        uint256
    ) external view onlyEngine {
        revert MarginClearinghouse__InvalidMarginBucket();
    }

    /// @notice Retired stale position-margin close-bounty selector; every authorized call reverts.
    /// @dev Stale V2 close bounties are also backed exclusively by free settlement so PnL pledge remains isolated.
    function reserveStaleCloseExecutionBountyFromPositionMargin(
        address,
        uint256
    ) external view onlyEngine {
        revert MarginClearinghouse__InvalidMarginBucket();
    }

    /// @notice Returns an account's internal settlement USDC balance.
    /// @dev Does not include unrealized PnL or apply engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Account balance in six-decimal USDC units
    function balanceUsdc(
        address account
    ) external view returns (uint256) {
        return settlementBalances[account];
    }

    /// @notice Returns the total locked USDC margin across all buckets for an account.
    /// @param account Account to inspect
    /// @return Sum of position, committed-order, and reserved-settlement margin in six-decimal USDC units
    function lockedMarginUsdc(
        address account
    ) external view returns (uint256) {
        return _totalLockedMarginUsdc(account);
    }

    /// @notice Returns the typed locked-margin buckets for an account.
    /// @dev Every field uses six-decimal USDC units.
    /// @param account Account to inspect
    /// @return buckets Position, committed-order, reserved-settlement, and total locked amounts
    function getLockedMarginBuckets(
        address account
    ) external view returns (IMarginClearinghouse.LockedMarginBuckets memory buckets) {
        buckets.positionMarginUsdc = positionMarginUsdc[account];
        buckets.committedOrderMarginUsdc = committedOrderMarginUsdc[account];
        buckets.reservedSettlementUsdc = reservedSettlementUsdc[account];
        buckets.totalLockedMarginUsdc = _totalLockedMarginUsdc(account);
    }

    /// @notice Returns the reservation record for a specific order id.
    /// @dev Amount fields use six-decimal USDC units but are stored as `uint96`. An unused id returns the default record.
    /// @param orderId Order reservation id to inspect
    /// @return reservation Account, bucket, status, original amount, and remaining amount
    function getOrderReservation(
        uint64 orderId
    ) external view returns (IMarginClearinghouse.OrderReservation memory reservation) {
        return orderReservations[orderId];
    }

    /// @notice Returns the aggregate active reservation summary for an account.
    /// @dev The margin amount uses six-decimal USDC units and equals the sum of active reservation remainders.
    /// @param account Account to inspect
    /// @return summary Aggregate remaining committed-order margin and number of active reservations
    function getAccountReservationSummary(
        address account
    ) external view returns (IMarginClearinghouse.AccountReservationSummary memory summary) {
        summary.activeCommittedOrderMarginUsdc = activeCommittedOrderReservationUsdc[account];
        summary.activeReservationCount = activeReservationCount[account];
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
