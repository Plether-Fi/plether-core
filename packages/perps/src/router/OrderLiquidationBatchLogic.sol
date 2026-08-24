// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

/// @notice Router getters and the isolated item entrypoint used by delegated liquidation-batch logic.
interface IOrderLiquidationBatchHost {

    function engine() external view returns (ICfdEngineCore);

    function pletherOracle() external view returns (IPletherOracle);

    function minEngineGas() external view returns (uint256);

    function admin() external view returns (address);

    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    function executeLiquidationBatchItem(
        address account,
        uint256 bullPrice,
        uint256 bearPrice,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

    function executePositionProtectionTriggerItem(
        address keeper,
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime
    ) external;

}

/// @notice Narrow deferred-refund surface used by delegated router logic.
interface IOrderDelegatedLogicRefundAdmin {

    function creditClaimableEth(
        address beneficiary,
        uint256 amount
    ) external payable;

}

/// @title OrderLiquidationBatchLogic
/// @notice Stateless liquidation-batch loop carried by the router's immutable sidecar and executed by delegatecall.
/// @dev This code deliberately reads router state only through external getters and mutates it only through the
///      isolated item entrypoint. It therefore has no dependency on the router's storage layout. Delegatecall keeps
///      the oracle/engine caller and emitted-event address equal to the router while moving the large loop out of the
///      router's EIP-170-constrained runtime bytecode.
abstract contract OrderLiquidationBatchLogic is IOrderRouterErrors {

    /// @notice Hard candidate-list bound; transaction gas can stop a batch before all 256 accounts are attempted.
    uint256 private constant MAX_LIQUIDATION_BATCH_ACCOUNTS = 256;
    /// @notice Fixed item budget above `minEngineGas` for router dispatch and account-level bounty accounting.
    uint256 private constant LIQUIDATION_BATCH_ROUTER_GAS = 200_000;
    /// @notice Item budget for each live order's bounty scan plus terminal reservation and queue cleanup.
    uint256 private constant LIQUIDATION_BATCH_GAS_PER_ORDER = 150_000;
    /// @notice Gas retained by the batch frame for failure classification, events, and a clean return.
    uint256 private constant LIQUIDATION_BATCH_TAIL_GAS = 250_000;

    /// @dev Concrete sidecar address embedded in its runtime; equality means the function was called directly.
    address private immutable _DELEGATED_LOGIC_SELF = address(this);

    /// @notice Refreshes the pool-accounting mark and settles matured LP epochs in one rollback frame.
    /// @dev Must be reached by delegatecall from the router. Every integration is obtained through external getters,
    ///      so this implementation has no dependency on router storage layout. Only the exact quoted Pyth fee is
    ///      forwarded before settlement; any excess is refunded or deferred afterwards.
    /// @param pythUpdateData Pyth price update blobs supplied to the configured oracle.
    function settleLpEpoch(
        bytes[] calldata pythUpdateData
    ) external payable {
        _requireDelegateCall();

        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        IPletherOracle oracle = host.pletherOracle();
        uint256 pythFee = oracle.getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) {
            revert IPletherOracle.PletherOracle__InsufficientFee(msg.value, pythFee);
        }

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice{value: pythFee}(msg.sender, pythUpdateData, IPletherOracle.PriceMode.PoolReconcile);
        host.engine().updateMarkPrice(snapshot.markPrice, snapshot.publishTime);

        address pool = address(oracle.housePool());
        uint256 selector = uint32(IHousePool.settleLpEpoch.selector);
        // Keep the Router path independent of the large settlement return struct while preserving exact revert data.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            mstore(add(ptr, 4), mload(add(snapshot, 32)))
            mstore(add(ptr, 36), mload(add(snapshot, 64)))
            if iszero(call(gas(), pool, 0, ptr, 68, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 448) { revert(0, 0) }
        }

        _sendEth(host.admin(), msg.sender, msg.value - pythFee);
    }

    /// @notice Applies an ordinary mark-refresh oracle update on behalf of the delegating router.
    /// @param pythUpdateData Pyth price update blobs funded by the call's full `msg.value`.
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable {
        _requireDelegateCall();

        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        bool isProtectionTrigger = msg.sender == _DELEGATED_LOGIC_SELF;
        address refundRecipient = msg.sender;
        uint64 protectionId;
        if (isProtectionTrigger) {
            assembly ("memory-safe") {
                refundRecipient := calldataload(sub(calldatasize(), 64))
                protectionId := calldataload(sub(calldatasize(), 32))
            }
        }
        IPletherOracle.PriceSnapshot memory snapshot = host.pletherOracle().updatePrice{value: msg.value}(
            refundRecipient, pythUpdateData, IPletherOracle.PriceMode.MarkRefresh
        );
        host.engine().updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        if (isProtectionTrigger) {
            host.executePositionProtectionTriggerItem(
                refundRecipient, protectionId, snapshot.markPrice, snapshot.publishTime
            );
        }
    }

