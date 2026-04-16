// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {OrderRouterAdmin} from "./OrderRouterAdmin.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IPerpsKeeper} from "./interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "./interfaces/IPerpsTraderActions.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {OrderFailurePolicyLib} from "./libraries/OrderFailurePolicyLib.sol";
import {OrderExecutionOrchestrator} from "./modules/OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "./modules/OrderOracleExecution.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev Holds only non-trader-owned keeper execution reserves. Trader collateral remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, IOrderRouterAdminHost, OrderExecutionOrchestrator {

    using SafeERC20 for IERC20;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;
    address public immutable admin;

    uint256 public maxOrderAge;
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 internal constant OPEN_ORDER_EXECUTION_BOUNTY_BPS = 1;
    uint256 internal constant MIN_OPEN_ORDER_EXECUTION_BOUNTY_USDC = 50_000;
    uint256 internal constant MAX_OPEN_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant CLOSE_ORDER_EXECUTION_BOUNTY_USDC = DecimalConstants.ONE_USDC;
    uint256 internal constant MAX_PENDING_ORDERS = 5;

    uint64 public globalTailOrderId;
    error OrderRouter__ZeroSize();
    error OrderRouter__OracleValidation(uint8 code);
    error OrderRouter__QueueState(uint8 code);
    error OrderRouter__CommitValidation(uint8 code);
    error OrderRouter__InsufficientGas();
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);

    function _onlyEngine() internal view {
        if (msg.sender != address(engine) && msg.sender != address(engine.settlementModule())) {
            _revertCommitValidation(8);
        }
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            _revertCommitValidation(8);
        }
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
    ) OrderOracleExecution(_engine, _engineLens, _vault, _pyth, _feedIds, _quantities, _basePrices, _inversions) {
        admin = address(new OrderRouterAdmin(address(this), msg.sender));
        maxOrderAge = DEFAULT_MAX_ORDER_AGE;
        if (_engine.code.length > 0) {
            USDC.forceApprove(_engine, type(uint256).max);
        }
    }

    function _revertZeroAddress() internal pure override {
        _revertOracleValidation(7);
    }

    function _revertOracleValidation(
        uint8 code
    ) internal pure {
        revert OrderRouter__OracleValidation(code);
    }

    function _revertQueueState(
        uint8 code
    ) internal pure {
        revert OrderRouter__QueueState(code);
    }

    function _revertCommitValidation(
        uint8 code
    ) internal pure {
        revert OrderRouter__CommitValidation(code);
    }

    function _revertEmptyFeeds() internal pure override {
        _revertOracleValidation(0);
    }

    function _revertLengthMismatch() internal pure override {
        _revertOracleValidation(1);
    }

    function _revertInvalidBasePrice() internal pure override {
        _revertOracleValidation(2);
    }

    function _revertInvalidWeights() internal pure override {
        _revertOracleValidation(3);
    }

    function _revertMissingPythUpdateData() internal pure override {
        _revertOracleValidation(5);
    }

    function _revertInsufficientPythFee() internal pure override {
        _revertOracleValidation(6);
    }

    function _revertMockModeDisabled() internal pure override {
        _revertOracleValidation(4);
    }

    function _revertOraclePriceTooStale() internal pure override {
        _revertOracleValidation(10);
    }

    function _revertOracleConfidenceTooWide() internal pure override {
        _revertOracleValidation(11);
    }

    function _revertOraclePublishTimeOutOfOrder() internal pure override {
        _revertOracleValidation(9);
    }

    function _revertMevOraclePriceTooStale() internal pure override {
        _revertOracleValidation(12);
    }

    function _revertOraclePriceNegative() internal pure override {
        _revertOracleValidation(8);
    }

    // ==========================================
    // ADMIN
    // ==========================================

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
            if (OrderRouterAdmin(admin).paused()) {
                revert Pausable.EnforcedPause();
            }
            if (engine.degradedMode()) {
                _revertCommitValidation(9);
            }
            if (_isCloseOnlyWindow()) {
                _revertCommitValidation(10);
            }
            if (!vault.canIncreaseRisk()) {
                if (!vault.isSeedLifecycleComplete()) {
                    _revertCommitValidation(0);
                }
                _revertCommitValidation(1);
            }
        }
        if (sizeDelta == 0) {
            revert OrderRouter__ZeroSize();
        }
        if (isClose && marginDelta > 0) {
            _revertCommitValidation(2);
        }
        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));
        uint256 executionBountyUsdc;
        if (isClose) {
            QueuedPositionView memory queuedPosition = _getQueuedPositionView(accountId);
            if (!queuedPosition.exists || queuedPosition.size == 0) {
                _revertCommitValidation(3);
            }
            if (queuedPosition.side != side) {
                _revertCommitValidation(4);
            }
            if (sizeDelta > queuedPosition.size) {
                _revertCommitValidation(5);
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
            _revertCommitValidation(7);
        }
        emit OrderCommitted(orderId, accountId, side);
    }

    /// @notice Returns the total queued escrow state for an account across all pending orders.
    function syncMarginQueue(
        bytes32 accountId
    ) external {
        _onlyEngine();
        _pruneMarginQueue(accountId);
    }

    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        OrderRecord storage record = orderRecords[orderId];
        CfdTypes.Order memory order = record.core;
        pending = IOrderRouterAccounting.PendingOrderView({
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
        nextAccountOrderId = record.nextAccountOrderId;
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
            _revertQueueState(0);
        }
        uint64 initialHeadOrderId = nextExecuteId;
        (, CfdTypes.Order memory initialHeadOrder) = _pendingOrder(initialHeadOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData, initialHeadOrder.targetPrice);

        _skipStaleOrders(orderId, update.executionPrice, update.oraclePublishTime);
        if (nextExecuteId == 0) {
            _revertQueueState(0);
        }
        if (orderId < nextExecuteId) {
            orderId = nextExecuteId;
        }
        if (orderId != nextExecuteId) {
            _revertQueueState(1);
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
            _revertQueueState(0);
        }
        if (maxOrderId < nextExecuteId) {
            _revertQueueState(2);
        }
        if (maxOrderId >= nextCommitId) {
            _revertQueueState(3);
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
        _revertQueueState(4);
    }

    function _maxOrderAge() internal view override returns (uint256) {
        return maxOrderAge;
    }

    function _revertNoOrdersToExecute() internal pure override {
        _revertQueueState(0);
    }

    function _revertInsufficientGas() internal pure override {
        revert OrderRouter__InsufficientGas();
    }

    function _revertMevDetected() internal pure override {
        _revertOracleValidation(13);
    }

    function _revertCloseOnlyMode() internal pure override {
        _revertCommitValidation(10);
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal override {
        if (amount > 0) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                OrderRouterAdmin(admin).creditClaimableEth(to, amount);
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
        try engine.reserveCloseOrderExecutionBounty(accountId, executionBountyUsdc, address(this)) {}
        catch {
            _revertCommitValidation(6);
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

    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external {
        _onlyAdmin();
        maxOrderAge = config.maxOrderAge;
        orderExecutionStalenessLimit = config.orderExecutionStalenessLimit;
        liquidationStalenessLimit = config.liquidationStalenessLimit;
        pythMaxConfidenceRatioBps = config.pythMaxConfidenceRatioBps;
    }

    function _nextCommitId() internal view override returns (uint64) {
        return nextCommitId;
    }

    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal override {
        _releaseCommittedMargin(orderId);
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
        _revertCommitValidation(6);
    }

    function _revertMarginOrderLinkCorrupted() internal pure override {
        _revertQueueState(5);
    }

    function _revertPendingOrderLinkCorrupted() internal pure override {
        _revertQueueState(6);
    }

}
