// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IPerpsKeeper} from "./interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "./interfaces/IPerpsTraderActions.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {OrderFailurePolicyLib} from "./libraries/OrderFailurePolicyLib.sol";
import {OrderExecutionOrchestrator} from "./modules/OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "./modules/OrderOracleExecution.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev Holds only non-trader-owned keeper execution reserves. Trader collateral remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, Ownable2Step, Pausable, OrderExecutionOrchestrator {

    using SafeERC20 for IERC20;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;

    uint256 public maxOrderAge;
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 internal constant OPEN_ORDER_EXECUTION_BOUNTY_BPS = 1;
    uint256 internal constant MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC = 50_000;
    uint256 internal constant MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant CLOSE_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant MAX_PENDING_ORDERS = 5;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;

    mapping(address => uint256) internal claimableEth;
    uint64 public globalTailOrderId;

    error OrderRouter__ZeroSize();
    error OrderRouter__CloseMarginDeltaNotAllowed();
    error OrderRouter__TimelockNotReady();
    error OrderRouter__NoProposal();
    error OrderRouter__FIFOViolation();
    error OrderRouter__OrderNotPending();
    error OrderRouter__InsufficientPythFee();
    error OrderRouter__MockModeDisabled();
    error OrderRouter__NoOrdersToExecute();
    error OrderRouter__MaxOrderIdNotCommitted();
    error OrderRouter__OraclePriceTooStale();
    error OrderRouter__NothingToClaim();
    error OrderRouter__EthTransferFailed();
    error OrderRouter__OraclePriceNegative();
    error OrderRouter__MevOraclePriceTooStale();
    error OrderRouter__LengthMismatch();
    error OrderRouter__InvalidWeights();
    error OrderRouter__InvalidBasePrice();
    error OrderRouter__EmptyFeeds();
    error OrderRouter__MevDetected();
    error OrderRouter__MissingPythUpdateData();
    error OrderRouter__OracleFrozen();
    error OrderRouter__InsufficientGas();
    error OrderRouter__NoOpenPosition();
    error OrderRouter__CloseSideMismatch();
    error OrderRouter__CloseSizeExceedsPosition();
    error OrderRouter__InsufficientFreeEquity();
    error OrderRouter__MarginOrderLinkCorrupted();
    error OrderRouter__PendingOrderLinkCorrupted();
    error OrderRouter__Unauthorized();
    error OrderRouter__TooManyPendingOrders();
    error OrderRouter__DegradedMode();
    error OrderRouter__CloseOnlyMode();
    error OrderRouter__SeedLifecycleIncomplete();
    error OrderRouter__TradingNotActive();
    error OrderRouter__OraclePublishTimeOutOfOrder();
    error OrderRouter__InvalidStalenessLimit();
    error OrderRouter__ZeroAddress();
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    struct TimelockedUintProposal {
        uint256 value;
        uint256 activationTime;
    }

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    modifier onlyEngine() {
        if (msg.sender != address(engine) && msg.sender != address(engine.settlementModule())) {
            revert OrderRouter__Unauthorized();
        }
        _;
    }

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _vault CfdVault used for vault depth queries and liquidation bounty payouts
    /// @param _pyth Pyth oracle contract (address(0) enables mock mode on Anvil)
    /// @param _feedIds Pyth price feed IDs for each basket component
    /// @param _quantities Weight of each component (must sum to 1e18)
    /// @param _basePrices Base price per component for normalization (8 decimals)
    /// @param _inversions Whether to invert each feed (e.g. USD/JPY -> JPY/USD)
    constructor(
        address _engine,
        address _engineLens,
        address _vault,
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    )
        Ownable(msg.sender)
        OrderOracleExecution(_engine, _engineLens, _vault, _pyth, _feedIds, _quantities, _basePrices, _inversions)
    {
        maxOrderAge = DEFAULT_MAX_ORDER_AGE;
    }

    function _revertZeroAddress() internal pure override {
        revert OrderRouter__ZeroAddress();
    }

    function _revertEmptyFeeds() internal pure override {
        revert OrderRouter__EmptyFeeds();
    }

    function _revertLengthMismatch() internal pure override {
        revert OrderRouter__LengthMismatch();
    }

    function _revertInvalidBasePrice() internal pure override {
        revert OrderRouter__InvalidBasePrice();
    }

    function _revertInvalidWeights() internal pure override {
        revert OrderRouter__InvalidWeights();
    }

    function _revertMissingPythUpdateData() internal pure override {
        revert OrderRouter__MissingPythUpdateData();
    }

    function _revertInsufficientPythFee() internal pure override {
        revert OrderRouter__InsufficientPythFee();
    }

    function _revertMockModeDisabled() internal pure override {
        revert OrderRouter__MockModeDisabled();
    }

    function _revertOraclePriceTooStale() internal pure override {
        revert OrderRouter__OraclePriceTooStale();
    }

    function _revertOraclePublishTimeOutOfOrder() internal pure override {
        revert OrderRouter__OraclePublishTimeOutOfOrder();
    }

    function _revertMevOraclePriceTooStale() internal pure override {
        revert OrderRouter__MevOraclePriceTooStale();
    }

    function _revertOraclePriceNegative() internal pure override {
        revert OrderRouter__OraclePriceNegative();
    }

    // ==========================================
    // ADMIN
    // ==========================================

    /// @notice Proposes a new maxOrderAge value, subject to 48h timelock.
    function proposeMaxOrderAge(
        uint256 newMaxOrderAge
    ) external onlyOwner {
        (pendingMaxOrderAge, maxOrderAgeActivationTime) = _proposeUint(newMaxOrderAge);
    }

    /// @notice Finalizes the pending maxOrderAge after timelock expires.
    function finalizeMaxOrderAge() external onlyOwner {
        maxOrderAge = _finalizeUint(TimelockedUintProposal(pendingMaxOrderAge, maxOrderAgeActivationTime));
        pendingMaxOrderAge = 0;
        maxOrderAgeActivationTime = 0;
    }

    /// @notice Proposes the live-market staleness limit for normal order execution and mark refresh.
    function proposeOrderExecutionStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouter__InvalidStalenessLimit();
        }
        (pendingOrderExecutionStalenessLimit, orderExecutionStalenessActivationTime) = _proposeUint(limit);
    }

    /// @notice Finalizes the pending live-market execution staleness limit after timelock expiry.
    function finalizeOrderExecutionStalenessLimit() external onlyOwner {
        orderExecutionStalenessLimit = _finalizeUint(
            TimelockedUintProposal(pendingOrderExecutionStalenessLimit, orderExecutionStalenessActivationTime)
        );
        pendingOrderExecutionStalenessLimit = 0;
        orderExecutionStalenessActivationTime = 0;
    }

    /// @notice Proposes the live-market staleness limit for liquidations.
    function proposeLiquidationStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouter__InvalidStalenessLimit();
        }
        (pendingLiquidationStalenessLimit, liquidationStalenessActivationTime) = _proposeUint(limit);
    }

    /// @notice Finalizes the pending liquidation staleness limit after timelock expiry.
    function finalizeLiquidationStalenessLimit() external onlyOwner {
        liquidationStalenessLimit =
            _finalizeUint(TimelockedUintProposal(pendingLiquidationStalenessLimit, liquidationStalenessActivationTime));
        pendingLiquidationStalenessLimit = 0;
        liquidationStalenessActivationTime = 0;
    }

    /// @notice Pauses new risk-increasing order commits.
    /// @dev Keeper execution and liquidation remain available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses new risk-increasing order commits.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==========================================
    // STEP 1: THE COMMITMENT (User Intent)
    // ==========================================

    /// @notice Submits a trade intent to the FIFO queue.
    ///         Margin and the order's execution bounty are reserved immediately.
    /// @param side BULL or BEAR
    /// @param sizeDelta Position size change (18 decimals)
    /// @param marginDelta Margin to add or remove (6 decimals, USDC)
    /// @param targetPrice Slippage limit price (8 decimals, 0 = market order)
    /// @param isClose True to allow execution even when paused or in FAD close-only mode
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external {
        if (!isClose) {
            _requireNotPaused();
            if (engine.degradedMode()) {
                revert OrderRouter__DegradedMode();
            }
            if (_isCloseOnlyWindow()) {
                revert OrderRouter__CloseOnlyMode();
            }
            if (!vault.canIncreaseRisk()) {
                if (!vault.isSeedLifecycleComplete()) {
                    revert OrderRouter__SeedLifecycleIncomplete();
                }
                revert OrderRouter__TradingNotActive();
            }
        }
        if (sizeDelta == 0) {
            revert OrderRouter__ZeroSize();
        }
        if (isClose && marginDelta > 0) {
            revert OrderRouter__CloseMarginDeltaNotAllowed();
        }
        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));
        uint256 executionBountyUsdc;
        if (isClose) {
            QueuedPositionView memory queuedPosition = _getQueuedPositionView(accountId);
            if (!queuedPosition.exists || queuedPosition.size == 0) {
                revert OrderRouter__NoOpenPosition();
            }
            if (queuedPosition.side != side) {
                revert OrderRouter__CloseSideMismatch();
            }
            if (sizeDelta > queuedPosition.size) {
                revert OrderRouter__CloseSizeExceedsPosition();
            }
            executionBountyUsdc = CLOSE_ORDER_EXECUTION_BOUNTY_USDC;
        } else {
            uint256 commitPrice = _commitReferencePrice();
            if (_canUseCommitMarkForOpenPrefilter()) {
                uint64 commitMarkTime = engine.lastMarkTime();
                CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory =
                    engineLens.previewOpenFailurePolicyCategory(
                        accountId, side, sizeDelta, marginDelta, commitPrice, commitMarkTime
                    );
                uint8 revertCode = engineLens.previewOpenRevertCode(
                    accountId, side, sizeDelta, marginDelta, commitPrice, commitMarkTime
                );
                if (OrderFailurePolicyLib.isPredictablyInvalidOpen(failureCategory)) {
                    revert OrderRouter__PredictableOpenInvalid(revertCode);
                }
            }
            executionBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(sizeDelta, commitPrice);
        }

        uint64 orderId = nextCommitId++;

        _reserveExecutionBounty(accountId, orderId, executionBountyUsdc, isClose);
        _reserveCommittedMargin(accountId, orderId, isClose, marginDelta);

        OrderRecord storage record = orderRecords[orderId];
        record.core = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: orderId,
            side: side,
            isClose: isClose
        });
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        if (isClose) {
            pendingCloseSize[accountId] += sizeDelta;
        }
        _linkGlobalOrder(orderId);
        _linkAccountOrder(accountId, orderId);
        if (++pendingOrderCounts[accountId] > MAX_PENDING_ORDERS) {
            revert OrderRouter__TooManyPendingOrders();
        }
        emit OrderCommitted(orderId, accountId, side);
    }

    /// @dev Legacy raw order-record getter kept for tests and migration only.
    function getOrderRecord(
        uint64 orderId
    ) external view returns (OrderRecord memory) {
        return orderRecords[orderId];
    }

    /// @notice Returns the total queued escrow state for an account across all pending orders.
    function syncMarginQueue(
        bytes32 accountId
    ) external onlyEngine {
        _pruneMarginQueue(accountId);
    }

    function getPendingOrdersForAccount(
        bytes32 accountId
    ) external view returns (IOrderRouterAccounting.PendingOrderView[] memory pending) {
        pending = new IOrderRouterAccounting.PendingOrderView[](pendingOrderCounts[accountId]);
        uint256 index;
        for (
            uint64 orderId = accountHeadOrderId[accountId];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;
            pending[index] = IOrderRouterAccounting.PendingOrderView({
                orderId: orderId,
                isClose: order.isClose,
                side: order.side,
                sizeDelta: order.sizeDelta,
                marginDelta: order.marginDelta,
                targetPrice: order.targetPrice,
                commitTime: order.commitTime,
                commitBlock: order.commitBlock,
                committedMarginUsdc: clearinghouse.getOrderReservation(orderId).remainingAmountUsdc,
                executionBountyUsdc: record.executionBountyUsdc
            });
            index++;
        }
    }

    // ==========================================
    // STEP 2: THE REVEAL (Keeper Execution)
    // ==========================================

    /// @notice Keeper executes the current global queue head.
    /// @dev Validates oracle freshness, publish-time ordering, and slippage, then delegates to the
    ///      engine. Invalid, expired, or out-of-slippage orders are finalized from router-custodied
    ///      execution bounty escrow; the router does not maintain a retry/requeue lane.
    /// @param orderId Must equal the current global queue head (expired orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        uint64 initialHeadOrderId = nextExecuteId;
        (, CfdTypes.Order memory initialHeadOrder) = _pendingOrder(initialHeadOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, initialHeadOrder.targetPrice);

        _skipStaleOrders(orderId, update.executionPrice, update.oraclePublishTime);
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (orderId < nextExecuteId) {
            orderId = nextExecuteId;
        }
        if (orderId != nextExecuteId) {
            revert OrderRouter__FIFOViolation();
        }
        (, CfdTypes.Order memory order) = _pendingOrder(orderId);

        _executePendingOrder(
            orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, true, update.pythFee
        );
    }

    /// @notice Executes queued pending orders against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Aggregates reserved USDC
    ///         execution bounties across processed orders and refunds excess ETH in a single transfer.
    /// @param maxOrderId Inclusive upper bound on committed order ids the batch may begin processing from
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (maxOrderId < nextExecuteId) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (maxOrderId >= nextCommitId) {
            revert OrderRouter__MaxOrderIdNotCommitted();
        }

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, 1e8);
        uint256 expiredPrunes;

        while (nextExecuteId != 0 && nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= MAX_PRUNE_ORDERS_PER_CALL) {
                    break;
                }
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(
                    orderId, _failedOutcomeForTerminalFailure(order), update.executionPrice, update.oraclePublishTime
                );
                expiredPrunes++;
                continue;
            }

            OrderExecutionStepResult result = _executePendingOrder(
                orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, false, 0
            );
            if (result == OrderExecutionStepResult.Break) {
                break;
            }
        }

        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _queueHeadOrderId() internal view override returns (uint64) {
        return nextExecuteId;
    }

    function _setQueueHeadOrderId(
        uint64 orderId
    ) internal override {
        nextExecuteId = orderId;
    }

    function _queueTailOrderId() internal view override returns (uint64) {
        return globalTailOrderId;
    }

    function _setQueueTailOrderId(
        uint64 orderId
    ) internal override {
        globalTailOrderId = orderId;
    }

    function _revertOrderNotPending() internal pure override {
        revert OrderRouter__OrderNotPending();
    }

    function _maxOrderAge() internal view override returns (uint256) {
        return maxOrderAge;
    }

    function _revertNoOrdersToExecute() internal pure override {
        revert OrderRouter__NoOrdersToExecute();
    }

    function _revertInsufficientGas() internal pure override {
        revert OrderRouter__InsufficientGas();
    }

    function _revertMevDetected() internal pure override {
        revert OrderRouter__MevDetected();
    }

    function _revertCloseOnlyMode() internal pure override {
        revert OrderRouter__CloseOnlyMode();
    }

    /// @notice Prunes expired head-of-queue orders in bounded slices.
    /// @dev This is a maintenance path for advancing the global FIFO without requiring a full execute call.
    function pruneExpiredOrders(
        uint64 upToId,
        uint256 maxPrunes
    ) external {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        uint256 boundedPrunes = maxPrunes > MAX_PRUNE_ORDERS_PER_CALL ? MAX_PRUNE_ORDERS_PER_CALL : maxPrunes;
        if (boundedPrunes == 0) {
            return;
        }
        uint64 cachedMarkTime = engine.lastMarkTime();
        if (cachedMarkTime == 0 || block.timestamp > cachedMarkTime + orderExecutionStalenessLimit) {
            return;
        }
        _pruneExpiredHeadOrders(upToId, boundedPrunes, engine.lastMarkPrice(), cachedMarkTime);
    }

    function _timelockReadyAt() internal view returns (uint256) {
        return block.timestamp + TIMELOCK_DELAY;
    }

    function _requireTimelockReady(
        uint256 readyAt
    ) internal view {
        if (readyAt == 0) {
            revert OrderRouter__NoProposal();
        }
        if (block.timestamp < readyAt) {
            revert OrderRouter__TimelockNotReady();
        }
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal override {
        if (amount > 0) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                claimableEth[to] += amount;
            }
        }
    }

    /// @dev Liquidation keeper value follows the same default custody path as other keeper flows:
    ///      credit the beneficiary's clearinghouse account when cash is available, otherwise defer the
    ///      claim for later clearinghouse settlement.
    function _creditOrDeferLiquidationBounty(
        uint256 liquidationBountyUsdc,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        if (liquidationBountyUsdc == 0) {
            return;
        }

        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveFreshPayouts(
            vault.totalAssets(),
            engine.accumulatedFeesUsdc(),
            engine.totalDeferredTraderCreditUsdc(),
            engine.totalDeferredKeeperCreditUsdc()
        );
        if (liquidationBountyUsdc > reservation.freeCashUsdc) {
            engine.recordDeferredKeeperCredit(msg.sender, liquidationBountyUsdc);
            return;
        }

        try vault.payOut(address(clearinghouse), liquidationBountyUsdc) {
            engine.creditKeeperExecutionBounty(msg.sender, liquidationBountyUsdc, executionPrice, oraclePublishTime);
        } catch {
            engine.recordDeferredKeeperCredit(msg.sender, liquidationBountyUsdc);
        }
    }

    function _forfeitEscrowedOrderBountiesOnLiquidation(
        bytes32 accountId
    ) internal {
        uint256 forfeitedUsdc;
        for (
            uint64 orderId = accountHeadOrderId[accountId];
            orderId != 0;
            orderId = orderRecords[orderId].nextAccountOrderId
        ) {
            OrderRecord storage record = orderRecords[orderId];
            if (record.executionBountyUsdc > 0) {
                forfeitedUsdc += record.executionBountyUsdc;
                record.executionBountyUsdc = 0;
            }
        }

        if (forfeitedUsdc == 0) {
            return;
        }

        USDC.safeTransfer(address(vault), forfeitedUsdc);
        vault.recordProtocolInflow(forfeitedUsdc);
        engine.recordRouterProtocolFee(forfeitedUsdc);
    }

    function _clearLiquidatedAccountOrders(
        bytes32 accountId
    ) internal {
        uint64 orderId = accountHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            uint64 nextOrderId = record.nextAccountOrderId;
            _releaseCommittedMargin(orderId);
            emit OrderFailed(orderId, OrderFailReason.AccountLiquidated);
            _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
            orderId = nextOrderId;
        }
    }

    function _quoteOpenOrderExecutionBountyUsdc(
        uint256 sizeDelta,
        uint256 price
    ) internal pure returns (uint256) {
        uint256 notionalUsdc = (sizeDelta * price) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        uint256 executionBountyUsdc = (notionalUsdc * OPEN_ORDER_EXECUTION_BOUNTY_BPS) / 10_000;
        if (executionBountyUsdc < MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC) {
            executionBountyUsdc = MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC;
        }
        return executionBountyUsdc > MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC
            ? MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC
            : executionBountyUsdc;
    }

    function _reserveCloseExecutionBounty(
        bytes32 accountId,
        uint256 executionBountyUsdc
    ) internal override {
        bool hasFreshCarryCheckpointMark = _hasFreshCarryCheckpointMark();
        uint256 freeSettlementUsdc =
            MarginClearinghouseAccountingLib.getFreeSettlementUsdc(clearinghouse.getAccountUsdcBuckets(accountId));
        uint256 freeBackedBountyUsdc =
            freeSettlementUsdc > executionBountyUsdc ? executionBountyUsdc : freeSettlementUsdc;
        if (freeBackedBountyUsdc > 0) {
            if (hasFreshCarryCheckpointMark) {
                clearinghouse.seizeUsdc(accountId, freeBackedBountyUsdc, address(this));
            } else {
                clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(
                    accountId, freeBackedBountyUsdc, address(this)
                );
            }
        }

        uint256 marginBackedBountyUsdc = executionBountyUsdc - freeBackedBountyUsdc;
        if (marginBackedBountyUsdc == 0) {
            return;
        }

        try engine.reserveCloseOrderExecutionBounty(accountId, marginBackedBountyUsdc, address(this)) {}
        catch {
            revert OrderRouter__InsufficientFreeEquity();
        }
    }

    function _hasFreshCarryCheckpointMark() internal view returns (bool) {
        uint256 lastMarkPrice = engine.lastMarkPrice();
        uint64 lastMarkTime = engine.lastMarkTime();
        if (lastMarkPrice == 0 || lastMarkTime == 0) {
            return false;
        }

        OracleFreshnessPolicyLib.Policy memory liveMarkPolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile,
            _isOracleFrozen(),
            engine.isFadWindow(),
            engine.engineMarkStalenessLimit(),
            vault.markStalenessLimit(),
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );
        return !OracleFreshnessPolicyLib.isStale(lastMarkTime, liveMarkPolicy.maxStaleness, block.timestamp);
    }

    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal override {
        OrderRecord storage record = _orderRecord(orderId);
        bytes32 accountId = record.core.accountId;
        if (accountId != bytes32(0)) {
            _unlinkAccountOrder(accountId, orderId);
            _unlinkMarginOrder(accountId, orderId);
        }
        _unlinkGlobalOrder(orderId);
        record.status = terminalStatus;
        if (accountId != bytes32(0) && pendingOrderCounts[accountId] > 0) {
            pendingOrderCounts[accountId]--;
        }
        if (accountId != bytes32(0) && record.core.isClose && pendingCloseSize[accountId] >= record.core.sizeDelta) {
            pendingCloseSize[accountId] -= record.core.sizeDelta;
        }
    }

    function _proposeUint(
        uint256 value
    ) internal view returns (uint256 pendingValue, uint256 activationTime) {
        pendingValue = value;
        activationTime = _timelockReadyAt();
    }

    function _finalizeUint(
        TimelockedUintProposal memory proposal
    ) internal view returns (uint256) {
        _requireTimelockReady(proposal.activationTime);
        return proposal.value;
    }

    function _claimAmount(
        mapping(address => uint256) storage claimable
    ) internal returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) {
            revert OrderRouter__NothingToClaim();
        }
        claimable[msg.sender] = 0;
    }

    function _nextCommitId() internal view override returns (uint64) {
        return nextCommitId;
    }

    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal override {
        _releaseCommittedMargin(orderId);
    }

    /// @notice Claims ETH balances that could not be pushed during prior cleanup/refund flows.
    function claimBalance(
        bool ethBalance
    ) external {
        if (!ethBalance) {
            revert OrderRouter__NothingToClaim();
        }

        uint256 ethAmount = _claimAmount(claimableEth);
        (bool success,) = payable(msg.sender).call{value: ethAmount}("");
        if (!success) {
            revert OrderRouter__EthTransferFailed();
        }
    }

    // ==========================================
    // MARK PRICE REFRESH
    // ==========================================

    /// @notice Push a fresh mark price to the engine without processing an order.
    ///         Required before LP deposits/withdrawals when mark is stale.
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable {
        OracleUpdateResult memory update = _prepareMarkRefreshOracle(pythUpdateData);
        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    // ==========================================
    // ATOMIC LIQUIDATIONS
    // ==========================================

    /// @notice Keeper-triggered liquidation using the canonical live-market staleness policy.
    ///         Forfeits any queued-order execution escrow to the vault instead of crediting it back to trader settlement,
    ///         then credits the liquidation keeper through the clearinghouse when cash is available.
    /// @param accountId The account to liquidate (bytes32-encoded address)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeLiquidation(
        bytes32 accountId,
        bytes[] calldata pythUpdateData
    ) external payable {
        OracleUpdateResult memory update = _prepareLiquidationOracle(pythUpdateData);

        _forfeitEscrowedOrderBountiesOnLiquidation(accountId);
        uint256 vaultDepth = vault.totalAssets();
        uint256 keeperBountyUsdc =
            engine.liquidatePosition(accountId, update.executionPrice, vaultDepth, update.oraclePublishTime);

        _clearLiquidatedAccountOrders(accountId);

        _creditOrDeferLiquidationBounty(keeperBountyUsdc, update.executionPrice, update.oraclePublishTime);

        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _revertInsufficientFreeEquity() internal pure override {
        revert OrderRouter__InsufficientFreeEquity();
    }

    function _revertMarginOrderLinkCorrupted() internal pure override {
        revert OrderRouter__MarginOrderLinkCorrupted();
    }

    function _revertPendingOrderLinkCorrupted() internal pure override {
        revert OrderRouter__PendingOrderLinkCorrupted();
    }

}
