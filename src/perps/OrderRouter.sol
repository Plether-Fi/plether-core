// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev No longer holds margin escrow. Users deposit to MarginClearinghouse directly.
/// @custom:security-contact contact@plether.com
contract OrderRouter is Ownable2Step, Pausable {

    ICfdEngine public engine;
    ICfdVault public vault;
    IPyth public pyth;
    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;

    uint256 public maxOrderAge;
    uint256 public minKeeperFee;

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant MIN_ENGINE_GAS = 600_000;
    uint256 internal constant MIN_MEV_PUBLISH_DELAY = 5;
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 internal constant DEFAULT_MIN_KEEPER_FEE = 0.01 ether;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;

    uint256 public pendingMinKeeperFee;
    uint256 public minKeeperFeeActivationTime;
    bool public keeperFeeEnforced;

    mapping(uint64 => CfdTypes.Order) public orders;
    mapping(uint64 => uint256) public keeperFees;
    mapping(uint64 => uint256) public committedMargins;
    mapping(address => uint256) public claimableEth;

    error OrderRouter__ZeroSize();
    error OrderRouter__CloseMarginDeltaNotAllowed();
    error OrderRouter__InsufficientKeeperFee();
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
        maxOrderAge = DEFAULT_MAX_ORDER_AGE;
        minKeeperFee = DEFAULT_MIN_KEEPER_FEE;
        keeperFeeEnforced = block.chainid != 31_337;

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

    /// @notice Proposes a new minKeeperFee value, subject to 48h timelock.
    function proposeMinKeeperFee(
        uint256 _minKeeperFee
    ) external onlyOwner {
        pendingMinKeeperFee = _minKeeperFee;
        minKeeperFeeActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending minKeeperFee after timelock expires.
    function finalizeMinKeeperFee() external onlyOwner {
        if (minKeeperFeeActivationTime == 0) {
            revert OrderRouter__NoProposal();
        }
        if (block.timestamp < minKeeperFeeActivationTime) {
            revert OrderRouter__TimelockNotReady();
        }
        minKeeperFee = pendingMinKeeperFee;
        pendingMinKeeperFee = 0;
        minKeeperFeeActivationTime = 0;
        keeperFeeEnforced = true;
    }

    /// @notice Cancels the pending minKeeperFee proposal.
    function cancelMinKeeperFeeProposal() external onlyOwner {
        pendingMinKeeperFee = 0;
        minKeeperFeeActivationTime = 0;
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

    /// @notice Submits a trade intent to the FIFO queue. Attach ETH as keeper incentive.
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
    ) external payable {
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
        if (isClose) {
            if (!engine.hasOpenPosition(accountId)) {
                revert OrderRouter__NoOpenPosition();
            }
            if (engine.getPositionSide(accountId) != side) {
                revert OrderRouter__CloseSideMismatch();
            }
        }
        if (keeperFeeEnforced && msg.value < minKeeperFee) {
            revert OrderRouter__InsufficientKeeperFee();
        }

        uint64 orderId = nextCommitId++;

        if (!isClose && marginDelta > 0) {
            IMarginClearinghouse(engine.clearinghouse()).lockMargin(accountId, marginDelta);
            committedMargins[orderId] = marginDelta;
        }

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

        keeperFees[orderId] = msg.value;
        emit OrderCommitted(orderId, accountId, side);
    }

    // ==========================================
    // STEP 2: THE REVEAL (Keeper Execution)
    // ==========================================

    /// @notice Keeper executes the next order in strict FIFO sequence.
    ///         Validates oracle freshness (publishTime > commitTime, age ≤ 60s),
    ///         checks slippage, then delegates to CfdEngine. On any failure the queue
    ///         still advances (un-brickable design).
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
        CfdTypes.Order memory order = orders[orderId];
        if (order.sizeDelta == 0) {
            revert OrderRouter__OrderNotPending();
        }
        if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
            emit OrderFailed(orderId, "Order expired");
            _finalizeExecution(orderId, 0, false);
            return;
        }

        (uint256 executionPrice, uint64 oraclePublishTime, uint256 pythFee) =
            _resolveOraclePrice(pythUpdateData, order.targetPrice);

        if (address(pyth) != address(0)) {
            bool isFad = engine.isFadWindow();
            bool oracleFrozen = _isOracleFrozen();
            if (oracleFrozen && !order.isClose) {
                emit OrderFailed(orderId, "Oracle frozen: close-only mode");
                _finalizeExecution(orderId, pythFee, false);
                return;
            }

            if (isFad && !order.isClose) {
                emit OrderFailed(orderId, "FAD: close-only mode");
                _finalizeExecution(orderId, pythFee, false);
                return;
            }

            uint256 maxStaleness = oracleFrozen ? engine.fadMaxStaleness() : 60;
            uint256 age = block.timestamp > oraclePublishTime ? block.timestamp - oraclePublishTime : 0;
            if (age > maxStaleness) {
                emit OrderFailed(orderId, "Oracle price too stale");
                _finalizeExecution(orderId, pythFee, false);
                return;
            }

            if (!oracleFrozen && block.number == order.commitBlock) {
                revert OrderRouter__MevDetected();
            }

            if (!oracleFrozen && oraclePublishTime <= order.commitTime + MIN_MEV_PUBLISH_DELAY) {
                revert OrderRouter__MevDetected();
            }
        }

        uint256 capPrice = engine.CAP_PRICE();
        if (executionPrice > capPrice) {
            executionPrice = capPrice;
        }

        if (!_checkSlippage(order, executionPrice)) {
            emit OrderFailed(orderId, "Slippage tolerance exceeded");
            _finalizeExecution(orderId, pythFee, false);
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
            _finalizeExecution(orderId, pythFee, false);
            return;
        } catch {
            emit OrderFailed(orderId, "Engine Math Panic");
            _finalizeExecution(orderId, pythFee, false);
            return;
        }

        _finalizeExecution(orderId, pythFee, true);
    }

    /// @notice Executes all pending orders up to maxOrderId against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Refunds all keeper
    ///         fees and excess ETH in a single transfer at the end.
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

        bool isFad;
        bool oracleFrozen;
        if (address(pyth) != address(0)) {
            isFad = engine.isFadWindow();
            oracleFrozen = _isOracleFrozen();
            uint256 maxStaleness = oracleFrozen ? engine.fadMaxStaleness() : 60;
            uint256 age = block.timestamp > oraclePublishTime ? block.timestamp - oraclePublishTime : 0;
            if (age > maxStaleness) {
                revert OrderRouter__OraclePriceTooStale();
            }
        }

        uint256 capPrice = engine.CAP_PRICE();
        uint256 clampedPrice = executionPrice > capPrice ? capPrice : executionPrice;

        uint256 totalKeeperFees;

        while (nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            CfdTypes.Order memory order = orders[orderId];

            if (order.sizeDelta == 0) {
                totalKeeperFees += _cleanupOrder(orderId, false);
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                emit OrderFailed(orderId, "Order expired");
                totalKeeperFees += _cleanupOrder(orderId, false);
                continue;
            }

            if ((isFad || oracleFrozen) && !order.isClose) {
                emit OrderFailed(orderId, "FAD: close-only mode");
                totalKeeperFees += _cleanupOrder(orderId, false);
                continue;
            }

            if (
                address(pyth) != address(0) && !oracleFrozen
                    // Stop at the first same-block order so newer queued orders remain pending too.
                    && (block.number == order.commitBlock
                        || oraclePublishTime <= order.commitTime + MIN_MEV_PUBLISH_DELAY)
            ) {
                break;
            }

            if (!_checkSlippage(order, clampedPrice)) {
                emit OrderFailed(orderId, "Slippage tolerance exceeded");
                totalKeeperFees += _cleanupOrder(orderId, false);
                continue;
            }

            uint256 vaultDepth = vault.totalAssets();

            uint256 forwardedGas = gasleft() - (gasleft() / 64);
            if (forwardedGas < MIN_ENGINE_GAS) {
                revert OrderRouter__InsufficientGas();
            }

            _releaseCommittedMarginForExecution(orderId);

            try engine.processOrder(order, clampedPrice, vaultDepth, oraclePublishTime) {
                emit OrderExecuted(orderId, clampedPrice);
                totalKeeperFees += _cleanupOrder(orderId, true);
            } catch Error(string memory reason) {
                emit OrderFailed(orderId, reason);
                totalKeeperFees += _cleanupOrder(orderId, false);
            } catch {
                emit OrderFailed(orderId, "Engine Math Panic");
                totalKeeperFees += _cleanupOrder(orderId, false);
            }
        }

        _sendEth(msg.sender, totalKeeperFees + (msg.value - pythFee));
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
            CfdTypes.Order memory order = orders[headId];
            if (order.sizeDelta == 0) {
                nextExecuteId++;
                continue;
            }
            if (block.timestamp - order.commitTime <= age) {
                break;
            }
            emit OrderFailed(headId, "Order expired");
            _confiscateOrderFee(headId);
        }
    }

    function _confiscateOrderFee(
        uint64 orderId
    ) internal {
        uint256 fee = keeperFees[orderId];
        _unlockCommittedMargin(orderId);
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;
        if (fee > 0) {
            claimableEth[msg.sender] += fee;
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
    ) internal returns (uint256 keeperFee) {
        keeperFee = keeperFees[orderId];
        if (success) {
            _clearCommittedMargin(orderId);
        } else {
            _unlockCommittedMargin(orderId);
            if (keeperFee > 0) {
                _sendEth(_accountOwnerAddress(orderId), keeperFee);
            }
            keeperFee = 0;
        }
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee,
        bool success
    ) internal {
        uint256 fee = keeperFees[orderId];
        address accountOwner = _accountOwnerAddress(orderId);
        if (success) {
            _clearCommittedMargin(orderId);
        } else {
            _unlockCommittedMargin(orderId);
        }
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;

        uint256 excessEth = msg.value - pythFee;
        if (success) {
            _sendEth(msg.sender, fee + excessEth);
        } else {
            _sendEth(accountOwner, fee);
            _sendEth(msg.sender, excessEth);
        }
    }

    function _accountOwnerAddress(
        uint64 orderId
    ) internal view returns (address) {
        return address(uint160(uint256(orders[orderId].accountId)));
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

    /// @notice Claims ETH stuck from failed keeper refund transfers
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
            uint256 maxStaleness = _isOracleFrozen() ? engine.fadMaxStaleness() : 60;
            uint256 age = block.timestamp > oraclePublishTime ? block.timestamp - oraclePublishTime : 0;
            if (age > maxStaleness) {
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
            uint256 maxStaleness = _isOracleFrozen() ? engine.fadMaxStaleness() : 15;
            uint256 age = block.timestamp > oraclePublishTime ? block.timestamp - oraclePublishTime : 0;
            if (age > maxStaleness) {
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
