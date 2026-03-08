// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev No longer holds margin escrow. Users deposit to MarginClearinghouse directly.
/// @custom:security-contact contact@plether.com
contract OrderRouter {

    ICfdEngine public engine;
    ICfdVault public vault;
    IPyth public pyth;
    bytes32 public pythPriceFeedId;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;

    mapping(uint64 => CfdTypes.Order) public orders;
    mapping(uint64 => uint256) public keeperFees;
    mapping(address => uint256) public claimableEth;

    error OrderRouter__ZeroSize();
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

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, string reason);

    constructor(
        address _engine,
        address _vault,
        address _pyth,
        bytes32 _feedId
    ) {
        engine = ICfdEngine(_engine);
        vault = ICfdVault(_vault);
        pyth = IPyth(_pyth);
        pythPriceFeedId = _feedId;
    }

    // ==========================================
    // STEP 1: THE COMMITMENT (User Intent)
    // ==========================================

    /// @notice Submits a trade intent to the FIFO queue. Attach ETH as keeper incentive.
    ///         No margin is escrowed here — users deposit to MarginClearinghouse beforehand.
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external payable {
        if (sizeDelta == 0) {
            revert OrderRouter__ZeroSize();
        }

        uint64 orderId = nextCommitId++;
        bytes32 accountId = bytes32(uint256(uint160(msg.sender)));

        orders[orderId] = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp),
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
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        if (orderId != nextExecuteId) {
            revert OrderRouter__FIFOViolation();
        }
        CfdTypes.Order memory order = orders[orderId];
        if (order.sizeDelta == 0) {
            revert OrderRouter__OrderNotPending();
        }

        uint256 pythFee = 0;
        uint256 executionPrice;

        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                if (msg.value < pythFee) {
                    revert OrderRouter__InsufficientPythFee();
                }
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }

            PythStructs.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);

            if (pythData.publishTime <= order.commitTime) {
                _cancelOrder(orderId, "MEV: Oracle price is stale", pythFee);
                return;
            }
            if (block.timestamp - pythData.publishTime > 60) {
                _cancelOrder(orderId, "Oracle price too stale", pythFee);
                return;
            }
            executionPrice = _normalizePythPrice(pythData.price, pythData.expo);
        } else {
            if (block.chainid != 31_337) {
                revert OrderRouter__MockModeDisabled();
            }
            if (pythUpdateData.length > 0) {
                executionPrice = abi.decode(pythUpdateData[0], (uint256));
            } else {
                executionPrice = order.targetPrice;
            }
        }

        if (!_checkSlippage(order, executionPrice)) {
            _cancelOrder(orderId, "Slippage tolerance exceeded", pythFee);
            return;
        }

        uint256 vaultDepth = vault.totalAssets();

        try engine.processOrder(order, executionPrice, vaultDepth) {
            emit OrderExecuted(orderId, executionPrice);
        } catch Error(string memory reason) {
            emit OrderFailed(orderId, reason);
            _finalizeExecution(orderId, pythFee);
            return;
        } catch {
            emit OrderFailed(orderId, "Engine Math Panic");
            _finalizeExecution(orderId, pythFee);
            return;
        }

        _finalizeExecution(orderId, pythFee);
    }

    /// @notice Executes all pending orders up to maxOrderId against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Refunds all keeper
    ///         fees and excess ETH in a single transfer at the end.
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

        uint256 pythFee;
        uint256 executionPrice;
        uint256 pricePublishTime;

        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                if (msg.value < pythFee) {
                    revert OrderRouter__InsufficientPythFee();
                }
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }

            PythStructs.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);
            if (block.timestamp - pythData.publishTime > 60) {
                revert OrderRouter__OraclePriceTooStale();
            }
            executionPrice = _normalizePythPrice(pythData.price, pythData.expo);
            pricePublishTime = pythData.publishTime;
        } else {
            if (block.chainid != 31_337) {
                revert OrderRouter__MockModeDisabled();
            }
            if (pythUpdateData.length > 0) {
                executionPrice = abi.decode(pythUpdateData[0], (uint256));
            } else {
                executionPrice = 1e8;
            }
        }

        uint256 totalKeeperFees;

        while (nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            CfdTypes.Order memory order = orders[orderId];

            if (order.sizeDelta == 0) {
                totalKeeperFees += _cleanupOrder(orderId);
                continue;
            }

            if (pricePublishTime > 0 && pricePublishTime <= order.commitTime) {
                emit OrderFailed(orderId, "MEV: Oracle price is stale");
                _refundOrderFee(orderId, order);
                continue;
            }

            if (!_checkSlippage(order, executionPrice)) {
                emit OrderFailed(orderId, "Slippage tolerance exceeded");
                _refundOrderFee(orderId, order);
                continue;
            }

            uint256 vaultDepth = vault.totalAssets();
            bool success;

            try engine.processOrder(order, executionPrice, vaultDepth) {
                emit OrderExecuted(orderId, executionPrice);
                success = true;
            } catch Error(string memory reason) {
                emit OrderFailed(orderId, reason);
            } catch {
                emit OrderFailed(orderId, "Engine Math Panic");
            }

            totalKeeperFees += _cleanupOrder(orderId);
        }

        uint256 totalOut = totalKeeperFees + (msg.value - pythFee);
        if (totalOut > 0) {
            (bool success,) = payable(msg.sender).call{value: totalOut}("");
            if (!success) {
                claimableEth[msg.sender] += totalOut;
            }
        }
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _cleanupOrder(
        uint64 orderId
    ) internal returns (uint256 keeperFee) {
        keeperFee = keeperFees[orderId];
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;
    }

    function _refundOrderFee(
        uint64 orderId,
        CfdTypes.Order memory order
    ) internal {
        uint256 fee = keeperFees[orderId];
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;
        if (fee > 0) {
            address user = address(uint160(uint256(order.accountId)));
            claimableEth[user] += fee;
        }
    }

    function _cancelOrder(
        uint64 orderId,
        string memory reason,
        uint256 pythFee
    ) internal {
        emit OrderFailed(orderId, reason);

        CfdTypes.Order memory order = orders[orderId];
        uint256 fee = keeperFees[orderId];
        delete keeperFees[orderId];
        delete orders[orderId];
        nextExecuteId++;

        // Refund keeper fee to user, not to the cancelling keeper
        if (fee > 0) {
            address user = address(uint160(uint256(order.accountId)));
            claimableEth[user] += fee;
        }

        // Return only the keeper's own excess ETH (msg.value minus Pyth fee)
        uint256 refund = msg.value - pythFee;
        if (refund > 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) {
                claimableEth[msg.sender] += refund;
            }
        }
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee
    ) internal {
        uint256 fee = keeperFees[orderId];
        delete keeperFees[orderId];
        delete orders[orderId];

        nextExecuteId++;

        uint256 totalOut = fee + (msg.value - pythFee);
        if (totalOut > 0) {
            (bool success,) = payable(msg.sender).call{value: totalOut}("");
            if (!success) {
                claimableEth[msg.sender] += totalOut;
            }
        }
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
    // ATOMIC LIQUIDATIONS
    // ==========================================

    /// @notice Keeper-triggered liquidation with stricter staleness (≤ 15s).
    ///         Pays the keeper bounty in USDC directly from the vault.
    function executeLiquidation(
        bytes32 accountId,
        bytes[] calldata pythUpdateData
    ) external payable {
        uint256 pythFee = 0;
        uint256 executionPrice;

        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                if (msg.value < pythFee) {
                    revert OrderRouter__InsufficientPythFee();
                }
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }
            PythStructs.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);

            if (block.timestamp - pythData.publishTime > 15) {
                revert OrderRouter__MevOraclePriceTooStale();
            }
            executionPrice = _normalizePythPrice(pythData.price, pythData.expo);
        } else {
            if (block.chainid != 31_337) {
                revert OrderRouter__MockModeDisabled();
            }
            if (pythUpdateData.length > 0) {
                executionPrice = abi.decode(pythUpdateData[0], (uint256));
            } else {
                executionPrice = 1e8;
            }
        }

        uint256 vaultDepth = vault.totalAssets();
        uint256 keeperBountyUsdc = engine.liquidatePosition(accountId, executionPrice, vaultDepth);

        if (keeperBountyUsdc > 0) {
            vault.payOut(msg.sender, keeperBountyUsdc);
        }

        uint256 refund = msg.value - pythFee;
        if (refund > 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) {
                claimableEth[msg.sender] += refund;
            }
        }
    }

}