    /// @notice Resolves and executes one account liquidation on behalf of the delegating router.
    /// @dev This preserves the single-account oracle path, including its account-specific adverse price and immediate
    ///      oracle refund policy. Account mutation is dispatched through the Router's isolated item entrypoint.
    /// @param account Canonical account to liquidate.
    /// @param pythUpdateData Pyth price update blobs funded by the call's full `msg.value`.
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable {
        _requireDelegateCall();

        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        IPletherOracle.PriceSnapshot memory snapshot =
            host.pletherOracle().updateLiquidationPrice{value: msg.value}(msg.sender, pythUpdateData, account);
        ICfdEngineCore engine = host.engine();
        if (snapshot.publishTime >= engine.lastMarkTime()) {
            engine.updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        }
        host.executeLiquidationBatchItem(account, snapshot.price, snapshot.price, snapshot.publishTime, msg.sender);
    }

    /// @notice Updates Pyth and the neutral engine mark once, then independently attempts each supplied account.
    /// @dev Must be reached by delegatecall from the router with the router's original calldata. Every account is
    ///      dispatched through the router's external self-call so a caught revert restores only that account's state.
    /// @param accounts Candidate accounts to liquidate.
    /// @param pythUpdateData Pyth update blobs funded once by the call's `msg.value`.
    /// @return nextIndex First unattempted index, or `accounts.length` when every account was attempted.
    function executeLiquidationBatch(
        address[] calldata accounts,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 nextIndex) {
        _requireDelegateCall();

        uint256 accountCount = accounts.length;
        if (accountCount == 0 || accountCount > MAX_LIQUIDATION_BATCH_ACCOUNTS) {
            revert OrderRouter__InvalidLiquidationBatchSize();
        }

        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        IPletherOracle.LiquidationBatchSnapshot memory snapshot =
            host.pletherOracle().updateLiquidationBatchPrice{value: msg.value}(msg.sender, pythUpdateData);
        host.engine().updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        uint256 engineGas = host.minEngineGas();

        while (nextIndex < accountCount) {
            address account = accounts[nextIndex];
            uint256 itemGas = engineGas + LIQUIDATION_BATCH_ROUTER_GAS
                + (host.pendingOrderCounts(account) * LIQUIDATION_BATCH_GAS_PER_ORDER);

            uint256 remainingGas = gasleft();
            if (remainingGas <= itemGas + LIQUIDATION_BATCH_TAIL_GAS) {
                emit LiquidationBatchStopped(nextIndex);
                return nextIndex;
            }

            try host.executeLiquidationBatchItem{gas: itemGas}(
                account, snapshot.bullPrice, snapshot.bearPrice, snapshot.publishTime, msg.sender
            ) returns (
                uint256 keeperBountyUsdc
            ) {
                emit LiquidationBatchItem(
                    nextIndex, account, LiquidationBatchResult.Liquidated, keeperBountyUsdc, bytes4(0)
                );
            } catch (bytes memory revertData) {
                if (revertData.length == 0) {
                    emit LiquidationBatchStopped(nextIndex);
                    return nextIndex;
                }
                bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
                emit LiquidationBatchItem(nextIndex, account, _liquidationBatchResult(selector), 0, selector);
            }

            unchecked {
                ++nextIndex;
            }
        }
    }

    function _liquidationBatchResult(
        bytes4 selector
    ) private pure returns (LiquidationBatchResult result) {
        if (selector == ICfdEngineTypes.CfdEngine__NoPositionToLiquidate.selector) {
            return LiquidationBatchResult.SkippedNoPosition;
        }
        if (selector == ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector) {
            return LiquidationBatchResult.SkippedSolvent;
        }
        return LiquidationBatchResult.Failed;
    }

    function _requireDelegateCall() private view {
        if (address(this) == _DELEGATED_LOGIC_SELF) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _sendEth(
        address admin,
        address recipient,
        uint256 amount
    ) private {
        if (amount == 0) {
            return;
        }
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) {
            IOrderDelegatedLogicRefundAdmin(admin).creditClaimableEth{value: amount}(recipient, amount);
        }
    }

}
