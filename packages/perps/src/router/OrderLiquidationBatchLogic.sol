// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {OrderFailurePolicyLib} from "@plether/perps/libraries/OrderFailurePolicyLib.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

/// @notice Router getters and isolated item entrypoints used by delegated keeper logic.
interface IOrderLiquidationBatchHost {

    function engine() external view returns (ICfdEngineCore);

    function pletherOracle() external view returns (IPletherOracle);

    function positionProtectionBook() external view returns (IPositionProtectionBook);

    function lifecycleBook() external view returns (IOrderLifecycleBook);

    function engineLensForCommit() external view returns (ICfdEngineLens);

    function nextCommitId() external view returns (uint64);

    function maxOrderAge() external view returns (uint256);

    function minEngineGas() external view returns (uint256);

    function admin() external view returns (address);

    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    function accountHeadOrderId(
        address account
    ) external view returns (uint64);

    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId);

    function minOpenNotionalUsdc() external view returns (uint256);

    function openOrderExecutionBountyBps() external view returns (uint256);

    function minOpenOrderExecutionBountyUsdc() external view returns (uint256);

    function maxOpenOrderExecutionBountyUsdc() external view returns (uint256);

    function closeOrderExecutionBountyUsdc() external view returns (uint256);

    function executeCommitOrderItem() external;

    function executeLiquidationBatchItem(
        address account,
        uint256 bullPrice,
        uint256 bearPrice,
        uint256 neutralMarkPrice,
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

    /// @notice Minimal projected position used by delegated close-commit validation.
    struct QueuedPositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
    }

    /// @notice Dedicated rejection ABI for direct or foreign-context liquidation-batch calls.
    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

    /// @notice Hard candidate-list bound; transaction gas can stop a batch before all 256 accounts are attempted.
    uint256 private constant MAX_LIQUIDATION_BATCH_ACCOUNTS = 256;
    /// @notice Fixed item budget above `minEngineGas` for router dispatch and account-level bounty accounting.
    uint256 private constant LIQUIDATION_BATCH_ROUTER_GAS = 250_000;
    /// @notice Item budget for each live order's bounty scan plus terminal reservation and queue cleanup.
    uint256 private constant LIQUIDATION_BATCH_GAS_PER_ORDER = 600_000;
    /// @notice Gas retained by the batch frame for failure classification, events, and a clean return.
    uint256 private constant LIQUIDATION_BATCH_TAIL_GAS = 250_000;
    /// @notice Bitmask of every execution regime currently defined by the V2 schema.
    uint8 private constant ALL_V2_EXECUTION_MODES = 1 | 2 | 4;

    /// @notice Returns the only Router address in which this immutable code may execute by delegatecall.
    function _delegatedLogicRouter() internal view virtual returns (address);

    /// @notice Resolves or submits a public financially bounded order on behalf of the delegating Router.
    /// @dev Keeping request validation and read-only policy projection in this stateless module preserves Router
    ///      bytecode headroom. Lifecycle registration still occurs as the Router, and the final reservation/queue
    ///      mutation crosses an authenticated external self-call back into the Router's canonical storage.
    function commitOrder(
        OrderV2Types.OrderRequest calldata request
    ) external returns (uint64 orderId) {
        _requireDelegateCall();
        return _commitOrder(IOrderLiquidationBatchHost(address(this)), msg.sender, request, true, false);
    }

    /// @notice Resolves or submits an attached open constructed by the Router's immutable protection Book.
    function commitProtectedOpen(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) external returns (uint64 orderId) {
        _requireDelegateCall();
        IOrderLiquidationBatchHost host = IOrderLiquidationBatchHost(address(this));
        if (
            msg.sender != address(host.positionProtectionBook()) || account == address(0) || request.isClose
                || request.bounds.expectedConfigHash != bytes32(0)
        ) {
            revert OrderRouter__Unauthorized();
        }
        return _commitOrder(host, account, request, true, true);
    }

    /// @dev Permanent identity is resolved before current-state validation so an exact replay remains unconditional.
    function _commitOrder(
        IOrderLiquidationBatchHost host,
        address account,
        OrderV2Types.OrderRequest calldata request,
        bool enforceProtectionLock,
        bool allowInternalConfigWildcard
    ) private returns (uint64 orderId) {
        IOrderLifecycleBook book = host.lifecycleBook();
        (OrderV2Types.ClientIntentResolution resolution, uint64 resolvedOrderId, bytes32 suppliedIntentHash) =
            book.resolveClientIntent(account, request);
        if (resolution == OrderV2Types.ClientIntentResolution.ExactReplay) {
            return resolvedOrderId;
        }
        if (resolution == OrderV2Types.ClientIntentResolution.Conflict) {
            OrderV2Types.ClientIntent memory existing = book.clientIntent(account, request.clientOrderId);
            revert IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict(
                account, request.clientOrderId, existing.intentHash, suppliedIntentHash
            );
        }

        _validateFreshRequest(host, account, request, enforceProtectionLock, allowInternalConfigWildcard);
        uint256 executionBountyUsdc = request.isClose
            ? _validatedCloseBounty(host, account, request.side, request.sizeDelta)
            : _validatedOpenBounty(host, account, request.side, request.sizeDelta, request.marginDelta);
        if (executionBountyUsdc > request.bounds.maxExecutionBountyUsdc) {
            revert IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound(
                executionBountyUsdc, request.bounds.maxExecutionBountyUsdc
            );
        }
        if (executionBountyUsdc > request.bounds.maxGrossAccountDebitUsdc) {
            revert OrderRouter__ExecutionBountyAboveGrossDebit(
                executionBountyUsdc, request.bounds.maxGrossAccountDebitUsdc
            );
        }

        orderId = host.nextCommitId();
        (uint64 registeredOrderId,, bool replayed) =
            book.registerPending(account, orderId, request, executionBountyUsdc);
        if (replayed || registeredOrderId != orderId) {
            revert IOrderLifecycleBook.OrderLifecycleBook__OrderIdAlreadyUsed(orderId);
        }
        _queueCommittedOrder(host, account, orderId, request, executionBountyUsdc);
    }

    function _validateFreshRequest(
        IOrderLiquidationBatchHost host,
        address account,
        OrderV2Types.OrderRequest calldata request,
        bool enforceProtectionLock,
        bool allowInternalConfigWildcard
    ) private view {
        if (request.clientOrderId == bytes32(0)) {
            revert OrderRouter__ZeroClientOrderId();
        }
        if (request.targetPrice == 0) {
            revert OrderRouter__ZeroTargetPrice();
        }

        OrderV2Types.ExecutionBounds calldata bounds = request.bounds;
        if (
            uint256(bounds.validUntil) <= block.timestamp
                || uint256(bounds.validUntil) - block.timestamp > host.maxOrderAge()
        ) {
            revert OrderRouter__InvalidValidUntil();
        }
        uint8 executionModes = bounds.allowedExecutionModes;
        if (executionModes == 0 || (executionModes & ~ALL_V2_EXECUTION_MODES) != 0) {
            revert OrderRouter__InvalidExecutionModeMask();
        }
        bytes32 currentConfigHash = host.lifecycleBook().currentExecutionConfigHash();
        if (
            (!allowInternalConfigWildcard && bounds.expectedConfigHash == bytes32(0))
                || (bounds.expectedConfigHash != bytes32(0) && bounds.expectedConfigHash != currentConfigHash)
        ) {
            revert OrderRouter__ExecutionConfigMismatch(bounds.expectedConfigHash, currentConfigHash);
        }
        if (bounds.maxPostLeverageBps == 0) {
            revert OrderRouter__ZeroPostLeverageBound();
        }

        OrderValidationLib.validateBaseCommit(request.sizeDelta, request.marginDelta, request.isClose);
        if (enforceProtectionLock && host.positionProtectionBook().activePositionProtectionId(account) != 0) {
            revert OrderRouter__ProtectionActive();
        }
        if (!request.isClose) {
            _validateOpenCommitAllowed(host);
        }
    }

    function _validateOpenCommitAllowed(
        IOrderLiquidationBatchHost host
    ) private view {
        if (IOrderRouterEmergencyAdmin(host.admin()).paused()) {
            revert Pausable.EnforcedPause();
        }
        ICfdEngineCore engine = host.engine();
        if (engine.degradedMode()) {
            revert OrderRouter__DegradedMode();
        }
        IPletherOracle oracle = host.pletherOracle();
        if (oracle.getOrderExecutionPolicy(false).closeOnly) {
            revert OrderRouter__CloseOnlyWindow();
        }
        IHousePool pool = oracle.housePool();
        if (!pool.canIncreaseRisk()) {
            if (!pool.isSeedLifecycleComplete()) {
                revert OrderRouter__NotInSeedLifecycle();
            }
            revert OrderRouter__VaultRiskBlocked();
        }
    }

    function _validatedCloseBounty(
        IOrderLiquidationBatchHost host,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) private view returns (uint256 executionBountyUsdc) {
        ICfdEngineCore engine = host.engine();
        QueuedPositionView memory queuedPosition = _queuedPosition(host, engine, account);
        OrderValidationLib.validateCloseCommit(
            queuedPosition.exists, queuedPosition.size, queuedPosition.side, side, sizeDelta
        );

        uint256 commitPrice = _commitReferencePrice(engine);
        (,,,,,, uint256 minBountyUsdc, uint256 bountyBps,,) = engine.riskParams();
        uint256 minNotionalUsdc = Math.mulDiv(minBountyUsdc, 10_000, bountyBps, Math.Rounding.Ceil);
        uint256 minCloseSizeDelta =
            Math.mulDiv(minNotionalUsdc, DecimalConstants.USDC_TO_TOKEN_SCALE, commitPrice, Math.Rounding.Ceil);
        if (sizeDelta < queuedPosition.size && sizeDelta < minCloseSizeDelta) {
            revert OrderRouter__CommitValidation(11);
        }
        return host.closeOrderExecutionBountyUsdc();
    }

    function _queuedPosition(
        IOrderLiquidationBatchHost host,
        ICfdEngineCore engine,
        address account
    ) private view returns (QueuedPositionView memory queuedPosition) {
        (uint256 positionSize,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (positionSize != 0) {
            queuedPosition.exists = true;
            queuedPosition.side = side;
            queuedPosition.size = positionSize;
        }

        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
        for (uint64 orderId = host.accountHeadOrderId(account); orderId != 0;) {
            (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextOrderId) =
                host.getPendingOrderView(orderId);
            if (riskOffCutoff == 0 || orderId > riskOffCutoff || pending.isClose) {
                if (pending.isClose) {
                    if (queuedPosition.exists && pending.side == queuedPosition.side) {
                        queuedPosition.size =
                            queuedPosition.size > pending.sizeDelta ? queuedPosition.size - pending.sizeDelta : 0;
                        if (queuedPosition.size == 0) {
                            queuedPosition.exists = false;
                        }
                    }
                } else if (!queuedPosition.exists || queuedPosition.size == 0) {
                    queuedPosition.exists = true;
                    queuedPosition.side = pending.side;
                    queuedPosition.size = pending.sizeDelta;
                } else if (pending.side == queuedPosition.side) {
                    queuedPosition.size += pending.sizeDelta;
                }
            }
            orderId = nextOrderId;
        }
    }

    function _validatedOpenBounty(
        IOrderLiquidationBatchHost host,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta
    ) private view returns (uint256 executionBountyUsdc) {
        ICfdEngineCore engine = host.engine();
        uint256 commitPrice = _commitReferencePrice(engine);
        uint256 notionalUsdc = (sizeDelta * commitPrice) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        if (notionalUsdc < host.minOpenNotionalUsdc()) {
            revert OrderRouter__CommitValidation(11);
        }

        uint64 commitMarkTime = engine.lastMarkTime();
        if (commitMarkTime != 0) {
            IPletherOracle.PolicySnapshot memory policy = host.pletherOracle().getOrderExecutionPolicy(false);
            if (!OracleFreshnessPolicyLib.isStale(commitMarkTime, policy.maxStaleness, block.timestamp)) {
                CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = host.engineLensForCommit()
                    .previewOpenFailurePolicyCategory(
                        account, side, sizeDelta, marginDelta, commitPrice, commitMarkTime
                    );
                uint8 revertCode = host.engineLensForCommit()
                    .previewOpenRevertCode(account, side, sizeDelta, marginDelta, commitPrice, commitMarkTime);
                if (OrderFailurePolicyLib.isPredictablyInvalidOpen(failureCategory)) {
                    revert OrderRouter__PredictableOpenInvalid(revertCode);
                }
            }
        }

        executionBountyUsdc = (notionalUsdc * host.openOrderExecutionBountyBps()) / 10_000;
        uint256 minimumBountyUsdc = host.minOpenOrderExecutionBountyUsdc();
        if (executionBountyUsdc < minimumBountyUsdc) {
            executionBountyUsdc = minimumBountyUsdc;
        }
        uint256 maximumBountyUsdc = host.maxOpenOrderExecutionBountyUsdc();
        return executionBountyUsdc > maximumBountyUsdc ? maximumBountyUsdc : executionBountyUsdc;
    }

    function _commitReferencePrice(
        ICfdEngineCore engine
    ) private view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }
        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _queueCommittedOrder(
        IOrderLiquidationBatchHost host,
        address account,
        uint64 orderId,
        OrderV2Types.OrderRequest calldata request,
        uint256 executionBountyUsdc
    ) private {
        bytes memory itemCall = abi.encodeWithSelector(
            IOrderLiquidationBatchHost.executeCommitOrderItem.selector,
            orderId,
            account,
            request.sizeDelta,
            request.marginDelta,
            request.targetPrice,
            request.side,
            request.isClose,
            executionBountyUsdc
        );
        (bool recorded, bytes memory revertData) = address(host).call(itemCall);
        if (!recorded) {
            assembly ("memory-safe") {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }
    }

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
            _registerProtectionTrigger(host, protectionId, linkedOrderId, plan);
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

    /// @dev Registers a protocol-native close intent before its independently revertible Router queue write.
    ///      The zero expected-config hash is an internal-only wildcard: public commits reject it and only the Router
    ///      may mutate the lifecycle Book. The enclosing mark-refresh transaction rolls Book activation and this
    ///      registration back together if the subsequent queue write or keeper credit fails.
    function _registerProtectionTrigger(
        IOrderLiquidationBatchHost host,
        uint64 protectionId,
        uint64 linkedOrderId,
        IPositionProtectionBook.TriggerPlan memory plan
    ) private {
        OrderV2Types.OrderRequest memory request;
        request.clientOrderId = keccak256(
            abi.encode(
                "PLETHER_POSITION_PROTECTION_TRIGGER_V2",
                block.chainid,
                address(this),
                plan.account,
                protectionId,
                linkedOrderId
            )
        );
        request.side = plan.side;
        request.sizeDelta = plan.size;
        request.targetPrice = plan.side == CfdTypes.Side.BULL ? host.engine().CAP_PRICE() : 1;
        request.isClose = true;
        request.bounds.validUntil = uint64(block.timestamp + host.maxOrderAge());
        request.bounds.allowedExecutionModes = 1 | 2 | 4;
        request.bounds.expectedConfigHash = bytes32(0);
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;

        (uint64 resolvedOrderId,, bool replayed) =
            host.lifecycleBook().registerPending(plan.account, linkedOrderId, request, plan.executionBountyUsdc);
        if (replayed || resolvedOrderId != linkedOrderId) {
            revert IOrderLifecycleBook.OrderLifecycleBook__OrderIdAlreadyUsed(linkedOrderId);
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
        // Read after the oracle and its refund callback: an authorized callback may advance the cutoff.
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
        host.executeLiquidationBatchItem(
            account, snapshot.price, snapshot.price, snapshot.markPrice, snapshot.publishTime, msg.sender, riskOffCutoff
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
        IPletherOracle.LiquidationBatchSnapshot memory snapshot =
            host.pletherOracle().updateLiquidationBatchPrice{value: msg.value}(msg.sender, pythUpdateData);
        host.engine().updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        // Honor any persistent cutoff advanced during the oracle/refund interaction.
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(host.admin()).riskOffOrderCutoff();
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
                account,
                snapshot.bullPrice,
                snapshot.bearPrice,
                snapshot.markPrice,
                snapshot.publishTime,
                msg.sender,
                riskOffCutoff
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
        (bool ok,) = payable(recipient).call{value: amount, gas: 30_000}("");
        if (!ok) {
            IOrderDelegatedLogicRefundAdmin(admin).creditClaimableEth{value: amount}(recipient, amount);
        }
    }

}
