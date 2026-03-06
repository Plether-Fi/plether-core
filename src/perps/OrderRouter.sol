// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICfdEngine {

    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (int256 settlementUsdc);

}

interface ICfdVault {

    function totalAssets() external view returns (uint256);
    function routeToVault(
        uint256 amountUsdc
    ) external;
    function routeToTrader(
        address trader,
        uint256 amountUsdc
    ) external;

}

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
contract OrderRouter {

    using SafeERC20 for IERC20;

    ICfdEngine public engine;
    ICfdVault public vault;
    IERC20 public usdc;
    IPyth public pyth;
    bytes32 public pythPriceFeedId;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;

    mapping(uint64 => CfdTypes.Order) public orders;
    mapping(uint64 => uint256) public keeperFees; // Native ETH bounties

    event OrderCommitted(uint64 indexed orderId, bytes32 indexed accountId, CfdTypes.Side side);
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, string reason);

    constructor(
        address _engine,
        address _vault,
        address _usdc,
        address _pyth,
        bytes32 _feedId
    ) {
        engine = ICfdEngine(_engine);
        vault = ICfdVault(_vault);
        usdc = IERC20(_usdc);
        pyth = IPyth(_pyth);
        pythPriceFeedId = _feedId;

        usdc.approve(_vault, type(uint256).max);
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

        // Lock the USDC margin in the Router temporarily (Escrow)
        if (marginDelta > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), marginDelta);
        }

        uint64 orderId = nextCommitId++;
        bytes32 accountId = bytes32(uint256(uint160(msg.sender))); // V1: Map to user address

        orders[orderId] = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp), // MEV Defense Timestamp
            orderId: orderId,
            side: side,
            isClose: isClose
        });

        keeperFees[orderId] = msg.value; // Store ETH bounty for keeper
        emit OrderCommitted(orderId, accountId, side);
    }

    // ==========================================
    // STEP 2: THE REVEAL (Keeper Execution)
    // ==========================================

    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        // 1. Strict FIFO Queue Enforcement
        require(orderId == nextExecuteId, "OrderRouter: Strict FIFO violation");
        CfdTypes.Order memory order = orders[orderId];
        require(order.sizeDelta > 0, "OrderRouter: Order not pending");

        uint256 pythFee = 0;
        uint256 executionPrice;

        // 2. Fetch Validated Oracle Price
        if (address(pyth) != address(0)) {
            if (pythUpdateData.length > 0) {
                pythFee = pyth.getUpdateFee(pythUpdateData);
                require(msg.value >= pythFee, "OrderRouter: Insufficient Pyth fee");
                pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            }

            IPyth.Price memory pythData = pyth.getPriceUnsafe(pythPriceFeedId);

            // 3. CRITICAL: Prevent Oracle Latency Arbitrage (Front-Running)
            if (pythData.publishTime <= order.commitTime) {
                _cancelAndRefund(orderId, order, "MEV: Oracle price is stale", pythFee);
                return;
            }
            executionPrice = _normalizePythPrice(pythData.price, pythData.expo);
        } else {
            executionPrice = order.targetPrice; // Mock mode if Pyth not deployed
        }

        // 4. Slippage Protection
        if (!_checkSlippage(order, executionPrice)) {
            _cancelAndRefund(orderId, order, "Slippage tolerance exceeded", pythFee);
            return;
        }

        // 5. THE UN-BRICKABLE TRY/CATCH EXECUTION
        uint256 vaultDepth = vault.totalAssets();

        try engine.processOrder(order, executionPrice, vaultDepth) returns (int256 settlementUsdc) {
            _routeSettlement(order, settlementUsdc);
            emit OrderExecuted(orderId, executionPrice);
        } catch Error(string memory reason) {
            // Engine Reverted (e.g., Solvency hit, Skew cap hit)
            _cancelAndRefund(orderId, order, reason, pythFee);
            return;
        } catch {
            // Engine Math Panic
            _cancelAndRefund(orderId, order, "Engine Math Panic", pythFee);
            return;
        }

        // 6. Cleanup & Keeper Reward
        _finalizeExecution(orderId, pythFee);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _routeSettlement(
        CfdTypes.Order memory order,
        int256 settlementUsdc
    ) internal {
        address user = address(uint160(uint256(order.accountId)));

        if (settlementUsdc < 0) {
            // User pays Protocol (Router sends locked margin to Vault)
            uint256 amountToVault = uint256(-settlementUsdc);
            vault.routeToVault(amountToVault);

            // Refund any un-utilized margin back to user
            if (order.marginDelta > amountToVault) {
                usdc.safeTransfer(user, order.marginDelta - amountToVault);
            }
        } else if (settlementUsdc > 0) {
            // Protocol pays User (Vault pays User directly)
            if (order.marginDelta > 0) {
                usdc.safeTransfer(user, order.marginDelta);
            }
            vault.routeToTrader(user, uint256(settlementUsdc));
        } else {
            // Net zero
            if (order.marginDelta > 0) {
                usdc.safeTransfer(user, order.marginDelta);
            }
        }
    }

    function _cancelAndRefund(
        uint64 orderId,
        CfdTypes.Order memory order,
        string memory reason,
        uint256 pythFee
    ) internal {
        if (order.marginDelta > 0) {
            address user = address(uint160(uint256(order.accountId)));
            usdc.safeTransfer(user, order.marginDelta);
        }
        emit OrderFailed(orderId, reason);
        _finalizeExecution(orderId, pythFee);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 pythFee
    ) internal {
        // Payout Keeper Bounty
        uint256 fee = keeperFees[orderId];
        delete keeperFees[orderId];
        delete orders[orderId];

        if (fee > 0) {
            (bool success,) = payable(msg.sender).call{value: fee}("");
            require(success, "OrderRouter: Keeper fee transfer failed");
        }

        // Refund excess ETH provided for Pyth update
        uint256 refund = msg.value - pythFee;
        if (refund > 0) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            require(success, "OrderRouter: Pyth refund failed");
        }

        nextExecuteId++; // CRITICAL: Advance the queue
    }

    function _checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0 || order.isClose) {
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

}
