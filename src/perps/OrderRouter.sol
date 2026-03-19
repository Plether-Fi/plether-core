// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OrderOraclePolicyLib} from "./libraries/OrderOraclePolicyLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev Holds only non-trader-owned keeper execution reserves. Trader collateral remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is Ownable2Step, Pausable, IOrderRouterAccounting {

    using SafeERC20 for IERC20;

    enum OrderStatus {
        None,
        Pending,
        Executed,
        Failed
    }

    /// @notice Canonical per-order lifecycle, escrow, and queue-link state.
    struct OrderRecord {
        CfdTypes.Order core;
        OrderStatus status;
        uint256 executionBountyUsdc;
        uint64 nextPendingOrderId;
        uint64 prevPendingOrderId;
        uint64 nextMarginOrderId;
        uint64 prevMarginOrderId;
        bool inMarginQueue;
        bool bountyDeferred;
    }

    struct AccountEscrow {
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        uint256 pendingOrderCount;
    }

    struct AccountOrderSummary {
        uint256 pendingOrderCount;
        uint256 pendingCloseSize;
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        bool hasTerminalCloseQueued;
    }

    struct PendingOrderView {
        uint64 orderId;
        bool isClose;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        uint64 commitTime;
        uint64 commitBlock;
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
    }

    ICfdEngine public immutable engine;
    ICfdVault internal immutable vault;
    IMarginClearinghouse internal immutable clearinghouse;
    IPyth public pyth;
    IERC20 public immutable USDC;
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
    uint256 internal constant OPEN_ORDER_EXECUTION_BOUNTY_BPS = 1;
    uint256 internal constant MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC = 50_000;
    uint256 internal constant MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant CLOSE_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 public constant MAX_PENDING_ORDERS = 5;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;

    mapping(uint64 => OrderRecord) internal orderRecords;
    mapping(address => uint256) public claimableEth;
    mapping(bytes32 => uint256) public pendingOrderCounts;
    mapping(bytes32 => uint256) public pendingCloseSize;
    mapping(bytes32 => uint64) public pendingHeadOrderId;
    mapping(bytes32 => uint64) public pendingTailOrderId;
    mapping(bytes32 => uint64) public marginHeadOrderId;
    mapping(bytes32 => uint64) public marginTailOrderId;

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

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, string reason);

    enum FailedOrderBountyPolicy {
        None,
        ClearerFull,
        RefundUser
    }

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
    ) Ownable(msg.sender) {
        engine = ICfdEngine(_engine);
        vault = ICfdVault(_vault);
        clearinghouse = _engine.code.length == 0
            ? IMarginClearinghouse(address(0))
            : IMarginClearinghouse(ICfdEngine(_engine).clearinghouse());
        pyth = IPyth(_pyth);
        USDC = _engine.code.length == 0 ? IERC20(address(0)) : engine.USDC();
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
        if (!isClose) {
            _requireNotPaused();
            if (engine.degradedMode()) {
                revert OrderRouter__DegradedMode();
            }
            if (_isCloseOnlyWindow()) {
                revert OrderRouter__CloseOnlyMode();
            }
        }
        if (sizeDelta == 0) {
            revert OrderRouter__ZeroSize();
        }
        if (isClose && marginDelta > 0) {
            revert OrderRouter__CloseMarginDeltaNotAllowed();
        }
        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));
        if (pendingOrderCounts[accountId] >= MAX_PENDING_ORDERS) {
            revert OrderRouter__TooManyPendingOrders();
        }
        if (isClose && !engine.hasOpenPosition(accountId) && pendingOrderCounts[accountId] == 0) {
            revert OrderRouter__NoOpenPosition();
        }
        if (isClose && engine.hasOpenPosition(accountId)) {
            if (engine.getPositionSide(accountId) != side) {
                revert OrderRouter__CloseSideMismatch();
            }
            uint256 positionSize = engine.getPositionSize(accountId);
            if (sizeDelta > positionSize) {
                revert OrderRouter__CloseSizeExceedsPosition();
            }
            if (pendingCloseSize[accountId] + sizeDelta > positionSize) {
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
        record.status = OrderStatus.Pending;
        if (isClose) {
            pendingCloseSize[accountId] += sizeDelta;
        }
        _linkPendingOrder(accountId, orderId);
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

    function orders(
        uint64 orderId
    ) external view returns (bytes32, uint256, uint256, uint256, uint64, uint64, uint64, CfdTypes.Side, bool) {
        CfdTypes.Order memory order = orderRecords[orderId].core;
        return (
            order.accountId,
            order.sizeDelta,
            order.marginDelta,
            order.targetPrice,
            order.commitTime,
            order.commitBlock,
            order.orderId,
            order.side,
            order.isClose
        );
    }

    function committedMargins(
        uint64 orderId
    ) external view returns (uint256) {
        return clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
    }

    function executionBountyReserves(
        uint64 orderId
    ) external view returns (uint256) {
        OrderRecord storage record = orderRecords[orderId];
        return record.bountyDeferred ? 0 : record.executionBountyUsdc;
    }

    function isInMarginQueue(
        uint64 orderId
    ) external view returns (bool) {
        return orderRecords[orderId].inMarginQueue;
    }

    function getOrderRecord(
        uint64 orderId
    ) external view returns (OrderRecord memory) {
        return orderRecords[orderId];
    }

    /// @notice Returns the total queued escrow state for an account across all pending orders.
    function getAccountEscrow(
        bytes32 accountId
    ) external view returns (IOrderRouterAccounting.AccountEscrowView memory escrow) {
        escrow.committedMarginUsdc =
        clearinghouse.getAccountReservationSummary(accountId).activeCommittedOrderMarginUsdc;
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            if (!record.bountyDeferred) {
                escrow.executionBountyUsdc += record.executionBountyUsdc;
            }
            escrow.pendingOrderCount++;
            orderId = record.nextPendingOrderId;
        }
    }

    function syncMarginQueue(
        bytes32 accountId
    ) external onlyEngine {
        _pruneMarginQueue(accountId);
    }

    function getAccountOrderSummary(
        bytes32 accountId
    ) external view returns (AccountOrderSummary memory summary) {
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;
            summary.pendingOrderCount++;
            if (order.isClose) {
                summary.pendingCloseSize += order.sizeDelta;
            }
            summary.committedMarginUsdc += clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
            summary.executionBountyUsdc += record.executionBountyUsdc;
            if (order.isClose) {
                summary.hasTerminalCloseQueued = true;
            }
            orderId = record.nextPendingOrderId;
        }
    }

    function getMarginReservationIds(
        bytes32 accountId
    ) external view returns (uint64[] memory orderIds) {
        uint64 cursor = marginHeadOrderId[accountId];
        uint256 count;
        while (cursor != 0) {
            count++;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }

        orderIds = new uint64[](count);
        cursor = marginHeadOrderId[accountId];
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = cursor;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }
    }

    function getPendingOrdersForAccount(
        bytes32 accountId
    ) external view returns (PendingOrderView[] memory pending) {
        pending = new PendingOrderView[](pendingOrderCounts[accountId]);
        uint256 index;
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;
            pending[index] = PendingOrderView({
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

    /// @notice Keeper executes the next order in strict FIFO sequence.
    ///         Validates oracle freshness and publish-time ordering against the order commit,
    ///         checks slippage, then delegates to CfdEngine. The executor is paid from the
    ///         order's router-custodied execution bounty whether the order fills or is invalid/expired,
    ///         so the queue remains economically serviceable as well as un-brickable.
    /// @param orderId Must equal nextExecuteId (stale orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        _skipStaleOrders(orderId);
        if (orderId != nextExecuteId) {
            revert OrderRouter__FIFOViolation();
        }
        (, CfdTypes.Order memory order) = _pendingOrder(orderId);
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, "Order expired");
            _finalizeExecution(orderId, 0, false, FailedOrderBountyPolicy.ClearerFull);
            return;
        }

        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) =
            _resolveOraclePrice(pythUpdateData, order.targetPrice);

        if (address(pyth) != address(0)) {
            OrderOraclePolicyLib.OracleExecutionPolicy memory policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
                OrderOraclePolicyLib.OracleAction.OrderExecution,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.fadMaxStaleness()
            );
            if (policy.closeOnly && !order.isClose) {
                emit OrderFailed(
                    orderId, policy.oracleFrozen ? "Oracle frozen: close-only mode" : "FAD: close-only mode"
                );
                _finalizeExecution(orderId, pythFee, false, FailedOrderBountyPolicy.RefundUser);
                return;
            }

            if (OrderOraclePolicyLib.isStale(oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert OrderRouter__OraclePriceTooStale();
            }

            if (policy.mevChecks && block.number == order.commitBlock) {
                revert OrderRouter__MevDetected();
            }

            if (policy.mevChecks && oraclePublishTime <= order.commitTime + MIN_MEV_PUBLISH_DELAY) {
                revert OrderRouter__MevDetected();
            }
        }

        uint256 capPrice = engine.CAP_PRICE();
        if (executionPrice > capPrice) {
            executionPrice = capPrice;
        }

        if (!_checkSlippage(order, executionPrice)) {
            emit OrderFailed(orderId, "Slippage tolerance exceeded");
            _finalizeExecution(orderId, pythFee, false, _failedOrderBountyPolicy(order));
            return;
        }

        uint256 vaultDepth = vault.totalAssets();

        uint256 forwardedGas = gasleft() - (gasleft() / 64);
        if (forwardedGas < MIN_ENGINE_GAS) {
            revert OrderRouter__InsufficientGas();
        }

        _releaseCommittedMarginForExecution(orderId);

        try engine.processOrder(order, executionPrice, vaultDepth, oraclePublishTime) {
            emit OrderExecuted(orderId, executionPrice);
        } catch Error(string memory reason) {
            emit OrderFailed(orderId, reason);
            _finalizeExecution(orderId, pythFee, false, _failedOrderBountyPolicy(order));
            return;
        } catch {
            emit OrderFailed(orderId, "Engine Math Panic");
            _finalizeExecution(orderId, pythFee, false, _failedOrderBountyPolicy(order));
            return;
        }

        _finalizeExecution(orderId, pythFee, true, FailedOrderBountyPolicy.ClearerFull);
    }

    /// @notice Executes all pending orders up to maxOrderId against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Aggregates reserved USDC
    ///         execution bounties across processed orders and refunds excess ETH in a single transfer.
    /// @param maxOrderId Inclusive upper bound of order IDs to process (must be committed)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        if (maxOrderId < nextExecuteId) {
            revert OrderRouter__NoOrdersToExecute();
        }
        if (maxOrderId >= nextCommitId) {
            revert OrderRouter__MaxOrderIdNotCommitted();
        }

        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) = _resolveOraclePrice(pythUpdateData, 1e8);

        OrderOraclePolicyLib.OracleExecutionPolicy memory policy;
        if (address(pyth) != address(0)) {
            policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
                OrderOraclePolicyLib.OracleAction.OrderExecution,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.fadMaxStaleness()
            );
            if (OrderOraclePolicyLib.isStale(oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert OrderRouter__OraclePriceTooStale();
            }
        }

        uint256 capPrice = engine.CAP_PRICE();
        uint256 clampedPrice = executionPrice > capPrice ? capPrice : executionPrice;

        while (nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != OrderStatus.Pending) {
                nextExecuteId++;
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                emit OrderFailed(orderId, "Order expired");
                _cleanupOrder(orderId, false, FailedOrderBountyPolicy.ClearerFull);
                continue;
            }

            if (policy.closeOnly && !order.isClose) {
                emit OrderFailed(
                    orderId, policy.oracleFrozen ? "Oracle frozen: close-only mode" : "FAD: close-only mode"
                );
                _cleanupOrder(orderId, false, FailedOrderBountyPolicy.RefundUser);
                continue;
            }

            if (
                address(pyth) != address(0) && policy.mevChecks
                    // Stop at the first same-block order so newer queued orders remain pending too.
                    && (block.number == order.commitBlock
                        || oraclePublishTime <= order.commitTime + MIN_MEV_PUBLISH_DELAY)
            ) {
                break;
            }

            if (!_checkSlippage(order, clampedPrice)) {
                emit OrderFailed(orderId, "Slippage tolerance exceeded");
                _cleanupOrder(orderId, false, _failedOrderBountyPolicy(order));
                continue;
            }

            uint256 vaultDepth = vault.totalAssets();

            uint256 forwardedGas = gasleft() - (gasleft() / 64);
            if (forwardedGas < MIN_ENGINE_GAS) {
                break;
            }

            _releaseCommittedMarginForExecution(orderId);

            try engine.processOrder(order, clampedPrice, vaultDepth, oraclePublishTime) {
                emit OrderExecuted(orderId, clampedPrice);
                _cleanupOrder(orderId, true, FailedOrderBountyPolicy.ClearerFull);
            } catch Error(string memory reason) {
                emit OrderFailed(orderId, reason);
                _cleanupOrder(orderId, false, _failedOrderBountyPolicy(order));
            } catch {
                emit OrderFailed(orderId, "Engine Math Panic");
                _cleanupOrder(orderId, false, _failedOrderBountyPolicy(order));
            }
        }

        _sendEth(msg.sender, msg.value - pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _skipStaleOrders(
        uint64 upToId
    ) internal {
        uint256 age = maxOrderAge;
        if (age == 0) {
            return;
        }
        while (nextExecuteId < upToId) {
            uint64 headId = nextExecuteId;
            OrderRecord storage record = _orderRecord(headId);
            CfdTypes.Order memory order = record.core;
            if (record.status != OrderStatus.Pending) {
                nextExecuteId++;
                continue;
            }
            if (block.timestamp - order.commitTime <= age) {
                break;
            }
            emit OrderFailed(headId, "Order expired");
            _cleanupOrder(headId, false, FailedOrderBountyPolicy.ClearerFull);
        }
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

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRecord storage record) {
        return orderRecords[orderId];
    }

    function _pendingOrder(
        uint64 orderId
    ) internal view returns (OrderRecord storage record, CfdTypes.Order memory order) {
        record = _orderRecord(orderId);
        if (record.status != OrderStatus.Pending) {
            revert OrderRouter__OrderNotPending();
        }
        order = record.core;
    }

    function _failedOrderBountyPolicy(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderBountyPolicy) {
        order;
        return FailedOrderBountyPolicy.ClearerFull;
    }

    function _cleanupOrder(
        uint64 orderId,
        bool success,
        FailedOrderBountyPolicy failedPolicy
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderEscrow(orderId, success, failedPolicy);
        _deleteOrder(orderId, true, success ? OrderStatus.Executed : OrderStatus.Failed);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee,
        bool success,
        FailedOrderBountyPolicy failedPolicy
    ) internal {
        _consumeOrderEscrow(orderId, success, failedPolicy);
        _deleteOrder(orderId, true, success ? OrderStatus.Executed : OrderStatus.Failed);
        _sendEth(msg.sender, msg.value - pythFee);
    }

    function _payOrDeferLiquidationBounty(
        uint256 liquidationBountyUsdc
    ) internal {
        if (liquidationBountyUsdc == 0) {
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
                if (!record.bountyDeferred) {
                    forfeitedUsdc += record.executionBountyUsdc;
                }
                record.executionBountyUsdc = 0;
                record.bountyDeferred = false;
            }
            orderId = record.nextPendingOrderId;
        }

        if (forfeitedUsdc == 0) {
            return;
        }

        USDC.safeTransfer(address(vault), forfeitedUsdc);
    }

    function _clearLiquidatedAccountOrders(
        bytes32 accountId
    ) internal {
        uint64 orderId = pendingHeadOrderId[accountId];
        while (orderId != 0) {
            uint64 nextOrderId = orderRecords[orderId].nextPendingOrderId;
            _releaseCommittedMargin(orderId);
            emit OrderFailed(orderId, "Account liquidated");
            _deleteOrder(orderId, orderId == nextExecuteId, OrderStatus.Failed);
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

    function _collectExecutionBounty(
        uint64 orderId
    ) internal returns (uint256 executionBountyUsdc) {
        OrderRecord storage record = _orderRecord(orderId);
        executionBountyUsdc = record.executionBountyUsdc;
        if (executionBountyUsdc == 0) {
            return 0;
        }
        record.executionBountyUsdc = 0;
        if (record.bountyDeferred) {
            record.bountyDeferred = false;
            IMarginClearinghouse ch = IMarginClearinghouse(engine.clearinghouse());
            if (ch.getFreeSettlementBalanceUsdc(record.core.accountId) >= executionBountyUsdc) {
                ch.seizeUsdc(record.core.accountId, executionBountyUsdc, address(this));
                USDC.safeTransfer(msg.sender, executionBountyUsdc);
            } else {
                executionBountyUsdc = 0;
            }
        } else {
            USDC.safeTransfer(msg.sender, executionBountyUsdc);
        }
    }

    function _refundExecutionBounty(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint256 bounty = record.executionBountyUsdc;
        if (bounty > 0) {
            record.executionBountyUsdc = 0;
            address trader = address(uint160(uint256(record.core.accountId)));
            USDC.safeTransfer(trader, bounty);
        }
    }

    function _commitReferencePrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }

        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _releaseCommittedMargin(
        uint64 orderId
    ) internal {
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        if (reservation.status == IMarginClearinghouse.ReservationStatus.Active) {
            clearinghouse.releaseOrderReservation(orderId);
        }
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

    function _linkMarginOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.inMarginQueue) {
            return;
        }

        uint64 tailOrderId = marginTailOrderId[accountId];
        if (tailOrderId == 0) {
            marginHeadOrderId[accountId] = orderId;
            marginTailOrderId[accountId] = orderId;
        } else {
            orderRecords[tailOrderId].nextMarginOrderId = orderId;
            record.prevMarginOrderId = tailOrderId;
            marginTailOrderId[accountId] = orderId;
        }

        record.inMarginQueue = true;
    }

    function _unlinkMarginOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (!record.inMarginQueue) {
            return;
        }

        uint64 prevOrderId = record.prevMarginOrderId;
        uint64 nextOrderId = record.nextMarginOrderId;
        uint64 headOrderId = marginHeadOrderId[accountId];
        uint64 tailOrderId = marginTailOrderId[accountId];

        if (headOrderId == orderId) {
            marginHeadOrderId[accountId] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextMarginOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__MarginOrderLinkCorrupted();
        }

        if (tailOrderId == orderId) {
            marginTailOrderId[accountId] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevMarginOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__MarginOrderLinkCorrupted();
        }

        record.nextMarginOrderId = 0;
        record.prevMarginOrderId = 0;
        record.inMarginQueue = false;
    }

    function _reserveExecutionBounty(
        bytes32 accountId,
        uint64 orderId,
        uint256 executionBountyUsdc,
        bool isClose
    ) internal {
        if (executionBountyUsdc == 0) {
            return;
        }
        if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) >= executionBountyUsdc) {
            clearinghouse.seizeUsdc(accountId, executionBountyUsdc, address(this));
            orderRecords[orderId].executionBountyUsdc = executionBountyUsdc;
        } else if (isClose) {
            orderRecords[orderId].executionBountyUsdc = executionBountyUsdc;
            orderRecords[orderId].bountyDeferred = true;
        } else {
            revert OrderRouter__InsufficientFreeEquity();
        }
    }

    function _reserveCommittedMargin(
        bytes32 accountId,
        uint64 orderId,
        bool isClose,
        uint256 marginDelta
    ) internal {
        if (isClose || marginDelta == 0) {
            return;
        }
        clearinghouse.reserveCommittedOrderMargin(accountId, orderId, marginDelta);
        _linkMarginOrder(accountId, orderId);
    }

    function _consumeOrderEscrow(
        uint64 orderId,
        bool success,
        FailedOrderBountyPolicy failedPolicy
    ) internal returns (uint256 executionBountyUsdc) {
        if (success) {
            _clearCommittedMargin(orderId);
            _collectExecutionBounty(orderId);
        } else {
            _releaseCommittedMargin(orderId);
            if (failedPolicy == FailedOrderBountyPolicy.ClearerFull) {
                _collectExecutionBounty(orderId);
            } else if (failedPolicy == FailedOrderBountyPolicy.RefundUser) {
                _refundExecutionBounty(orderId);
            }
        }
        return 0;
    }

    function _deleteOrder(
        uint64 orderId,
        bool advanceHead,
        OrderStatus terminalStatus
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        bytes32 accountId = record.core.accountId;
        if (accountId != bytes32(0)) {
            _unlinkPendingOrder(accountId, orderId);
            _unlinkMarginOrder(accountId, orderId);
        }
        record.status = terminalStatus;
        if (accountId != bytes32(0) && pendingOrderCounts[accountId] > 0) {
            pendingOrderCounts[accountId]--;
        }
        if (accountId != bytes32(0) && record.core.isClose && pendingCloseSize[accountId] >= record.core.sizeDelta) {
            pendingCloseSize[accountId] -= record.core.sizeDelta;
        }
        if (advanceHead) {
            nextExecuteId++;
        }
    }

    function _clearCommittedMargin(
        uint64 orderId
    ) internal {
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        if (reservation.status == IMarginClearinghouse.ReservationStatus.Active && reservation.remainingAmountUsdc > 0)
        {
            clearinghouse.consumeOrderReservation(orderId, reservation.remainingAmountUsdc);
        }
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

    /// @notice Keeper-triggered liquidation with stricter staleness (≤ 15s).
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

    function _pruneMarginQueue(
        bytes32 accountId
    ) internal {
        uint64 orderId = marginHeadOrderId[accountId];
        while (orderId != 0) {
            uint256 remainingCommittedMarginUsdc = clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
            if (remainingCommittedMarginUsdc > 0) {
                break;
            }

            uint64 nextOrderId = orderRecords[orderId].nextMarginOrderId;
            _unlinkMarginOrder(accountId, orderId);
            orderId = nextOrderId;
        }
    }

}
