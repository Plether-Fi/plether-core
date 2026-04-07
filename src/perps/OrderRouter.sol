// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IPerpsKeeper} from "./interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "./interfaces/IPerpsTraderActions.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OrderFailurePolicyLib} from "./libraries/OrderFailurePolicyLib.sol";
import {OrderOraclePolicyLib} from "./libraries/OrderOraclePolicyLib.sol";
import {OrderEscrowAccounting} from "./modules/OrderEscrowAccounting.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev Holds only non-trader-owned keeper execution reserves. Trader collateral remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, Ownable2Step, Pausable, OrderEscrowAccounting {

    using SafeERC20 for IERC20;

    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    bytes4 internal constant TYPED_ORDER_FAILURE_SELECTOR = ICfdEngineCore.CfdEngine__TypedOrderFailure.selector;
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineCore.CfdEngine__MarkPriceOutOfOrder.selector;

    struct QueuedPositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
    }

    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        bool degradedMode;
        OrderOraclePolicyLib.OracleExecutionPolicy policy;
    }

    enum OrderExecutionStepResult {
        Continue,
        Break,
        Return
    }

    ICfdVault internal immutable vault;
    IPyth public pyth;
    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;

    uint256 public maxOrderAge;
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant MIN_ENGINE_GAS = 600_000;
    uint256 internal constant MIN_MEV_PUBLISH_DELAY = 5;
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 internal constant MAX_EXPIRED_ORDER_SKIPS_PER_CALL = 32;
    uint256 internal constant MAX_BATCH_ORDER_SCANS = 64;
    uint256 internal constant MAX_PRUNE_ORDERS_PER_CALL = 64;
    uint256 internal constant OPEN_ORDER_EXECUTION_BOUNTY_BPS = 1;
    uint256 internal constant MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC = 50_000;
    uint256 internal constant MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant CLOSE_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 public constant MAX_PENDING_ORDERS = 5;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;
    uint256 public orderExecutionStalenessLimit = 60;
    uint256 public pendingOrderExecutionStalenessLimit;
    uint256 public orderExecutionStalenessActivationTime;
    uint256 public liquidationStalenessLimit = 15;
    uint256 public pendingLiquidationStalenessLimit;
    uint256 public liquidationStalenessActivationTime;

    mapping(address => uint256) public claimableEth;
    mapping(bytes32 => uint64) public pendingHeadOrderId;
    mapping(bytes32 => uint64) public pendingTailOrderId;
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
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    enum OrderFailReason {
        Expired,
        CloseOnlyOracleFrozen,
        CloseOnlyFad,
        SlippageExceeded,
        EnginePanic,
        AccountLiquidated,
        EngineRevert
    }

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);
    modifier onlyEngine() {
        if (msg.sender != address(engine)) {
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
        address _vault,
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) Ownable(msg.sender) OrderEscrowAccounting(_engine) {
        vault = ICfdVault(_vault);
        pyth = IPyth(_pyth);
        maxOrderAge = DEFAULT_MAX_ORDER_AGE;

        if (_pyth != address(0)) {
            if (_feedIds.length == 0) {
                revert OrderRouter__EmptyFeeds();
            }
            if (
                _feedIds.length != _quantities.length || _feedIds.length != _basePrices.length
                    || _feedIds.length != _inversions.length
            ) {
                revert OrderRouter__LengthMismatch();
            }
            uint256 totalWeight;
            for (uint256 i = 0; i < _basePrices.length; i++) {
                if (_basePrices[i] == 0) {
                    revert OrderRouter__InvalidBasePrice();
                }
                totalWeight += _quantities[i];
            }
            if (totalWeight != 1e18) {
                revert OrderRouter__InvalidWeights();
            }
        }

        pythFeedIds = _feedIds;
        quantities = _quantities;
        basePrices = _basePrices;
        inversions = _inversions;
    }

    // ==========================================
    // ADMIN
    // ==========================================

    /// @notice Proposes a new maxOrderAge value, subject to 48h timelock.
    function proposeMaxOrderAge(
        uint256 _maxOrderAge
    ) external onlyOwner {
        pendingMaxOrderAge = _maxOrderAge;
        maxOrderAgeActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending maxOrderAge after timelock expires.
    function finalizeMaxOrderAge() external onlyOwner {
        if (maxOrderAgeActivationTime == 0) {
            revert OrderRouter__NoProposal();
        }
        if (block.timestamp < maxOrderAgeActivationTime) {
            revert OrderRouter__TimelockNotReady();
        }
        maxOrderAge = pendingMaxOrderAge;
        pendingMaxOrderAge = 0;
        maxOrderAgeActivationTime = 0;
    }

    /// @notice Cancels the pending maxOrderAge proposal.
    function cancelMaxOrderAgeProposal() external onlyOwner {
        pendingMaxOrderAge = 0;
        maxOrderAgeActivationTime = 0;
    }

    function proposeOrderExecutionStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouter__InvalidStalenessLimit();
        }
        pendingOrderExecutionStalenessLimit = limit;
        orderExecutionStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    function finalizeOrderExecutionStalenessLimit() external onlyOwner {
        if (orderExecutionStalenessActivationTime == 0) {
            revert OrderRouter__NoProposal();
        }
        if (block.timestamp < orderExecutionStalenessActivationTime) {
            revert OrderRouter__TimelockNotReady();
        }
        orderExecutionStalenessLimit = pendingOrderExecutionStalenessLimit;
        pendingOrderExecutionStalenessLimit = 0;
        orderExecutionStalenessActivationTime = 0;
    }

    function cancelOrderExecutionStalenessLimitProposal() external onlyOwner {
        pendingOrderExecutionStalenessLimit = 0;
        orderExecutionStalenessActivationTime = 0;
    }

    function proposeLiquidationStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouter__InvalidStalenessLimit();
        }
        pendingLiquidationStalenessLimit = limit;
        liquidationStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    function finalizeLiquidationStalenessLimit() external onlyOwner {
        if (liquidationStalenessActivationTime == 0) {
            revert OrderRouter__NoProposal();
        }
        if (block.timestamp < liquidationStalenessActivationTime) {
            revert OrderRouter__TimelockNotReady();
        }
        liquidationStalenessLimit = pendingLiquidationStalenessLimit;
        pendingLiquidationStalenessLimit = 0;
        liquidationStalenessActivationTime = 0;
    }

    function cancelLiquidationStalenessLimitProposal() external onlyOwner {
        pendingLiquidationStalenessLimit = 0;
        liquidationStalenessActivationTime = 0;
    }

    function pause() external onlyOwner {
        _pause();
    }

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
        _commitOrder(side, sizeDelta, marginDelta, targetPrice, isClose);
    }

    /// @notice Trader-facing wrapper that maps the simplified action surface onto the current router semantics.
    function submitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDeltaUsdc,
        uint256 acceptablePrice,
        bool isReduceOnly
    ) external {
        _commitOrder(side, sizeDelta, marginDeltaUsdc, acceptablePrice, isReduceOnly);
    }

    function _commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) internal {
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
        if (!isClose && _canUseCommitMarkForOpenPrefilter()) {
            CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engine.previewOpenFailurePolicyCategory(
                accountId, side, sizeDelta, marginDelta, _commitReferencePrice(), engine.lastMarkTime()
            );
            uint8 revertCode = engine.previewOpenRevertCode(
                accountId, side, sizeDelta, marginDelta, _commitReferencePrice(), engine.lastMarkTime()
            );
            if (OrderFailurePolicyLib.isPredictablyInvalidOpen(failureCategory)) {
                revert OrderRouter__PredictableOpenInvalid(revertCode);
            }
        }
        if (pendingOrderCounts[accountId] >= MAX_PENDING_ORDERS) {
            revert OrderRouter__TooManyPendingOrders();
        }
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
        }
        uint256 executionBountyUsdc = isClose
            ? _quoteCloseOrderExecutionBountyUsdc()
            : _quoteOpenOrderExecutionBountyUsdc(sizeDelta, _commitReferencePrice());

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
        _linkPendingOrder(accountId, orderId);
        _linkGlobalOrder(orderId);
        pendingOrderCounts[accountId]++;
        emit OrderCommitted(orderId, accountId, side);
    }

    /// @notice Quotes the reserved USDC execution bounty for a new open order using the latest engine mark price.
    /// @dev Falls back to 1.00 USD if the engine has not observed a mark yet. Result is floored at
    ///      0.05 USDC and capped at 1 USDC for non-close intents.
    /// @param sizeDelta Order size in 18-decimal notional units
    /// @return executionBountyUsdc Reserved execution bounty in 6-decimal USDC units
    function quoteOpenOrderExecutionBountyUsdc(
        uint256 sizeDelta
    ) external view returns (uint256 executionBountyUsdc) {
        return _quoteOpenOrderExecutionBountyUsdc(sizeDelta, _commitReferencePrice());
    }

    /// @notice Quotes the flat reserved USDC execution bounty for a close order.
    function quoteCloseOrderExecutionBountyUsdc() external pure returns (uint256 executionBountyUsdc) {
        return _quoteCloseOrderExecutionBountyUsdc();
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
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
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
            orderId = record.nextPendingOrderId;
        }
    }

    // ==========================================
    // STEP 2: THE REVEAL (Keeper Execution)
    // ==========================================

    /// @notice Keeper executes the current global queue head.
    ///         Validates oracle freshness and publish-time ordering against the order commit,
    ///         checks slippage, then delegates to CfdEngine. Terminal invalid/expired orders pay from
    ///         router-custodied execution bounty, while retryable slippage misses are requeued to the
    ///         global tail with cooldown so keepers cannot burn out-of-market intents or pin the FIFO head.
    /// @param orderId Must equal the current global queue head (expired orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        if (nextExecuteId == 0) {
            revert OrderRouter__NoOrdersToExecute();
        }
        _skipStaleOrders(orderId, MAX_EXPIRED_ORDER_SKIPS_PER_CALL);
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

        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) =
            _resolveOraclePrice(pythUpdateData, order.targetPrice);

        RouterExecutionContext memory executionContext;
        if (address(pyth) != address(0)) {
            executionContext = _currentRouterExecutionContext();
            if (OrderOraclePolicyLib.isStale(oraclePublishTime, executionContext.policy.maxStaleness, block.timestamp))
            {
                revert OrderRouter__OraclePriceTooStale();
            }
        }

        if (oraclePublishTime < engine.lastMarkTime()) {
            revert OrderRouter__OraclePublishTimeOutOfOrder();
        }

        uint256 capPrice = engine.CAP_PRICE();
        if (executionPrice > capPrice) {
            executionPrice = capPrice;
        }

        _executePendingOrder(orderId, order, executionPrice, oraclePublishTime, executionContext, true, pythFee);
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

        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) = _resolveOraclePrice(pythUpdateData, 1e8);

        RouterExecutionContext memory executionContext;
        if (address(pyth) != address(0)) {
            executionContext = _currentRouterExecutionContext();
            if (OrderOraclePolicyLib.isStale(oraclePublishTime, executionContext.policy.maxStaleness, block.timestamp))
            {
                revert OrderRouter__OraclePriceTooStale();
            }
        }

        if (oraclePublishTime < engine.lastMarkTime()) {
            revert OrderRouter__OraclePublishTimeOutOfOrder();
        }

        uint256 capPrice = engine.CAP_PRICE();
        uint256 clampedPrice = executionPrice > capPrice ? capPrice : executionPrice;

        uint256 scanned;
        uint256 maxScans = MAX_BATCH_ORDER_SCANS;
        while (nextExecuteId != 0 && nextExecuteId <= maxOrderId && scanned < maxScans) {
            scanned++;
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }

            OrderExecutionStepResult result =
                _executePendingOrder(orderId, order, clampedPrice, oraclePublishTime, executionContext, false, 0);
            if (result == OrderExecutionStepResult.Break) {
                break;
            }
        }

        _sendEth(msg.sender, msg.value - pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _skipStaleOrders(
        uint64 upToId,
        uint256 maxSkips
    ) internal returns (uint256 skipped) {
        uint256 age = maxOrderAge;
        while (nextExecuteId != 0 && nextExecuteId <= upToId && skipped < maxSkips) {
            uint64 headId = nextExecuteId;
            OrderRecord storage record = _orderRecord(headId);
            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }
            if (headId == upToId || age == 0) {
                break;
            }
            CfdTypes.Order memory order = record.core;
            if (block.timestamp - order.commitTime <= age) {
                break;
            }
            emit OrderFailed(headId, OrderFailReason.Expired);
            _cleanupOrder(headId, false, _failedOrderBountyPolicy(_routedExpiryFailure(order)));
            skipped++;
        }
    }

    function _currentRouterExecutionContext() internal view returns (RouterExecutionContext memory context) {
        context.oracleFrozen = _isOracleFrozen();
        context.isFadWindow = engine.isFadWindow();
        context.degradedMode = engine.degradedMode();
        context.policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
            OrderOraclePolicyLib.OracleAction.OrderExecution,
            context.oracleFrozen,
            context.isFadWindow,
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );
    }

    function _routedCloseOnlyFailure(
        CfdTypes.Order memory order,
        bool oracleFrozen,
        bool isFadWindow,
        bool degradedMode,
        bool closeOnly
    ) internal pure returns (OrderFailurePolicyLib.FailureContext memory failure) {
        failure = _routedRouterPolicyFailure(
            order,
            oracleFrozen
                ? OrderFailurePolicyLib.RouterFailureCode.CloseOnlyOracleFrozen
                : OrderFailurePolicyLib.RouterFailureCode.CloseOnlyFad,
            oracleFrozen,
            isFadWindow,
            degradedMode,
            closeOnly
        );
    }

    function _processTypedOrderExecution(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 vaultDepth,
        uint64 oraclePublishTime,
        bool oracleFrozen,
        bool isFadWindow,
        bool degradedMode
    )
        internal
        returns (
            bool success,
            OrderFailReason failureReason,
            OrderFailurePolicyLib.FailedOrderBountyPolicy failureBountyPolicy
        )
    {
        try engine.processOrderTyped(order, executionPrice, vaultDepth, oraclePublishTime) {
            return (true, OrderFailReason.EngineRevert, OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull);
        } catch (bytes memory revertData) {
            bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
            if (selector == MARK_PRICE_OUT_OF_ORDER_SELECTOR) {
                revert OrderRouter__OraclePublishTimeOutOfOrder();
            }
            failureReason = selector == PANIC_SELECTOR ? OrderFailReason.EnginePanic : OrderFailReason.EngineRevert;
            failureBountyPolicy = _failedOrderBountyPolicy(
                _routedFailureFromEngineRevert(order, revertData, oracleFrozen, isFadWindow, degradedMode)
            );
            return (false, failureReason, failureBountyPolicy);
        }
    }

    function _executePendingOrder(
        uint64 orderId,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 oraclePublishTime,
        RouterExecutionContext memory executionContext,
        bool revertOnBlockedExecution,
        uint256 pythFee
    ) internal returns (OrderExecutionStepResult result) {
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, OrderFailReason.Expired);
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                false,
                _failedOrderBountyPolicy(_routedExpiryFailure(order)),
                revertOnBlockedExecution
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        if (executionContext.policy.closeOnly && !order.isClose) {
            emit OrderFailed(
                orderId,
                executionContext.policy.oracleFrozen ? OrderFailReason.CloseOnlyOracleFrozen : OrderFailReason.CloseOnlyFad
            );
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                false,
                _failedOrderBountyPolicy(
                    _routedCloseOnlyFailure(
                        order,
                        executionContext.policy.oracleFrozen,
                        executionContext.isFadWindow,
                        executionContext.degradedMode,
                        executionContext.policy.closeOnly
                    )
                ),
                revertOnBlockedExecution
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        if (
            address(pyth) != address(0) && executionContext.policy.mevChecks
                && (block.number == order.commitBlock || oraclePublishTime <= order.commitTime + MIN_MEV_PUBLISH_DELAY)
        ) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__MevDetected();
            }
            return OrderExecutionStepResult.Break;
        }

        if (!_checkSlippage(order, executionPrice)) {
            emit OrderFailed(orderId, OrderFailReason.SlippageExceeded);
            _finalizeOrCleanupOrder(
                orderId,
                pythFee,
                false,
                OrderFailurePolicyLib.FailedOrderBountyPolicy.RefundUser,
                revertOnBlockedExecution
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        uint256 forwardedGas = gasleft() - (gasleft() / 64);
        if (forwardedGas < MIN_ENGINE_GAS) {
            if (revertOnBlockedExecution) {
                revert OrderRouter__InsufficientGas();
            }
            return OrderExecutionStepResult.Break;
        }

        uint256 vaultDepth = vault.totalAssets();
        _releaseCommittedMarginForExecution(orderId);

        (
            bool executionSucceeded,
            OrderFailReason failureReason,
            OrderFailurePolicyLib.FailedOrderBountyPolicy failureBountyPolicy
        ) = _processTypedOrderExecution(
            order,
            executionPrice,
            vaultDepth,
            oraclePublishTime,
            executionContext.oracleFrozen,
            executionContext.isFadWindow,
            executionContext.degradedMode
        );
        if (executionSucceeded) {
            emit OrderExecuted(orderId, executionPrice);
            _finalizeOrCleanupOrder(
                orderId, pythFee, true, OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull, revertOnBlockedExecution
            );
            return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
        }

        emit OrderFailed(orderId, failureReason);
        _finalizeOrCleanupOrder(orderId, pythFee, false, failureBountyPolicy, revertOnBlockedExecution);
        return revertOnBlockedExecution ? OrderExecutionStepResult.Return : OrderExecutionStepResult.Continue;
    }

    function _finalizeOrCleanupOrder(
        uint64 orderId,
        uint256 pythFee,
        bool success,
        OrderFailurePolicyLib.FailedOrderBountyPolicy failedPolicy,
        bool refundEthNow
    ) internal {
        if (refundEthNow) {
            _finalizeExecution(orderId, pythFee, success, failedPolicy);
            return;
        }
        _cleanupOrder(orderId, success, failedPolicy);
    }

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
        _skipStaleOrders(upToId, boundedPrunes);
    }

    function _resolveOraclePrice(
        bytes[] calldata pythUpdateData,
        uint256 mockFallbackPrice
    ) internal returns (uint256 price, uint64 publishTime, uint256 pythFee) {
        if (address(pyth) != address(0)) {
            if (pythUpdateData.length == 0) {
                revert OrderRouter__MissingPythUpdateData();
            }
            pythFee = pyth.getUpdateFee(pythUpdateData);
            if (msg.value < pythFee) {
                revert OrderRouter__InsufficientPythFee();
            }
            pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            uint256 minPublishTime;
            (price, minPublishTime) = _computeBasketPrice();
            publishTime = uint64(minPublishTime);
        } else {
            if (block.chainid != 31_337) {
                revert OrderRouter__MockModeDisabled();
            }
            if (pythUpdateData.length > 0) {
                price = abi.decode(pythUpdateData[0], (uint256));
            } else {
                price = mockFallbackPrice;
            }
            publishTime = uint64(block.timestamp);
        }
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                claimableEth[to] += amount;
            }
        }
    }

    function _pendingOrder(
        uint64 orderId
    ) internal view returns (OrderRecord storage record, CfdTypes.Order memory order) {
        record = _orderRecord(orderId);
        if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
            revert OrderRouter__OrderNotPending();
        }
        order = record.core;
    }

    function _getQueuedPositionView(
        bytes32 accountId
    ) internal view returns (QueuedPositionView memory queuedPosition) {
        if (engine.hasOpenPosition(accountId)) {
            queuedPosition.exists = true;
            queuedPosition.side = engine.getPositionSide(accountId);
            queuedPosition.size = engine.getPositionSize(accountId);
        }

        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            CfdTypes.Order memory order = orderRecords[orderId].core;

            if (order.isClose) {
                if (queuedPosition.exists && order.side == queuedPosition.side) {
                    queuedPosition.size =
                        queuedPosition.size > order.sizeDelta ? queuedPosition.size - order.sizeDelta : 0;
                    if (queuedPosition.size == 0) {
                        queuedPosition.exists = false;
                    }
                }
            } else if (!queuedPosition.exists || queuedPosition.size == 0) {
                queuedPosition.exists = true;
                queuedPosition.side = order.side;
                queuedPosition.size = order.sizeDelta;
            } else if (order.side == queuedPosition.side) {
                queuedPosition.size += order.sizeDelta;
            }

            orderId = orderRecords[orderId].nextPendingOrderId;
        }
    }

    function _failedOrderBountyPolicy(
        OrderFailurePolicyLib.FailureContext memory context
    ) internal pure returns (OrderFailurePolicyLib.FailedOrderBountyPolicy) {
        return OrderFailurePolicyLib.bountyPolicyForFailure(context);
    }

    function _decodeTypedOrderFailure(
        bytes memory revertData
    )
        internal
        pure
        returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose)
    {
        assembly {
            failureCategory := mload(add(revertData, 36))
            failureCode := mload(add(revertData, 68))
            isClose := mload(add(revertData, 100))
        }
    }

    function _cleanupOrder(
        uint64 orderId,
        bool success,
        OrderFailurePolicyLib.FailedOrderBountyPolicy failedPolicy
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderEscrow(orderId, success, uint8(failedPolicy));
        _deleteOrder(
            orderId,
            true,
            success ? IOrderRouterAccounting.OrderStatus.Executed : IOrderRouterAccounting.OrderStatus.Failed
        );
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee,
        bool success,
        OrderFailurePolicyLib.FailedOrderBountyPolicy failedPolicy
    ) internal {
        _consumeOrderEscrow(orderId, success, uint8(failedPolicy));
        _deleteOrder(
            orderId,
            true,
            success ? IOrderRouterAccounting.OrderStatus.Executed : IOrderRouterAccounting.OrderStatus.Failed
        );
        _sendEth(msg.sender, msg.value - pythFee);
    }

    function _routedExpiryFailure(
        CfdTypes.Order memory order
    ) internal view returns (OrderFailurePolicyLib.FailureContext memory context) {
        context.failure = OrderFailurePolicyLib.RoutedFailure({
            domain: OrderFailurePolicyLib.FailureDomain.Expired, code: 0, isClose: order.isClose
        });
        context.source = OrderFailurePolicyLib.FailureSource.Expired;
        context.oracleFrozen = _isOracleFrozen();
        context.isFad = engine.isFadWindow();
        context.degradedMode = engine.degradedMode();
        context.closeOnly = context.oracleFrozen || context.isFad;
    }

    function _routedRouterPolicyFailure(
        CfdTypes.Order memory order,
        OrderFailurePolicyLib.RouterFailureCode failureCode,
        bool oracleFrozen,
        bool isFad,
        bool degradedMode,
        bool closeOnly
    ) internal pure returns (OrderFailurePolicyLib.FailureContext memory context) {
        context.failure = OrderFailurePolicyLib.RoutedFailure({
            domain: OrderFailurePolicyLib.FailureDomain.ProtocolStateInvalidated,
            code: uint8(failureCode),
            isClose: order.isClose
        });
        context.source = OrderFailurePolicyLib.FailureSource.RouterPolicy;
        context.oracleFrozen = oracleFrozen;
        context.isFad = isFad;
        context.degradedMode = degradedMode;
        context.closeOnly = closeOnly;
    }

    function _routedFailureFromEngineRevert(
        CfdTypes.Order memory order,
        bytes memory revertData,
        bool oracleFrozen,
        bool isFad,
        bool degradedMode
    ) internal pure returns (OrderFailurePolicyLib.FailureContext memory context) {
        OrderFailurePolicyLib.RoutedFailure memory failure;
        OrderFailurePolicyLib.FailureSource source;

        if (revertData.length >= 4 && bytes4(revertData) == TYPED_ORDER_FAILURE_SELECTOR) {
            (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose) =
                _decodeTypedOrderFailure(revertData);
            failure = OrderFailurePolicyLib.RoutedFailure({
                domain: OrderFailurePolicyLib.failureDomainForExecutionCategory(failureCategory),
                code: failureCode,
                isClose: isClose
            });
            source = OrderFailurePolicyLib.FailureSource.EngineTyped;
        } else {
            failure = OrderFailurePolicyLib.RoutedFailure({
                domain: OrderFailurePolicyLib.FailureDomain.UserInvalid, code: 0, isClose: order.isClose
            });
            source = OrderFailurePolicyLib.FailureSource.UntypedRevert;
        }

        context.failure = failure;
        context.source = source;
        context.oracleFrozen = oracleFrozen;
        context.isFad = isFad;
        context.degradedMode = degradedMode;
        context.closeOnly = oracleFrozen || isFad;
    }

    /// @dev Immediate liquidation bounties still pay directly to the executing keeper wallet.
    ///      If immediate payment is unavailable or direct transfer fails, the bounty is deferred and later
    ///      settles as clearinghouse credit via `claimDeferredClearerBounty()`.
    function _payOrDeferLiquidationBounty(
        uint256 liquidationBountyUsdc
    ) internal {
        if (liquidationBountyUsdc == 0) {
            return;
        }

        CashPriorityLib.SeniorCashReservation memory reservation = CashPriorityLib.reserveFreshPayouts(
            vault.totalAssets(),
            engine.accumulatedFeesUsdc(),
            engine.totalDeferredPayoutUsdc(),
            engine.totalDeferredClearerBountyUsdc()
        );
        if (liquidationBountyUsdc > reservation.freeCashUsdc) {
            engine.recordDeferredClearerBounty(msg.sender, liquidationBountyUsdc);
            return;
        }

        try vault.payOut(msg.sender, liquidationBountyUsdc) {}
        catch {
            engine.recordDeferredClearerBounty(msg.sender, liquidationBountyUsdc);
        }
    }

    function _forfeitEscrowedOrderBountiesOnLiquidation(
        bytes32 accountId
    ) internal {
        uint256 forfeitedUsdc;
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            if (record.executionBountyUsdc > 0) {
                forfeitedUsdc += record.executionBountyUsdc;
                record.executionBountyUsdc = 0;
            }
            orderId = record.nextPendingOrderId;
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
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            uint64 nextOrderId = orderRecords[orderId].nextPendingOrderId;
            _releaseCommittedMargin(orderId);
            emit OrderFailed(orderId, OrderFailReason.AccountLiquidated);
            _deleteOrder(orderId, orderId == nextExecuteId, IOrderRouterAccounting.OrderStatus.Failed);
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

    function _quoteCloseOrderExecutionBountyUsdc() internal pure returns (uint256) {
        return CLOSE_ORDER_EXECUTION_BOUNTY_USDC;
    }

    function _commitReferencePrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }

        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _canUseCommitMarkForOpenPrefilter() internal view returns (bool) {
        uint64 lastMarkTime = engine.lastMarkTime();
        if (lastMarkTime == 0) {
            return false;
        }

        OrderOraclePolicyLib.OracleExecutionPolicy memory policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
            OrderOraclePolicyLib.OracleAction.OrderExecution,
            _isOracleFrozen(),
            engine.isFadWindow(),
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );
        return !OrderOraclePolicyLib.isStale(lastMarkTime, policy.maxStaleness, block.timestamp);
    }

    function _linkPendingOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        uint64 tailOrderId = pendingTailOrderId[accountId];
        if (tailOrderId == 0) {
            pendingHeadOrderId[accountId] = orderId;
            pendingTailOrderId[accountId] = orderId;
            return;
        }

        orderRecords[tailOrderId].nextPendingOrderId = orderId;
        orderRecords[orderId].prevPendingOrderId = tailOrderId;
        pendingTailOrderId[accountId] = orderId;
    }

    function _linkGlobalOrder(
        uint64 orderId
    ) internal {
        uint64 tailOrderId = globalTailOrderId;
        if (tailOrderId == 0) {
            nextExecuteId = orderId;
            globalTailOrderId = orderId;
            return;
        }

        orderRecords[tailOrderId].nextGlobalOrderId = orderId;
        orderRecords[orderId].prevGlobalOrderId = tailOrderId;
        globalTailOrderId = orderId;
    }

    function _unlinkGlobalOrder(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint64 prevOrderId = record.prevGlobalOrderId;
        uint64 nextOrderId = record.nextGlobalOrderId;
        uint64 headOrderId = nextExecuteId;
        uint64 tailOrderId = globalTailOrderId;

        if (headOrderId == orderId) {
            nextExecuteId = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextGlobalOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__PendingOrderLinkCorrupted();
        }

        if (tailOrderId == orderId) {
            globalTailOrderId = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevGlobalOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__PendingOrderLinkCorrupted();
        }

        record.nextGlobalOrderId = 0;
        record.prevGlobalOrderId = 0;
    }

    function _unlinkPendingOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint64 prevOrderId = record.prevPendingOrderId;
        uint64 nextOrderId = record.nextPendingOrderId;
        uint64 headOrderId = pendingHeadOrderId[accountId];
        uint64 tailOrderId = pendingTailOrderId[accountId];

        if (headOrderId == orderId) {
            pendingHeadOrderId[accountId] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextPendingOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__PendingOrderLinkCorrupted();
        }

        if (tailOrderId == orderId) {
            pendingTailOrderId[accountId] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevPendingOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__PendingOrderLinkCorrupted();
        }

        record.nextPendingOrderId = 0;
        record.prevPendingOrderId = 0;
    }

    function _reserveCloseExecutionBounty(
        bytes32 accountId,
        uint256 executionBountyUsdc
    ) internal override {
        uint256 freeSettlementUsdc = clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc;
        uint256 freeBackedBountyUsdc =
            freeSettlementUsdc > executionBountyUsdc ? executionBountyUsdc : freeSettlementUsdc;
        if (freeBackedBountyUsdc > 0) {
            clearinghouse.seizeUsdc(accountId, freeBackedBountyUsdc, address(this));
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

    function _deleteOrder(
        uint64 orderId,
        bool advanceHead,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        bytes32 accountId = record.core.accountId;
        if (accountId != bytes32(0)) {
            _unlinkPendingOrder(accountId, orderId);
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
        advanceHead;
    }

    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal {
        _releaseCommittedMargin(orderId);
    }

    /// @notice Claims ETH stuck from failed refund transfers.
    function claimEth() external {
        uint256 amount = claimableEth[msg.sender];
        if (amount == 0) {
            revert OrderRouter__NothingToClaim();
        }
        claimableEth[msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert OrderRouter__EthTransferFailed();
        }
    }

    /// @notice Claims USDC bounty refunds that could not be pushed during failed-order cleanup.
    function claimUsdc() external {
        uint256 amount = claimableUsdc[msg.sender];
        if (amount == 0) {
            revert OrderRouter__NothingToClaim();
        }
        claimableUsdc[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);
    }

    function _computeBasketPrice() internal view returns (uint256 basketPrice, uint256 minPublishTime) {
        minPublishTime = type(uint256).max;
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythFeedIds[i]);
            uint256 norm = inversions[i] ? _invertPythPrice(p.price, p.expo) : _normalizePythPrice(p.price, p.expo);

            basketPrice += (norm * quantities[i]) / (basePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);

            if (p.publishTime < minPublishTime) {
                minPublishTime = p.publishTime;
            }
        }

        if (basketPrice == 0) {
            revert OrderRouter__OraclePriceNegative();
        }
    }

    /// @dev Opens vs closes have opposing slippage directions:
    ///      BULL open wants HIGH entry (more room for drop) → exec >= target
    ///      BULL close wants LOW exit (lock in profit) → exec <= target
    ///      BEAR open wants LOW entry (more room for rise) → exec <= target
    ///      BEAR close wants HIGH exit (lock in profit) → exec >= target
    ///      targetPrice == 0 disables the check (market order).
    function _checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0) {
            return true;
        }
        if (order.isClose) {
            if (order.side == CfdTypes.Side.BULL) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.BULL) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
    }

    /// @dev Returns true only when FX markets are actually closed and Pyth feeds have stopped publishing.
    ///      Distinct from isFadWindow() which starts 3 hours earlier for margin purposes.
    ///      Uses Friday 22:00 UTC (conservative vs 21:00 EDT summer) to guarantee zero latency arbitrage.
    function _isOracleFrozen() internal view returns (bool) {
        return MarketCalendarLib.isOracleFrozen(block.timestamp, engine.fadDayOverrides(block.timestamp / 86_400));
    }

    function _isCloseOnlyWindow() internal view returns (bool) {
        return _isOracleFrozen() || engine.isFadWindow();
    }

    /// @dev Inverts a Pyth price (e.g. USD/JPY → JPY/USD) and returns 8-decimal output.
    ///      Formula: 10^(8 - expo) / price
    function _invertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert OrderRouter__OraclePriceNegative();
        }
        return 10 ** uint256(uint32(8 - expo)) / uint64(price);
    }

    /// @dev Converts a Pyth price to 8-decimal format. Scales up/down based on exponent difference from -8.
    function _normalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert OrderRouter__OraclePriceNegative();
        }
        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint32(expo + 8));
        }
        return rawPrice / (10 ** uint32(-8 - expo));
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
        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) = _resolveOraclePrice(pythUpdateData, 1e8);

        if (address(pyth) != address(0)) {
            OrderOraclePolicyLib.OracleExecutionPolicy memory policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
                OrderOraclePolicyLib.OracleAction.MarkRefresh,
                _isOracleFrozen(),
                engine.isFadWindow(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            );
            if (OrderOraclePolicyLib.isStale(oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert OrderRouter__OraclePriceTooStale();
            }
        }

        engine.updateMarkPrice(executionPrice, oraclePublishTime);

        _sendEth(msg.sender, msg.value - pythFee);
    }

    // ==========================================
    // ATOMIC LIQUIDATIONS
    // ==========================================

    /// @notice Keeper-triggered liquidation using the canonical live-market staleness policy.
    ///         Forfeits any queued-order execution escrow to the vault instead of crediting it back to trader settlement,
    ///         then pays the liquidation keeper bounty in USDC directly from the vault.
    /// @param accountId The account to liquidate (bytes32-encoded address)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeLiquidation(
        bytes32 accountId,
        bytes[] calldata pythUpdateData
    ) external payable {
        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) = _resolveOraclePrice(pythUpdateData, 1e8);

        if (address(pyth) != address(0)) {
            OrderOraclePolicyLib.OracleExecutionPolicy memory policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
                OrderOraclePolicyLib.OracleAction.Liquidation,
                _isOracleFrozen(),
                engine.isFadWindow(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            );
            if (OrderOraclePolicyLib.isStale(oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert OrderRouter__MevOraclePriceTooStale();
            }
        }

        _forfeitEscrowedOrderBountiesOnLiquidation(accountId);
        uint256 vaultDepth = vault.totalAssets();
        uint256 keeperBountyUsdc = engine.liquidatePosition(accountId, executionPrice, vaultDepth, oraclePublishTime);

        _clearLiquidatedAccountOrders(accountId);

        _payOrDeferLiquidationBounty(keeperBountyUsdc);

        _sendEth(msg.sender, msg.value - pythFee);
    }

    function _pendingHeadOrderId(
        bytes32 accountId
    ) internal view override returns (uint64) {
        return pendingHeadOrderId[accountId];
    }

    function _revertInsufficientFreeEquity() internal pure override {
        revert OrderRouter__InsufficientFreeEquity();
    }

    function _revertMarginOrderLinkCorrupted() internal pure override {
        revert OrderRouter__MarginOrderLinkCorrupted();
    }

}
