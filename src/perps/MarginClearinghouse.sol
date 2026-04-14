// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
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

    mapping(bytes32 => uint256) internal settlementBalances;

    mapping(bytes32 => uint256) internal positionMarginUsdc;
    mapping(bytes32 => uint256) internal committedOrderMarginUsdc;
    mapping(bytes32 => uint256) internal reservedSettlementUsdc;
    mapping(uint64 => IMarginClearinghouse.OrderReservation) internal orderReservations;
    mapping(bytes32 => uint64[]) internal reservationIdsByAccount;
    mapping(bytes32 => uint256) internal reservationHeadIndexByAccount;
    mapping(bytes32 => uint256) internal activeCommittedOrderReservationUsdc;
    mapping(bytes32 => uint256) internal activeReservedSettlementReservationUsdc;
    mapping(bytes32 => uint256) internal activeReservationCount;

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
    error MarginClearinghouse__EngineAlreadySet();
    error MarginClearinghouse__ZeroAddress();
    error MarginClearinghouse__InsufficientBucketMargin();
    error MarginClearinghouse__AmountOverflow();

    event Deposit(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event MarginLocked(bytes32 indexed accountId, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc);
    event MarginUnlocked(
        bytes32 indexed accountId, IMarginClearinghouse.MarginBucket indexed bucket, uint256 amountUsdc
    );
    event ReservationCreated(
        uint64 indexed orderId,
        bytes32 indexed accountId,
        IMarginClearinghouse.ReservationBucket indexed bucket,
        uint256 amountUsdc
    );
    event ReservationConsumed(
        uint64 indexed orderId, bytes32 indexed accountId, uint256 amountUsdc, uint256 remainingAmountUsdc
    );
    event ReservationReleased(uint64 indexed orderId, bytes32 indexed accountId, uint256 amountUsdc);
    event AssetSeized(bytes32 indexed accountId, address indexed asset, uint256 amount, address recipient);

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
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param amount Token amount to transfer in
    function deposit(
        bytes32 accountId,
        uint256 amount
    ) external {
        _deposit(accountId, msg.sender, amount);
    }

    /// @notice Trader-facing wrapper that deposits into the caller's canonical account id.
    function depositMargin(
        uint256 amount
    ) external nonReentrant {
        _deposit(bytes32(uint256(uint160(msg.sender))), msg.sender, amount);
    }

    /// @notice Withdraws settlement USDC from a margin account.
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param amount USDC amount to withdraw
    function withdraw(
        bytes32 accountId,
        uint256 amount
    ) external nonReentrant {
        _withdraw(accountId, msg.sender, amount);
    }

    /// @notice Trader-facing wrapper that withdraws from the caller's canonical account id.
    function withdrawMargin(
        uint256 amount
    ) external nonReentrant {
        _withdraw(bytes32(uint256(uint160(msg.sender))), msg.sender, amount);
    }

    function _deposit(
        bytes32 accountId,
        address owner,
        uint256 amount
    ) internal {
        if (bytes32(uint256(uint160(owner))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (amount == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(accountId));

        IERC20(settlementAsset).safeTransferFrom(owner, address(this), amount);

        settlementBalances[accountId] += amount;

        _checkpointCarryBeforeMarginChange(accountId, reachableCollateralBasisUsdc);

        emit Deposit(accountId, settlementAsset, amount);
    }

    function _withdraw(
        bytes32 accountId,
        address owner,
        uint256 amount
    ) internal {
        if (bytes32(uint256(uint160(owner))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(accountId));

        _checkpointCarryBeforeMarginChange(accountId, reachableCollateralBasisUsdc);

        address engine_ = engine;

        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        settlementBalances[accountId] -= amount;

        if (engine_ != address(0)) {
            IWithdrawGuard(engine_).checkWithdraw(accountId);
        }

        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        uint256 totalLockedMargin = _totalLockedMarginUsdc(accountId);
        if (remainingEquity < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[accountId] < totalLockedMargin) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }

        IERC20(settlementAsset).safeTransfer(owner, amount);
        emit Withdraw(accountId, settlementAsset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns the total USD buying power of the account (6 decimals).
    /// @param accountId Account to value
    /// @return totalEquityUsdc Settlement balance in USDC (6 decimals)
    function getAccountEquityUsdc(
        bytes32 accountId
    ) public view returns (uint256 totalEquityUsdc) {
        return settlementBalances[accountId];
    }

    /// @notice Returns strictly unencumbered purchasing power
    /// @param accountId Account to query
    /// @return Equity minus locked margin, floored at zero (6 decimals)
    function getFreeBuyingPowerUsdc(
        bytes32 accountId
    ) public view returns (uint256) {
        uint256 equity = getAccountEquityUsdc(accountId);
        uint256 encumbered = _totalLockedMarginUsdc(accountId);
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns the explicit USDC bucket split after subtracting the clearinghouse's typed locked-margin buckets.
    function getAccountUsdcBuckets(
        bytes32 accountId
    ) public view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = _buildAccountUsdcBuckets(accountId);
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Locks margin to back a new CFD trade.
    ///         Requires sufficient USDC to back settlement (non-USDC equity alone is insufficient).
    /// @param accountId Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockPositionMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _lockMargin(accountId, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Unlocks active position margin when a CFD trade closes
    /// @param accountId Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals), clamped to current locked amount
    function unlockPositionMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(accountId, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Locks margin to back a pending order commitment.
    /// @param accountId Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockCommittedOrderMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(accountId);
        _lockMargin(accountId, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    function reserveCommittedOrderMargin(
        bytes32 accountId,
        uint64 orderId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (orderReservations[orderId].status != IMarginClearinghouse.ReservationStatus.None) {
            revert MarginClearinghouse__ReservationAlreadyExists();
        }
        if (amountUsdc == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        _checkpointCarryBeforeMarginChange(accountId);
        _lockMargin(accountId, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
        uint96 amount96 = _toUint96(amountUsdc);
        orderReservations[orderId] = IMarginClearinghouse.OrderReservation({
            accountId: accountId,
            bucket: IMarginClearinghouse.ReservationBucket.CommittedOrder,
            status: IMarginClearinghouse.ReservationStatus.Active,
            originalAmountUsdc: amount96,
            remainingAmountUsdc: amount96
        });
        reservationIdsByAccount[accountId].push(orderId);
        activeCommittedOrderReservationUsdc[accountId] += amountUsdc;
        activeReservationCount[accountId] += 1;

        emit ReservationCreated(orderId, accountId, IMarginClearinghouse.ReservationBucket.CommittedOrder, amountUsdc);
    }

    /// @notice Unlocks committed order margin when an order is cancelled or filled.
    /// @param accountId Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals)
    function unlockCommittedOrderMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(accountId);
        _unlockMargin(accountId, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
    }

    function releaseOrderReservation(
        uint64 orderId
    ) external onlyOperator returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = _activeReservation(orderId);
        _checkpointCarryBeforeMarginChange(reservation.accountId);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.accountId, releasedUsdc);
    }

    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external onlyOperator returns (uint256 releasedUsdc) {
        IMarginClearinghouse.OrderReservation storage reservation = orderReservations[orderId];
        if (reservation.status != IMarginClearinghouse.ReservationStatus.Active) {
            return 0;
        }

        _checkpointCarryBeforeMarginChange(reservation.accountId);
        releasedUsdc = _releaseReservation(reservation, true);
        emit ReservationReleased(orderId, reservation.accountId, releasedUsdc);
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

        emit ReservationConsumed(orderId, reservation.accountId, consumedUsdc, reservation.remainingAmountUsdc);
    }

    function consumeAccountOrderReservations(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator returns (uint256 consumedUsdc) {
        return _consumeAccountOrderReservations(accountId, amountUsdc, true);
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
                orderIds[i], reservation.accountId, reservationConsumedUsdc, reservation.remainingAmountUsdc
            );
        }
    }

    function _consumeAccountOrderReservations(
        bytes32 accountId,
        uint256 amountUsdc,
        bool consumeBuckets
    ) internal returns (uint256 consumedUsdc) {
        if (amountUsdc == 0) {
            return 0;
        }

        uint64[] storage reservationIds = reservationIdsByAccount[accountId];
        uint256 remainingUsdc = amountUsdc;
        for (uint256 i = reservationHeadIndexByAccount[accountId]; i < reservationIds.length && remainingUsdc > 0; i++) {
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
                reservationIds[i], accountId, reservationConsumedUsdc, reservation.remainingAmountUsdc
            );
        }

        _advanceReservationHead(accountId);
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
            _consumeReservationBucket(reservation.accountId, reservation.bucket, amountUsdc);
        }
        _decreaseActiveReservation(reservation.accountId, reservation.bucket, amountUsdc);

        if (reservation.remainingAmountUsdc == 0) {
            _closeReservation(reservation, terminalStatus);
        }
    }

    function _decreaseActiveReservation(
        bytes32 accountId,
        IMarginClearinghouse.ReservationBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (bucket == IMarginClearinghouse.ReservationBucket.CommittedOrder) {
            activeCommittedOrderReservationUsdc[accountId] -= amountUsdc;
        } else {
            activeReservedSettlementReservationUsdc[accountId] -= amountUsdc;
        }
    }

    function lockReservedSettlement(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(accountId);
        _lockMargin(accountId, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    function unlockReservedSettlement(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _checkpointCarryBeforeMarginChange(accountId);
        _unlockMargin(accountId, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
    }

    /// @notice Adjusts settlement USDC for realized PnL, deferred servicing, and rebates.
    ///         Positive amounts credit the account; negative amounts debit it.
    /// @param accountId Account to settle
    /// @param amount Signed USDC delta: positive credits, negative debits (6 decimals)
    function settleUsdc(
        bytes32 accountId,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            _creditSettlementUsdc(accountId, uint256(amount));
        } else if (amount < 0) {
            _debitSettlementUsdc(accountId, uint256(-amount));
        }
    }

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }

        _creditSettlementUsdc(accountId, amountUsdc);
        _lockMargin(accountId, IMarginClearinghouse.MarginBucket.Position, amountUsdc);
    }

    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        bytes32 accountId,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external onlyOperator returns (int256 netMarginChangeUsdc) {
        MarginClearinghouseAccountingLib.OpenCostPlan memory plan =
            MarginClearinghouseAccountingLib.planOpenCostApplication(
                _buildAccountUsdcBuckets(accountId), marginDeltaUsdc, tradeCostUsdc
            );

        if (plan.insufficientPositionMargin) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        if (plan.insufficientFreeEquity) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }

        netMarginChangeUsdc = plan.netMarginChangeUsdc;
        if (plan.settlementCreditUsdc > 0) {
            _creditSettlementUsdc(accountId, plan.settlementCreditUsdc);
        }

        if (plan.positionMarginUnlockedUsdc > 0) {
            _unlockMargin(accountId, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedUsdc);
        }

        if (plan.settlementDebitUsdc > 0) {
            settlementBalances[accountId] -= plan.settlementDebitUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, plan.settlementDebitUsdc);
            emit AssetSeized(accountId, settlementAsset, plan.settlementDebitUsdc, recipient);
        }

        if (plan.positionMarginLockedUsdc > 0) {
            _lockMargin(accountId, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginLockedUsdc);
        }
    }

    /// @notice Consumes a realized settlement loss from free settlement first, then from active position margin.
    /// @dev Unrelated locked margin remains protected.
    function consumeSettlementLoss(
        bytes32 accountId,
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
            _planFundingLossConsumption(accountId, lossUsdc);
        freeSettlementConsumedUsdc = consumption.freeSettlementConsumedUsdc;
        marginConsumedUsdc = consumption.activeMarginConsumedUsdc;
        uncoveredUsdc = consumption.uncoveredUsdc;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildAccountUsdcBuckets(accountId);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyFundingLossMutation(buckets, consumption);

        if (mutation.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(
                accountId, IMarginClearinghouse.MarginBucket.Position, mutation.positionMarginUnlockedUsdc
            );
        }

        uint256 totalConsumedUsdc = mutation.settlementDebitUsdc;
        if (totalConsumedUsdc == 0) {
            return (marginConsumedUsdc, freeSettlementConsumedUsdc, uncoveredUsdc);
        }

        settlementBalances[accountId] -= totalConsumedUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, totalConsumedUsdc);
        emit AssetSeized(accountId, settlementAsset, totalConsumedUsdc, recipient);
    }

    /// @notice Consumes close-path losses from settlement buckets while preserving any explicitly protected remaining position margin.
    function consumeCloseLoss(
        bytes32 accountId,
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
                settlementBalances[accountId],
                positionMarginUsdc[accountId],
                committedOrderMarginUsdc[accountId],
                reservedSettlementUsdc[accountId]
            )
            : MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
                settlementBalances[accountId],
                positionMarginUsdc[accountId],
                committedOrderMarginUsdc[accountId],
                reservedSettlementUsdc[accountId]
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
                accountId, IMarginClearinghouse.MarginBucket.Position, mutation.positionMarginUnlockedUsdc
            );
        }
        if (includeOtherLockedMargin && mutation.otherLockedMarginUnlockedUsdc > 0) {
            _consumeOtherLockedMarginViaReservations(
                accountId, reservationOrderIds, mutation.otherLockedMarginUnlockedUsdc
            );
        }

        settlementBalances[accountId] -= mutation.settlementDebitUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, mutation.settlementDebitUsdc);
        emit AssetSeized(accountId, settlementAsset, mutation.settlementDebitUsdc, recipient);
    }

    /// @notice Applies a pre-planned liquidation settlement mutation.
    /// @dev Releases the active position margin bucket and covered committed margin exactly as planned.
    function applyLiquidationSettlementPlan(
        bytes32 accountId,
        uint64[] calldata reservationOrderIds,
        IMarginClearinghouse.LiquidationSettlementPlan calldata plan,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc) {
        seizedUsdc = plan.settlementSeizedUsdc;

        if (plan.positionMarginUnlockedUsdc > 0) {
            _consumeLockedMargin(accountId, IMarginClearinghouse.MarginBucket.Position, plan.positionMarginUnlockedUsdc);
        }
        if (plan.otherLockedMarginUnlockedUsdc > 0) {
            _consumeOtherLockedMarginViaReservations(accountId, reservationOrderIds, plan.otherLockedMarginUnlockedUsdc);
        }

        if (seizedUsdc > 0) {
            settlementBalances[accountId] -= plan.settlementSeizedUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, plan.settlementSeizedUsdc);
            emit AssetSeized(accountId, settlementAsset, plan.settlementSeizedUsdc, recipient);
        }
    }

    function _buildAccountUsdcBuckets(
        bytes32 accountId
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalances[accountId],
            positionMarginUsdc[accountId],
            committedOrderMarginUsdc[accountId],
            reservedSettlementUsdc[accountId]
        );
    }

    function _planFundingLossConsumption(
        bytes32 accountId,
        uint256 lossUsdc
    ) internal view returns (MarginClearinghouseAccountingLib.SettlementConsumption memory consumption) {
        return
            MarginClearinghouseAccountingLib.planFundingLossConsumption(_buildAccountUsdcBuckets(accountId), lossUsdc);
    }

    function _creditSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        settlementBalances[accountId] += amountUsdc;
    }

    function _checkpointCarryBeforeMarginChange(
        bytes32 accountId
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        uint256 reachableCollateralBasisUsdc =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(getAccountUsdcBuckets(accountId));
        _checkpointCarryBeforeMarginChange(accountId, reachableCollateralBasisUsdc);
    }

    function _checkpointCarryBeforeMarginChange(
        bytes32 accountId,
        uint256 reachableCollateralBasisUsdc
    ) internal {
        address engine_ = engine;
        if (engine_ == address(0)) {
            return;
        }

        ICfdEngineCore(engine_).realizeCarryBeforeMarginChange(accountId, reachableCollateralBasisUsdc);
    }

    function _debitSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (settlementBalances[accountId] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        settlementBalances[accountId] -= amountUsdc;
    }

    function _lockMargin(
        bytes32 accountId,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (getFreeBuyingPowerUsdc(accountId) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[accountId] < _totalLockedMarginUsdc(accountId) + amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        _setBucketStorage(bucket, accountId, _bucketStorage(bucket, accountId) + amountUsdc);
        emit MarginLocked(accountId, bucket, amountUsdc);
    }

    function _unlockMargin(
        bytes32 accountId,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        _consumeLockedMargin(accountId, bucket, amountUsdc);
    }

    /// @dev Consumes non-position locked margin by priority: committed-order margin first, then reserved settlement.
    ///      Queued order margin is released before reserved settlement because failed/cancelled order intents are softer
    ///      obligations than explicitly reserved settlement buckets.
    function _consumeOtherLockedMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        uint256 committedConsumedUsdc =
            amountUsdc > committedOrderMarginUsdc[accountId] ? committedOrderMarginUsdc[accountId] : amountUsdc;
        if (committedConsumedUsdc > 0) {
            committedOrderMarginUsdc[accountId] -= committedConsumedUsdc;
            emit MarginUnlocked(accountId, IMarginClearinghouse.MarginBucket.CommittedOrder, committedConsumedUsdc);
        }

        uint256 remainingUsdc = amountUsdc - committedConsumedUsdc;
        if (remainingUsdc > 0) {
            if (reservedSettlementUsdc[accountId] < remainingUsdc) {
                revert MarginClearinghouse__InsufficientBucketMargin();
            }
            reservedSettlementUsdc[accountId] -= remainingUsdc;
            emit MarginUnlocked(accountId, IMarginClearinghouse.MarginBucket.ReservedSettlement, remainingUsdc);
        }
    }

    function _consumeOtherLockedMarginViaReservations(
        bytes32 accountId,
        uint64[] calldata reservationOrderIds,
        uint256 amountUsdc
    ) internal {
        uint256 consumedReservationUsdc = _consumeOrderReservationsById(reservationOrderIds, amountUsdc);
        uint256 residualOtherLockedUsdc = amountUsdc - consumedReservationUsdc;
        if (residualOtherLockedUsdc > 0) {
            if (committedOrderMarginUsdc[accountId] > 0) {
                revert MarginClearinghouse__IncompleteReservationCoverage();
            }
            _consumeOtherLockedMargin(accountId, residualOtherLockedUsdc);
        }
    }

    function _consumeReservationBucket(
        bytes32 accountId,
        IMarginClearinghouse.ReservationBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (bucket == IMarginClearinghouse.ReservationBucket.CommittedOrder) {
            _consumeLockedMargin(accountId, IMarginClearinghouse.MarginBucket.CommittedOrder, amountUsdc);
        } else if (bucket == IMarginClearinghouse.ReservationBucket.ReservedSettlement) {
            _consumeLockedMargin(accountId, IMarginClearinghouse.MarginBucket.ReservedSettlement, amountUsdc);
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
        activeReservationCount[reservation.accountId] -= 1;
        _advanceReservationHead(reservation.accountId);
    }

    function _advanceReservationHead(
        bytes32 accountId
    ) internal {
        uint64[] storage reservationIds = reservationIdsByAccount[accountId];
        uint256 headIndex = reservationHeadIndexByAccount[accountId];
        while (headIndex < reservationIds.length) {
            if (orderReservations[reservationIds[headIndex]].status == IMarginClearinghouse.ReservationStatus.Active) {
                break;
            }
            headIndex++;
        }
        reservationHeadIndexByAccount[accountId] = headIndex;
    }

    function _consumeLockedMargin(
        bytes32 accountId,
        IMarginClearinghouse.MarginBucket bucket,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }
        uint256 currentBucket = _bucketStorage(bucket, accountId);
        if (currentBucket < amountUsdc) {
            revert MarginClearinghouse__InsufficientBucketMargin();
        }
        _setBucketStorage(bucket, accountId, currentBucket - amountUsdc);
        emit MarginUnlocked(accountId, bucket, amountUsdc);
    }

    function _bucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        bytes32 accountId
    ) internal view returns (uint256 bucketValue) {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            return positionMarginUsdc[accountId];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            return committedOrderMarginUsdc[accountId];
        }
        if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            return reservedSettlementUsdc[accountId];
        }
        revert MarginClearinghouse__InvalidMarginBucket();
    }

    function _setBucketStorage(
        IMarginClearinghouse.MarginBucket bucket,
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (bucket == IMarginClearinghouse.MarginBucket.Position) {
            positionMarginUsdc[accountId] = amountUsdc;
        } else if (bucket == IMarginClearinghouse.MarginBucket.CommittedOrder) {
            committedOrderMarginUsdc[accountId] = amountUsdc;
        } else if (bucket == IMarginClearinghouse.MarginBucket.ReservedSettlement) {
            reservedSettlementUsdc[accountId] = amountUsdc;
        } else {
            revert MarginClearinghouse__InvalidMarginBucket();
        }
    }

    function _totalLockedMarginUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        return positionMarginUsdc[accountId] + committedOrderMarginUsdc[accountId] + reservedSettlementUsdc[accountId];
    }

    /// @notice Transfers settlement USDC from an account to the calling operator.
    /// @dev The recipient must equal msg.sender, so operators can only pull seized funds
    ///      into their own contract/account and must forward them explicitly afterward.
    /// @param accountId Account to seize from
    /// @param amount USDC amount to seize
    /// @param recipient Recipient of seized tokens (must equal msg.sender)
    function seizeUsdc(
        bytes32 accountId,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (recipient != msg.sender) {
            revert MarginClearinghouse__InvalidSeizeRecipient();
        }
        _checkpointCarryBeforeMarginChange(accountId);
        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > MarginClearinghouseAccountingLib.getFreeSettlementUsdc(_buildAccountUsdcBuckets(accountId))) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        settlementBalances[accountId] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, settlementAsset, amount, recipient);
    }

    function seizePositionMarginUsdc(
        bytes32 accountId,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (recipient == address(0)) {
            revert MarginClearinghouse__ZeroAddress();
        }
        if (amount == 0) {
            return;
        }
        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        _checkpointCarryBeforeMarginChange(accountId);
        _consumeLockedMargin(accountId, IMarginClearinghouse.MarginBucket.Position, amount);
        settlementBalances[accountId] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, settlementAsset, amount, recipient);
    }

    function balanceUsdc(
        bytes32 accountId
    ) external view returns (uint256) {
        return settlementBalances[accountId];
    }

    function lockedMarginUsdc(
        bytes32 accountId
    ) external view returns (uint256) {
        return _totalLockedMarginUsdc(accountId);
    }

    function getLockedMarginBuckets(
        bytes32 accountId
    ) external view returns (IMarginClearinghouse.LockedMarginBuckets memory buckets) {
        buckets.positionMarginUsdc = positionMarginUsdc[accountId];
        buckets.committedOrderMarginUsdc = committedOrderMarginUsdc[accountId];
        buckets.reservedSettlementUsdc = reservedSettlementUsdc[accountId];
        buckets.totalLockedMarginUsdc = _totalLockedMarginUsdc(accountId);
    }

    function getOrderReservation(
        uint64 orderId
    ) external view returns (IMarginClearinghouse.OrderReservation memory reservation) {
        return orderReservations[orderId];
    }

    function getAccountReservationSummary(
        bytes32 accountId
    ) external view returns (IMarginClearinghouse.AccountReservationSummary memory summary) {
        summary.activeCommittedOrderMarginUsdc = activeCommittedOrderReservationUsdc[accountId];
        summary.activeReservedSettlementUsdc = activeReservedSettlementReservationUsdc[accountId];
        summary.activeReservationCount = activeReservationCount[accountId];
    }

    function reservationHeadIndex(
        bytes32 accountId
    ) external view returns (uint256) {
        return reservationHeadIndexByAccount[accountId];
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
