// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {OrderOraclePolicyLib} from "./libraries/OrderOraclePolicyLib.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev No longer holds margin escrow. Users deposit to MarginClearinghouse directly.
/// @custom:security-contact contact@plether.com
contract OrderRouter is Ownable2Step, Pausable {

    using SafeERC20 for IERC20;

    struct AccountEscrow {
        uint256 committedMarginUsdc;
        uint256 keeperReserveUsdc;
        uint256 pendingOrderCount;
    }

    ICfdEngine public engine;
    ICfdVault public vault;
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
    uint256 internal constant ORDER_KEEPER_BPS = 1;
    uint256 internal constant MIN_ORDER_KEEPER_FEE_USDC = 50_000;
    uint256 internal constant MAX_ORDER_KEEPER_FEE_USDC = DecimalConstants.ONE_USDC;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;

    mapping(uint64 => CfdTypes.Order) public orders;
    mapping(uint64 => uint256) public committedMargins;
    mapping(uint64 => uint256) public keeperFeeReserves;
    mapping(address => uint256) public claimableEth;
    mapping(bytes32 => uint256) public pendingOrderCounts;

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
    error OrderRouter__InsufficientFreeEquity();

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, string reason);

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _vault CfdVault used for vault depth queries and keeper payouts
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
    ///         For opens/increases with positive marginDelta, margin is locked immediately.
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
        }
        if (sizeDelta == 0) {
            revert OrderRouter__ZeroSize();
        }
        if (isClose && marginDelta > 0) {
            revert OrderRouter__CloseMarginDeltaNotAllowed();
        }
        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));
        if (isClose && !engine.hasOpenPosition(accountId) && pendingOrderCounts[accountId] == 0) {
            revert OrderRouter__NoOpenPosition();
        }
        uint256 keeperFeeReserveUsdc = isClose ? 0 : _quoteOrderKeeperFeeUsdc(sizeDelta, _commitReferencePrice());

        uint64 orderId = nextCommitId++;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engine.clearinghouse());

        _reserveKeeperFee(clearinghouse, accountId, orderId, keeperFeeReserveUsdc);
        _reserveCommittedMargin(clearinghouse, accountId, orderId, isClose, marginDelta);

        orders[orderId] = CfdTypes.Order({
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
        pendingOrderCounts[accountId]++;
        emit OrderCommitted(orderId, accountId, side);
    }

    /// @notice Quotes the reserved USDC keeper fee for a new order using the latest engine mark price.
    /// @dev Falls back to 1.00 USD if the engine has not observed a mark yet. Result is floored at
    ///      0.05 USDC and capped at 1 USDC for non-close intents.
    /// @param sizeDelta Order size in 18-decimal notional units
    /// @return keeperFeeUsdc Reserved keeper fee in 6-decimal USDC units
    function quoteKeeperFeeUsdc(
        uint256 sizeDelta
    ) external view returns (uint256 keeperFeeUsdc) {
        return _quoteOrderKeeperFeeUsdc(sizeDelta, _commitReferencePrice());
    }

    /// @notice Returns the total escrowed state for an account across all queued orders.
    function getAccountEscrow(
        bytes32 accountId
    ) external view returns (AccountEscrow memory escrow) {
        uint64 maxOrderId = nextCommitId;
        for (uint64 orderId = nextExecuteId; orderId < maxOrderId; orderId++) {
            CfdTypes.Order memory order = orders[orderId];
            if (order.accountId != accountId || order.sizeDelta == 0) {
                continue;
            }
            escrow.committedMarginUsdc += committedMargins[orderId];
            escrow.keeperReserveUsdc += keeperFeeReserves[orderId];
            escrow.pendingOrderCount++;
        }
    }

    // ==========================================
    // STEP 2: THE REVEAL (Keeper Execution)
    // ==========================================

    /// @notice Keeper executes the next order in strict FIFO sequence.
    ///         Validates oracle freshness (publishTime > commitTime, age ≤ 60s),
    ///         checks slippage, then delegates to CfdEngine. The keeper is paid from the
    ///         order's reserved USDC fee whether the order fills or is invalid/expired,
    ///         so the queue remains economically serviceable as well as un-brickable.
    /// @param orderId Must equal nextExecuteId (stale orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        uint256 reservedKeeperRewardUsdc = _skipStaleOrders(orderId);
        uint256 vaultKeeperRewardUsdc;
        if (orderId != nextExecuteId) {
            revert OrderRouter__FIFOViolation();
        }
        CfdTypes.Order memory order = orders[orderId];
        if (order.sizeDelta == 0) {
            revert OrderRouter__OrderNotPending();
        }
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, "Order expired");
            _finalizeExecution(orderId, 0, false, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), 0);
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
                emit OrderFailed(orderId, policy.oracleFrozen ? "Oracle frozen: close-only mode" : "FAD: close-only mode");
                _finalizeExecution(orderId, pythFee, false, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), 0);
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
            _finalizeExecution(orderId, pythFee, false, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), 0);
            return;
        }

        uint256 vaultDepth = vault.totalAssets();

        uint256 forwardedGas = gasleft() - (gasleft() / 64);
        if (forwardedGas < MIN_ENGINE_GAS) {
            revert OrderRouter__InsufficientGas();
        }

        _releaseCommittedMarginForExecution(orderId);

        try engine.processOrder(order, executionPrice, vaultDepth, oraclePublishTime) returns (int256 closeKeeperRewardUsdc) {
            if (closeKeeperRewardUsdc > 0) {
                vaultKeeperRewardUsdc += uint256(closeKeeperRewardUsdc);
            }
            emit OrderExecuted(orderId, executionPrice);
        } catch Error(string memory reason) {
            emit OrderFailed(orderId, reason);
            _finalizeExecution(orderId, pythFee, false, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), 0);
            return;
        } catch {
            emit OrderFailed(orderId, "Engine Math Panic");
            _finalizeExecution(orderId, pythFee, false, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), 0);
            return;
        }

        _finalizeExecution(orderId, pythFee, true, reservedKeeperRewardUsdc + _collectKeeperFeeReserve(orderId), vaultKeeperRewardUsdc);
    }

    /// @notice Executes all pending orders up to maxOrderId against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Aggregates reserved USDC
    ///         keeper fees across processed orders and refunds excess ETH in a single transfer.
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

        uint256 totalReservedKeeperRewardUsdc;
        uint256 totalVaultKeeperRewardUsdc;

        while (nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            CfdTypes.Order memory order = orders[orderId];

            if (order.sizeDelta == 0) {
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                emit OrderFailed(orderId, "Order expired");
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
                continue;
            }

            if (policy.closeOnly && !order.isClose) {
                emit OrderFailed(orderId, policy.oracleFrozen ? "Oracle frozen: close-only mode" : "FAD: close-only mode");
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
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
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
                continue;
            }

            uint256 vaultDepth = vault.totalAssets();

            uint256 forwardedGas = gasleft() - (gasleft() / 64);
            if (forwardedGas < MIN_ENGINE_GAS) {
                revert OrderRouter__InsufficientGas();
            }

            _releaseCommittedMarginForExecution(orderId);

            try engine.processOrder(order, clampedPrice, vaultDepth, oraclePublishTime) returns (int256 closeKeeperRewardUsdc) {
                if (closeKeeperRewardUsdc > 0) {
                    totalVaultKeeperRewardUsdc += uint256(closeKeeperRewardUsdc);
                }
                emit OrderExecuted(orderId, clampedPrice);
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, true);
            } catch Error(string memory reason) {
                emit OrderFailed(orderId, reason);
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
            } catch {
                emit OrderFailed(orderId, "Engine Math Panic");
                totalReservedKeeperRewardUsdc += _cleanupOrder(orderId, false);
            }
        }

        if (totalReservedKeeperRewardUsdc > 0) {
            USDC.safeTransfer(msg.sender, totalReservedKeeperRewardUsdc);
        }
        if (totalVaultKeeperRewardUsdc > 0) {
            vault.payOut(msg.sender, totalVaultKeeperRewardUsdc);
        }

        _sendEth(msg.sender, msg.value - pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _skipStaleOrders(
        uint64 upToId
    ) internal returns (uint256 totalKeeperRewardUsdc) {
        uint256 age = maxOrderAge;
        if (age == 0) {
            return 0;
        }
        while (nextExecuteId < upToId) {
            uint64 headId = nextExecuteId;
            CfdTypes.Order memory order = orders[headId];
            if (order.sizeDelta == 0) {
                nextExecuteId++;
                continue;
            }
            if (block.timestamp - order.commitTime <= age) {
                break;
            }
            emit OrderFailed(headId, "Order expired");
            totalKeeperRewardUsdc += _cleanupOrder(headId, false);
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

    function _cleanupOrder(
        uint64 orderId,
        bool success
    ) internal returns (uint256 keeperRewardUsdc) {
        keeperRewardUsdc = _consumeOrderEscrow(orderId, success);
        _deleteOrder(orderId);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee,
        bool success,
        uint256 reservedKeeperRewardUsdc,
        uint256 vaultKeeperRewardUsdc
    ) internal {
        _consumeOrderEscrow(orderId, success);
        _deleteOrder(orderId);

        if (reservedKeeperRewardUsdc > 0) {
            USDC.safeTransfer(msg.sender, reservedKeeperRewardUsdc);
        }
        if (vaultKeeperRewardUsdc > 0) {
            vault.payOut(msg.sender, vaultKeeperRewardUsdc);
        }
        _sendEth(msg.sender, msg.value - pythFee);
    }

    function _quoteOrderKeeperFeeUsdc(
        uint256 sizeDelta,
        uint256 price
    ) internal pure returns (uint256) {
        uint256 notionalUsdc = (sizeDelta * price) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        uint256 keeperRewardUsdc = (notionalUsdc * ORDER_KEEPER_BPS) / 10_000;
        if (keeperRewardUsdc < MIN_ORDER_KEEPER_FEE_USDC) {
            keeperRewardUsdc = MIN_ORDER_KEEPER_FEE_USDC;
        }
        return keeperRewardUsdc > MAX_ORDER_KEEPER_FEE_USDC ? MAX_ORDER_KEEPER_FEE_USDC : keeperRewardUsdc;
    }

    function _collectKeeperFeeReserve(
        uint64 orderId
    ) internal returns (uint256 keeperRewardUsdc) {
        keeperRewardUsdc = keeperFeeReserves[orderId];
        if (keeperRewardUsdc > 0) {
            delete keeperFeeReserves[orderId];
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

    function _unlockCommittedMargin(
        uint64 orderId
    ) internal {
        uint256 amount = committedMargins[orderId];
        if (amount == 0) {
            return;
        }
        delete committedMargins[orderId];
        bytes32 accountId = orders[orderId].accountId;
        IMarginClearinghouse(engine.clearinghouse()).unlockMargin(accountId, amount);
    }

    function _reserveKeeperFee(
        IMarginClearinghouse clearinghouse,
        bytes32 accountId,
        uint64 orderId,
        uint256 keeperFeeReserveUsdc
    ) internal {
        if (keeperFeeReserveUsdc == 0) {
            return;
        }
        if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) < keeperFeeReserveUsdc) {
            revert OrderRouter__InsufficientFreeEquity();
        }
        clearinghouse.seizeAsset(accountId, address(USDC), keeperFeeReserveUsdc, address(this));
        keeperFeeReserves[orderId] = keeperFeeReserveUsdc;
    }

    function _reserveCommittedMargin(
        IMarginClearinghouse clearinghouse,
        bytes32 accountId,
        uint64 orderId,
        bool isClose,
        uint256 marginDelta
    ) internal {
        if (isClose || marginDelta == 0) {
            return;
        }
        clearinghouse.lockMargin(accountId, marginDelta);
        committedMargins[orderId] = marginDelta;
    }

    function _consumeOrderEscrow(
        uint64 orderId,
        bool success
    ) internal returns (uint256 keeperRewardUsdc) {
        if (success) {
            _clearCommittedMargin(orderId);
        } else {
            _unlockCommittedMargin(orderId);
        }
        return _collectKeeperFeeReserve(orderId);
    }

    function _deleteOrder(
        uint64 orderId
    ) internal {
        bytes32 accountId = orders[orderId].accountId;
        delete orders[orderId];
        if (accountId != bytes32(0) && pendingOrderCounts[accountId] > 0) {
            pendingOrderCounts[accountId]--;
        }
        nextExecuteId++;
    }

    function _clearCommittedMargin(
        uint64 orderId
    ) internal {
        if (committedMargins[orderId] > 0) {
            delete committedMargins[orderId];
        }
    }

    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal {
        uint256 amount = committedMargins[orderId];
        if (amount == 0) {
            return;
        }
        delete committedMargins[orderId];
        bytes32 accountId = orders[orderId].accountId;
        IMarginClearinghouse(engine.clearinghouse()).unlockMargin(accountId, amount);
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
        uint256 dayOfWeek = ((block.timestamp / 86_400) + 4) % 7;
        uint256 hourOfDay = (block.timestamp % 86_400) / 3600;

        if (dayOfWeek == 5 && hourOfDay >= 22) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 21) {
            return true;
        }

        return engine.fadDayOverrides(block.timestamp / 86_400);
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
    ///         Pays the keeper bounty in USDC directly from the vault.
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

        uint256 vaultDepth = vault.totalAssets();
        uint256 keeperBountyUsdc = engine.liquidatePosition(accountId, executionPrice, vaultDepth, oraclePublishTime);

        if (keeperBountyUsdc > 0) {
            vault.payOut(msg.sender, keeperBountyUsdc);
        }

        _sendEth(msg.sender, msg.value - pythFee);
    }

}
