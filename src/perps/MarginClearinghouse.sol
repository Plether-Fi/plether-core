// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title MarginClearinghouse
/// @notice USDC-only cross-margin account manager for Plether.
/// @dev Holds settlement balances and locked margin for CFD accounts.
/// @custom:security-contact contact@plether.com
contract MarginClearinghouse is IMarginAccount, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    bytes4 internal constant MARK_PRICE_STALE_SELECTOR = bytes4(keccak256("CfdEngine__MarkPriceStale()"));

    struct AccountClaimBalances {
        uint256 traderClaimBalanceUsdc;
        uint256 keeperClaimBalanceUsdc;
    }

    mapping(address => uint256) internal settlementBalances;
    mapping(address => AccountClaimBalances) internal claimBalances;
    uint256 internal totalTraderClaimBalance;
    uint256 internal totalKeeperClaimBalance;

    mapping(address => uint256) internal positionMarginUsdc;
    mapping(address => uint256) internal committedOrderMarginUsdc;
    mapping(address => uint256) internal reservedSettlementUsdc;
    mapping(uint64 => IMarginClearinghouse.OrderReservation) internal orderReservations;
    mapping(address => uint256) internal activeCommittedOrderReservationUsdc;
    mapping(address => uint256) internal activeReservationCount;

    address public immutable settlementAsset;
    address public engine;

    error MarginClearinghouse__NotOperator();
    error MarginClearinghouse__NotAccountOwner();
    error MarginClearinghouse__ZeroAmount();
    error MarginClearinghouse__InsufficientBalance();
    error MarginClearinghouse__InsufficientFreeEquity();
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    error MarginClearinghouse__InsufficientAssetToSeize();
    error MarginClearinghouse__InvalidSeizeRecipient();
    error MarginClearinghouse__InvalidMarginBucket();
    error MarginClearinghouse__ReservationAlreadyExists();
    error MarginClearinghouse__ReservationNotActive();
    error MarginClearinghouse__IncompleteReservationCoverage();
    error MarginClearinghouse__ReservationLedgerActive();
    error MarginClearinghouse__EngineAlreadySet();
    error MarginClearinghouse__ZeroAddress();
    error MarginClearinghouse__InsufficientBucketMargin();
    error MarginClearinghouse__AmountOverflow();
    error MarginClearinghouse__InsufficientClaimBalance();

    event Deposit(address indexed account, address indexed asset, uint256 amount);
    event Withdraw(address indexed account, address indexed asset, uint256 amount);
    event MarginLocked(address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc);
    event MarginUnlocked(address indexed account, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc);
    event ClaimCredited(address indexed account, IMarginClearinghouse.ClaimKind indexed kind, uint256 amountUsdc);
    event ClaimReleasedToSettlement(
        address indexed account, IMarginClearinghouse.ClaimKind indexed kind, uint256 amountUsdc
    );
    event ClaimConsumed(address indexed account, IMarginClearinghouse.ClaimKind indexed kind, uint256 amountUsdc);
    event ReservationCreated(
        uint64 indexed orderId,
        address indexed account,
        IMarginClearinghouse.ReservationBucket indexed bucket,
        uint256 amountUsdc
    );
    event ReservationConsumed(
        uint64 indexed orderId, address indexed account, uint256 amountUsdc, uint256 remainingAmountUsdc
    );
    event ReservationReleased(uint64 indexed orderId, address indexed account, uint256 amountUsdc);
    event AssetSeized(address indexed account, address indexed asset, uint256 amount, address recipient);

    modifier onlyOperator() {
        address engine_ = engine;
        if (engine_ == address(0)) {
            revert MarginClearinghouse__NotOperator();
        }
        if (
            msg.sender != engine_ && msg.sender != ICfdEngineCore(engine_).orderRouter()
                && msg.sender != ICfdEngineCore(engine_).settlementModule()
        ) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    modifier onlyOrderRouter() {
        address engine_ = engine;
        if (engine_ == address(0) || msg.sender != ICfdEngineCore(engine_).orderRouter()) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    modifier onlyEngine() {
        address engine_ = engine;
        if (engine_ == address(0) || msg.sender != engine_) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @param _settlementAsset USDC address used for PnL settlement and margin backing
    constructor(
        address _settlementAsset
    ) Ownable(msg.sender) {
        settlementAsset = _settlementAsset;
    }

    /// @notice Sets the CfdEngine address (one-time, reverts if already set).
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

    /// @notice Deposits settlement USDC into the specified margin account.
    /// @param account Deterministic account ID derived from msg.sender address
    /// @param amount Token amount to transfer in
    function deposit(
        address account,
        uint256 amount
    ) external {
        _deposit(account, msg.sender, amount);
    }

    /// @notice Trader-facing wrapper that deposits into the caller's canonical account id.
    function depositMargin(
        uint256 amount
    ) external nonReentrant {
        _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Withdraws settlement USDC from a margin account.
    /// @param account Deterministic account ID derived from msg.sender address
    /// @param amount USDC amount to withdraw
    function withdraw(
        address account,
        uint256 amount
    ) external nonReentrant {
        _withdraw(account, msg.sender, amount);
    }

    /// @notice Trader-facing wrapper that withdraws from the caller's canonical account id.
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

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(account));

        IERC20(settlementAsset).safeTransferFrom(owner, address(this), amount);

        settlementBalances[account] += amount;

        _realizeOrCheckpointCarryBeforeMarginChange(account, reachableCollateralBasisUsdc);

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

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(account));

        _checkpointCarryBeforeMarginChange(account, reachableCollateralBasisUsdc);

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

    /// @notice Returns the total USD buying power of the account (6 decimals).
    /// @param account Account to value
    /// @return totalEquityUsdc Settlement balance in USDC (6 decimals)
    function getAccountEquityUsdc(
        address account
    ) public view override returns (uint256 totalEquityUsdc) {
        return settlementBalances[account];
    }

    /// @notice Returns strictly unencumbered purchasing power
    /// @param account Account to query
    /// @return Equity minus locked margin, floored at zero (6 decimals)
    function getFreeBuyingPowerUsdc(
        address account
    ) public view override returns (uint256) {
        uint256 equity = getAccountEquityUsdc(account);
        uint256 encumbered = _totalLockedMarginUsdc(account);
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns the explicit USDC bucket split after subtracting the clearinghouse's typed locked-margin buckets.
    function getAccountUsdcBuckets(
        address account
    ) public view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = _buildAccountUsdcBuckets(account);
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Locks margin to back a new CFD trade.
    ///         Requires sufficient USDC to back settlement (non-USDC equity alone is insufficient).
    /// @param account Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Unlocks active position margin when a CFD trade closes
    /// @param account Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals), clamped to current locked amount
    function unlockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Locks margin to back a pending order commitment.
    /// @param account Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _requireNoActiveReservations(account);
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountUsdc
    ) external onlyOperator {
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

    /// @notice Unlocks committed order margin when an order is cancelled or filled.
    /// @param account Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals)
    function unlockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _requireNoActiveReservations(account);
        _checkpointCarryBeforeMarginChange(account);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    function releaseOrderReservation(
        uint64 orderId
    ) external onlyOperator returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = _activeReservation(orderId);
        _checkpointCarryBeforeMarginChange(reservation.account);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.account, releasedUsdc);
    }

    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external onlyOperator returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderId];
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            return 0;
        }

        _checkpointCarryBeforeMarginChange(reservation.account);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.account, releasedUsdc);
    }

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

    function consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc
    ) external onlyOperator returns (uint256 consumedUsdc) {
        return _consumeAccountOrderReservations(account, amountUsdc, true);
    }

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

    function lockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(account);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    function unlockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(account);
        _unlockMargin(account, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Adjusts settlement USDC for realized PnL, claim servicing, and rebates.
    ///         Positive amounts credit the account; negative amounts debit it.
    /// @param account Account to settle
    /// @param amount Signed USDC delta: positive credits, negative debits (6 decimals)
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

    /// @notice Records a non-spendable claim owed to an account.
    function creditClaim(
        address account,
        IMarginClearinghouse.ClaimKind kind,
        uint256 amountUsdc
    ) external onlyEngine {
        _creditClaim(account, kind, amountUsdc);
    }

    /// @notice Moves a serviced non-spendable claim into spendable settlement balance.
    function releaseClaimToSettlement(
        address account,
        IMarginClearinghouse.ClaimKind kind,
        uint256 amountUsdc
    ) external onlyEngine {
        _consumeClaim(account, kind, amountUsdc);
        _creditSettlementUsdc(account, amountUsdc);
        emit ClaimReleasedToSettlement(account, kind, amountUsdc);
    }

    /// @notice Consumes a non-spendable claim without crediting settlement.
    function consumeClaim(
        address account,
        IMarginClearinghouse.ClaimKind kind,
        uint256 amountUsdc
    ) external onlyEngine {
        _consumeClaim(account, kind, amountUsdc);
        emit ClaimConsumed(account, kind, amountUsdc);
    }

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        address account,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }

        _creditSettlementUsdc(account, amountUsdc);
        _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external onlyOperator returns (int256 netMarginChangeUsdc) {
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

        if (plan.settlementDebitUsdc > 0) {
            settlementBalances[account] -= plan.settlementDebitUsdc;
        }

        if (plan.positionMarginLockedUsdc > 0) {
            _lockMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginLockedUsdc);
        }

        if (plan.settlementDebitUsdc > 0) {
            IERC20(settlementAsset).safeTransfer(recipient, plan.settlementDebitUsdc);
            emit AssetSeized(account, settlementAsset, plan.settlementDebitUsdc, recipient);
        }
    }

    /// @notice Consumes a realized settlement loss from free settlement first, then from active position margin.
    /// @dev Unrelated locked margin remains protected.
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

    /// @notice Consumes close-path losses from settlement buckets while preserving any explicitly protected remaining position margin.
    function consumeCloseLoss(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 shortfallUsdc) {
        if (lossUsdc == 0) {
            return (0, 0);
        }

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = includeOtherLockedMargin
            ? MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                settlementBalances[account],
                positionMarginUsdc[account],
                committedOrderMarginUsdc[account],
                reservedSettlementUsdc[account]
            )
            : MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
                settlementBalances[account],
                positionMarginUsdc[account],
                committedOrderMarginUsdc[account],
                reservedSettlementUsdc[account]
            );
        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, protectedLockedMarginUsdc, lossUsdc);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, protectedLockedMarginUsdc, consumption);
        seizedUsdc = consumption.totalConsumedUsdc;
        shortfallUsdc = consumption.uncoveredUsdc;

        if (seizedUsdc == 0) {
            return (0, shortfallUsdc);
        }

        if (mutation.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(
                account, IMarginClearinghouse.MarginBucket.Position, mutation.positionMarginUnlockedUsdc
            );
        }
        if (includeOtherLockedMargin && mutation.otherLockedMarginUnlockedUsdc > 0) {
            _consumeOtherLockedMarginViaReservations(
                account, reservationOrderIds, mutation.otherLockedMarginUnlockedUsdc
            );
        }

        settlementBalances[account] -= mutation.settlementDebitUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, mutation.settlementDebitUsdc);
        emit AssetSeized(account, settlementAsset, mutation.settlementDebitUsdc, recipient);
    }

    /// @notice Applies a pre-planned liquidation settlement mutation.
    /// @dev Releases the active position margin bucket and covered committed margin exactly as planned.
    function applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc) {
        seizedUsdc = plan.settlementSeizedUsdc;

        if (plan.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedUsdc);
        }
        if (plan.otherLockedMarginUnlockedUsdc > 0) {
            _consumeOtherLockedMarginViaReservations(account, reservationOrderIds, plan.otherLockedMarginUnlockedUsdc);
        }

        if (seizedUsdc > 0) {
            settlementBalances[account] -= plan.settlementSeizedUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, plan.settlementSeizedUsdc);
            emit AssetSeized(account, settlementAsset, plan.settlementSeizedUsdc, recipient);
        }
    }

    function _buildAccountUsdcBuckets(
        address account
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalances[account],
            positionMarginUsdc[account],
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

    function _creditSettlementUsdc(
        address account,
        uint256 amountUsdc
    ) internal {
        settlementBalances[account] += amountUsdc;
    }

    function _creditClaim(
        address account,
        IMarginClearinghouse.ClaimKind kind,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        AccountClaimBalances storage balances = claimBalances[account];
        if (kind == IMarginClearinghouse.ClaimKind.Trader) {
            balances.traderClaimBalanceUsdc += amountUsdc;
            totalTraderClaimBalance += amountUsdc;
        } else {
            balances.keeperClaimBalanceUsdc += amountUsdc;
            totalKeeperClaimBalance += amountUsdc;
        }

        emit ClaimCredited(account, kind, amountUsdc);
    }

    function _checkpointCarryBeforeMarginChange(
        address account
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(account));
        _checkpointCarryBeforeMarginChange(account, reachableCollateralBasisUsdc);
    }

    function _checkpointCarryBeforeMarginChange(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        _realizeOrCheckpointCarryBeforeMarginChange(account, reachableCollateralBasisUsdc);
    }

    function _requireNoActiveReservations(
        address account
    ) internal view {
        if (activeReservationCount[account] != 0) {
            revert MarginClearinghouse__ReservationLedgerActive();
        }
    }

    function _realizeOrCheckpointCarryBeforeMarginChange(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        try ICfdEngineCore(engine_).realizeCarryBeforeMarginChange(account, reachableCollateralBasisUsdc) {}
        catch (bytes memory revertData) {
            if (revertData.length < 4 || bytes4(revertData) != MARK_PRICE_STALE_SELECTOR) {
                assembly {
                    revert(add(revertData, 32), mload(revertData))
                }
            }

            ICfdEngineCore(engine_).checkpointCarryUsingStoredMark(account, reachableCollateralBasisUsdc);
        }
    }

    function _debitSettlementUsdc(
        address account,
        uint256 amountUsdc
    ) internal {
        if (settlementBalances[account] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        settlementBalances[account] -= amountUsdc;
    }

    function _consumeClaim(
        address account,
        IMarginClearinghouse.ClaimKind kind,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        AccountClaimBalances storage balances = claimBalances[account];
        if (kind == IMarginClearinghouse.ClaimKind.Trader) {
            if (balances.traderClaimBalanceUsdc < amountUsdc) {
                revert MarginClearinghouse__InsufficientClaimBalance();
            }
            balances.traderClaimBalanceUsdc -= amountUsdc;
            totalTraderClaimBalance -= amountUsdc;
        } else {
            if (balances.keeperClaimBalanceUsdc < amountUsdc) {
                revert MarginClearinghouse__InsufficientClaimBalance();
            }
            balances.keeperClaimBalanceUsdc -= amountUsdc;
            totalKeeperClaimBalance -= amountUsdc;
        }
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
        uint256 residualOtherLockedUsdc = amountUsdc - consumedReservationUsdc;
        if (residualOtherLockedUsdc > 0) {
            if (committedOrderMarginUsdc[account] > 0) {
                revert MarginClearinghouse__IncompleteReservationCoverage();
            }
            _consumeOtherLockedMargin(account, residualOtherLockedUsdc);
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
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _totalLockedMarginUsdc(
        address account
    ) internal view returns (uint256) {
        return positionMarginUsdc[account] + committedOrderMarginUsdc[account] + reservedSettlementUsdc[account];
    }

    /// @notice Transfers settlement USDC from an account to the calling operator.
    /// @dev The recipient must equal msg.sender, so operators can only pull seized funds
    ///      into their own contract/account and must forward them explicitly afterward.
    /// @param account Account to seize from
    /// @param amount USDC amount to seize
    /// @param recipient Recipient of seized tokens (must equal msg.sender)
    function seizeUsdc(
        address account,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (recipient != msg.sender) {
            revert MarginClearinghouse__InvalidSeizeRecipient();
        }
        _checkpointCarryBeforeMarginChange(account);
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > _buildAccountUsdcBuckets(account).freeSettlementUsdc) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        settlementBalances[account] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(account, settlementAsset, amount, recipient);
    }

    /// @notice Reserves free settlement for the engine's fresh close-bounty path with carry checkpointing.
    function reserveCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount,
        address recipient
    ) external onlyEngine {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        _checkpointCarryBeforeMarginChange(account);
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > _buildAccountUsdcBuckets(account).freeSettlementUsdc) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        settlementBalances[account] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(account, settlementAsset, amount, recipient);
    }

    /// @notice Reserves free settlement for the engine's stale close-bounty path without checkpointing carry.
    function reserveStaleCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount,
        address recipient
    ) external onlyEngine {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > _buildAccountUsdcBuckets(account).freeSettlementUsdc) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        settlementBalances[account] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(account, settlementAsset, amount, recipient);
    }

    function seizePositionMarginUsdc(
        address account,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (amount == 0) {
            return;
        }
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        _checkpointCarryBeforeMarginChange(account);
        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, amount);
        settlementBalances[account] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(account, settlementAsset, amount, recipient);
    }

    /// @notice Reserves active position margin for the engine's stale close-bounty path without checkpointing carry.
    function reserveStaleCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount,
        address recipient
    ) external onlyEngine {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (amount == 0) {
            return;
        }
        if (settlementBalances[account] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        _consumeLockedMargin(account, IMarginClearinghouse.MarginBucket.Position, amount);
        settlementBalances[account] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(account, settlementAsset, amount, recipient);
    }

    function balanceUsdc(
        address account
    ) external view returns (uint256) {
        return settlementBalances[account];
    }

    function claimBalanceUsdc(
        address account
    ) external view returns (uint256) {
        AccountClaimBalances storage balances = claimBalances[account];
        return balances.traderClaimBalanceUsdc + balances.keeperClaimBalanceUsdc;
    }

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256) {
        return claimBalances[account].traderClaimBalanceUsdc;
    }

    function keeperClaimBalanceUsdc(
        address account
    ) external view returns (uint256) {
        return claimBalances[account].keeperClaimBalanceUsdc;
    }

    function totalClaimBalanceUsdc() external view returns (uint256) {
        return totalTraderClaimBalance + totalKeeperClaimBalance;
    }

    function totalTraderClaimBalanceUsdc() external view returns (uint256) {
        return totalTraderClaimBalance;
    }

    function totalKeeperClaimBalanceUsdc() external view returns (uint256) {
        return totalKeeperClaimBalance;
    }

    function getClaimBalances(
        address account
    ) external view returns (IMarginClearinghouse.ClaimBalances memory balances) {
        AccountClaimBalances storage accountBalances = claimBalances[account];
        balances.traderClaimBalanceUsdc = accountBalances.traderClaimBalanceUsdc;
        balances.keeperClaimBalanceUsdc = accountBalances.keeperClaimBalanceUsdc;
        balances.totalClaimBalanceUsdc = accountBalances.traderClaimBalanceUsdc + accountBalances.keeperClaimBalanceUsdc;
    }

    function lockedMarginUsdc(
        address account
    ) external view returns (uint256) {
        return _totalLockedMarginUsdc(account);
    }

    function getLockedMarginBuckets(
        address account
    ) external view returns (IMarginClearinghouse.LockedMarginBuckets memory buckets) {
        buckets.positionMarginUsdc = positionMarginUsdc[account];
        buckets.committedOrderMarginUsdc = committedOrderMarginUsdc[account];
        buckets.reservedSettlementUsdc = reservedSettlementUsdc[account];
        buckets.totalLockedMarginUsdc = _totalLockedMarginUsdc(account);
    }

    function getOrderReservation(
        uint64 orderId
    ) external view returns (IMarginClearinghouse.OrderReservation memory reservation) {
        return orderReservations[orderId];
    }

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
