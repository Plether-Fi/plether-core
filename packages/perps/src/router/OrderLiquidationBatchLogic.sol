// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";

/// @notice Router getters and isolated item entrypoints used by delegated keeper logic.
interface IOrderLiquidationBatchHost {

    function engine() external view returns (ICfdEngineCore);

    function pletherOracle() external view returns (IPletherOracle);

    function positionProtectionBook() external view returns (IPositionProtectionBook);

    function nextCommitId() external view returns (uint64);

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
        address keeper,
        uint64 riskOffCutoff
    ) external returns (uint256 outcome);

    function executePositionProtectionTriggerItem() external;

}

/// @notice Narrow deferred-refund surface used by delegated router logic.
interface IOrderDelegatedLogicRefundAdmin {

    function creditClaimableEth(
        address beneficiary,
        uint256 amount
    ) external payable;

}

/// @title OrderLiquidationBatchLogic
/// @notice Stateless mark-refresh, LP-settlement, and liquidation orchestration executed by Router delegatecall.
/// @dev This code deliberately reads router state only through external getters and mutates it only through the
///      isolated item entrypoints. It therefore has no dependency on the router's storage layout. Delegatecall keeps
///      the oracle/engine caller and emitted-event address equal to the router while keeping this code out of the
///      Router's EIP-170 runtime and EIP-3860 creation input.
abstract contract OrderLiquidationBatchLogic is IOrderRouterErrors {

    /// @notice Dedicated rejection ABI for direct or foreign-context liquidation-batch calls.
    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

    /// @notice Hard candidate-list bound; transaction gas can stop a batch before all 256 accounts are attempted.
    uint256 private constant MAX_LIQUIDATION_BATCH_ACCOUNTS = 256;
    /// @notice Fixed item budget above `minEngineGas` for router dispatch and account-level bounty accounting.
    uint256 private constant LIQUIDATION_BATCH_ROUTER_GAS = 250_000;
    /// @notice Item budget for each live order's bounty scan plus terminal reservation and queue cleanup.
    uint256 private constant LIQUIDATION_BATCH_GAS_PER_ORDER = 150_000;
    /// @notice Gas retained by the batch frame for failure classification, events, and a clean return.
    uint256 private constant LIQUIDATION_BATCH_TAIL_GAS = 250_000;

    /// @notice Returns the only Router address in which this immutable code may execute by delegatecall.
    function _delegatedLogicRouter() internal view virtual returns (address);

    /// @notice Forwards the oracle-policy portion of an authenticated Router configuration.
    /// @dev The Router performs admin authentication and its pre-oracle stores before delegating here, then applies
    ///      its remaining fields after this call. Delegate context preserves `msg.sender == Router` at the oracle.
    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external {
        _requireDelegateCall();
        IOrderLiquidationBatchHost(address(this)).pletherOracle()
            .applyConfig(
                IPletherOracle.OracleConfig({
                    orderExecutionStalenessLimit: config.orderExecutionStalenessLimit,
                    liquidationStalenessLimit: config.liquidationStalenessLimit,
                    basketMaxConfidenceRatioBps: config.basketMaxConfidenceRatioBps,
                    orderSettlementWindow: config.orderSettlementWindow,
                    maxComponentPublishTimeDivergence: config.maxComponentPublishTimeDivergence,
                    adverseConfidenceMultiplierBps: config.adverseConfidenceMultiplierBps
                })
            );
    }

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
        // Only the Router's immutable state-owning Book may append the authenticated trigger payload.
        IPositionProtectionBook protectionBook = host.positionProtectionBook();
        bool isProtectionTrigger = msg.sender == address(protectionBook);
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
        ICfdEngineCore engine = host.engine();
        engine.updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        if (isProtectionTrigger) {
            uint64 linkedOrderId = host.nextCommitId();
            IPositionProtectionBook.TriggerPlan memory plan =
                protectionBook.activate(protectionId, snapshot.markPrice, snapshot.publishTime, linkedOrderId);
            bytes memory triggerItemCall = abi.encodeWithSelector(
                IOrderLiquidationBatchHost.executePositionProtectionTriggerItem.selector,
                linkedOrderId,
                plan.account,
                plan.side,
                plan.size,
                plan.executionBountyUsdc
            );
            (bool triggerRecorded, bytes memory triggerRevertData) = address(host).call(triggerItemCall);
            if (!triggerRecorded) {
                assembly ("memory-safe") {
                    revert(add(triggerRevertData, 0x20), mload(triggerRevertData))
                }
            }
            engine.creditBounty(
                plan.account, refundRecipient, plan.triggerBountyUsdc, snapshot.markPrice, snapshot.publishTime
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
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
        IPletherOracle.PriceSnapshot memory snapshot =
            host.pletherOracle().updateLiquidationPrice{value: msg.value}(msg.sender, pythUpdateData, account);
        ICfdEngineCore engine = host.engine();
        if (snapshot.publishTime >= engine.lastMarkTime()) {
            engine.updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        }
        host.executeLiquidationBatchItem(
            account, snapshot.price, snapshot.price, snapshot.publishTime, msg.sender, riskOffCutoff
        );
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
        _requireLiquidationBatchDelegateCall();

        uint256 accountCount = accounts.length;
        if (accountCount == 0 || accountCount > MAX_LIQUIDATION_BATCH_ACCOUNTS) {
            revert OrderRouter__InvalidLiquidationBatchSize();
        }

        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
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
                account, snapshot.bullPrice, snapshot.bearPrice, snapshot.publishTime, msg.sender, riskOffCutoff
            ) returns (
                uint256 outcome
            ) {
                bool restoredSolvency = outcome == type(uint256).max;
                emit LiquidationBatchItem(
                    nextIndex,
                    account,
                    restoredSolvency ? LiquidationBatchResult.SkippedSolvent : LiquidationBatchResult.Liquidated,
                    restoredSolvency ? 0 : outcome,
                    bytes4(0)
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
        if (address(this) != _delegatedLogicRouter()) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _requireLiquidationBatchDelegateCall() private view {
        if (address(this) != _delegatedLogicRouter()) {
            revert OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();
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
