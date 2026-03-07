// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./ICfdEngine.sol";
import {ICfdVault} from "./ICfdVault.sol";

interface IPyth {

    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (Price memory price);
    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable;
    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256 feeAmount);

}

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev No longer holds margin escrow. Users deposit to MarginClearinghouse directly.
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

    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external payable {
        require(sizeDelta > 0, "OrderRouter: Size must be > 0");

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

    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        require(orderId == nextExecuteId, "OrderRouter: Strict FIFO violation");
        CfdTypes.Order memory order = orders[orderId];
        require(order.sizeDelta > 0, "OrderRouter: Order not pending");

        uint256 pythFee = 0;
        uint256 executionPrice;

        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                require(msg.value >= pythFee, "OrderRouter: Insufficient Pyth fee");
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }

            IPyth.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);

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
            require(block.chainid == 31_337, "OrderRouter: Mock mode disabled on live networks");
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
            _cancelOrder(orderId, reason, pythFee);
            return;
        } catch {
            _cancelOrder(orderId, "Engine Math Panic", pythFee);
            return;
        }

        _finalizeExecution(orderId, pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _cancelOrder(
        uint64 orderId,
        string memory reason,
        uint256 pythFee
    ) internal {
        emit OrderFailed(orderId, reason);
        _finalizeExecution(orderId, pythFee);
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

    function claimEth() external {
        uint256 amount = claimableEth[msg.sender];
        require(amount > 0, "OrderRouter: Nothing to claim");
        claimableEth[msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "OrderRouter: ETH transfer failed");
    }

    function _checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0) {
            return true;
        }
        if (order.side == CfdTypes.Side.BULL) {
            return executionPrice <= order.targetPrice;
        }
        return executionPrice >= order.targetPrice;
    }

    function _normalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        require(price > 0, "Oracle price negative");
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

    function executeLiquidation(
        bytes32 accountId,
        bytes[] calldata pythUpdateData
    ) external payable {
        uint256 pythFee = 0;
        uint256 executionPrice;

        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                require(msg.value >= pythFee, "OrderRouter: Insufficient Pyth fee");
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }
            IPyth.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);

            require(block.timestamp - pythData.publishTime <= 15, "MEV: Oracle price too stale");
            executionPrice = _normalizePythPrice(pythData.price, pythData.expo);
        } else {
            require(block.chainid == 31_337, "OrderRouter: Mock mode disabled on live networks");
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
