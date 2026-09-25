// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

/// @dev Minimal Router surface used to keep execution-config hashing outside size-constrained Router bytecode.
interface IOrderLifecycleRouterConfigView {

    function policyEvaluator() external view returns (address);

    function executionSidecar() external view returns (address);

    function pletherOracle() external view returns (address);

    function admin() external view returns (address);

}

/// @dev Minimal Engine surface used by the execution-config digest.
interface IOrderLifecycleEngineConfigView {

    function planner() external view returns (address);

    function settlementSidecar() external view returns (address);

    function terminalNavBook() external view returns (address);

    function admin() external view returns (address);

    function protocolTreasury() external view returns (address);

}

/// @dev Common finalized-configuration version surface exposed by both immutable admin contracts.
interface IOrderLifecycleAdminConfigView {

    function activeConfigVersion() external view returns (uint64);

}

/// @dev Execution-critical HousePool policy included in the pinned configuration digest.
interface IOrderLifecyclePoolConfigView {

    function markStalenessLimit() external view returns (uint256);

}

/// @title OrderLifecycleBook
/// @notice Immutable Router-owned registry for V2 idempotency and terminal execution evidence.
/// @dev This contract holds no funds and intentionally has no owner, upgrade, migration, or arbitrary mutation path.
/// @custom:security-contact contact@plether.com
contract OrderLifecycleBook is IOrderLifecycleBook {

    /// @inheritdoc IOrderLifecycleBook
    bytes32 public constant override INTENT_TYPEHASH = keccak256(
        "PletherOrderIntentV3(uint256 chainId,address router,address account,bytes32 clientOrderId,uint8 side,"
        "uint256 sizeDelta,uint256 marginDelta,uint256 targetPrice,bool isClose,uint8 closeMode,uint64 validUntil,"
        "uint8 allowedExecutionModes,bytes32 expectedConfigHash,uint256 maxExecutionBountyUsdc,"
        "uint256 maxExecutionNotionalUsdc,uint256 maxGrossAccountDebitUsdc,uint256 maxActionChargeUsdc,"
        "uint256 maxExplicitFeesUsdc,uint256 maxPostPositionSize,uint256 minPostSettlementBalanceUsdc,"
        "uint256 minPostPositionEquityUsdc,uint32 maxPostLeverageBps)"
    );

    /// @inheritdoc IOrderLifecycleBook
    bytes32 public constant override RECEIPT_TYPEHASH = keccak256(
        "PletherOrderReceiptV4(uint256 chainId,address book,address router,uint64 terminalBlock,uint64 terminalTime,"
        "OrderReceipt receipt)"
    );

    /// @inheritdoc IOrderLifecycleBook
    bytes32 public constant override CONFIG_SCHEMA_HASH = keccak256("PletherExecutionConfigV4");

    /// @inheritdoc IOrderLifecycleBook
    address public immutable override ROUTER;
    mapping(address => uint64) public override pendingTerminalExitId;

    /// @inheritdoc IOrderLifecycleBook
    address public immutable override ENGINE;

    /// @inheritdoc IOrderLifecycleBook
    address public immutable override CLEARINGHOUSE;

    /// @inheritdoc IOrderLifecycleBook
    address public immutable override HOUSE_POOL;

    /// @notice Permanent account-scoped client id commitments with enforced public and protocol subdomains.
    mapping(address account => mapping(bytes32 clientOrderId => OrderV2Types.ClientIntent intent)) private
        _clientIntents;

    /// @dev Bounties already fit uint96 in the clearinghouse. Other amounts retain their full uint256 domain.
    ///      Pre-commitment custody is exactly post-commitment custody plus collected carry.
    struct StoredCommitment {
        uint256 carryCollectedUsdc;
        uint256 carryOutstandingUsdc;
        uint96 bountyFromFreeUsdc;
        uint96 bountyFromPledgeUsdc;
        uint256 settlementAfterUsdc;
        uint256 freeSettlementAfterUsdc;
    }

    /// @dev Internal representation only; the public PendingIntent tuple remains unchanged.
    struct StoredPendingIntent {
        address account;
        OrderV2Types.CloseMode closeMode;
        uint64 positionEpoch;
        CfdTypes.Side positionSide;
        bytes32 clientOrderId;
        bytes32 intentHash;
        uint256 executionBountyUsdc;
        uint256 positionSize;
        StoredCommitment commitment;
        OrderV2Types.ExecutionBounds bounds;
    }

    /// @notice Ephemeral policy and identity required to authenticate terminal settlement.
    mapping(uint64 orderId => StoredPendingIntent intent) private _pendingIntents;

    /// @notice Ephemeral Router-authenticated marker for retryable position-protection child orders.
    mapping(uint64 orderId => bool registered) private _protectionAttempts;

    /// @notice Permanent compact terminal outcomes.
    mapping(uint64 orderId => OrderV2Types.CompactOutcome terminalOutcome) private _outcomes;

    modifier onlyRouter() {
        if (msg.sender != ROUTER) {
            revert OrderLifecycleBook__Unauthorized();
        }
        _;
    }

    /// @notice Binds the predicted Router and its immutable V2 protocol dependencies.
    /// @dev The Book is deployed immediately before its Router to keep Book creation code out of Router initcode.
    ///      The Router constructor validates every binding before accepting this instance.
    constructor(
        address router_,
        address engine_,
        address clearinghouse_,
        address housePool_
    ) {
        if (router_ == address(0) || engine_ == address(0) || clearinghouse_ == address(0) || housePool_ == address(0))
        {
            revert OrderLifecycleBook__ZeroDependency();
        }
        ROUTER = router_;
        ENGINE = engine_;
        CLEARINGHOUSE = clearinghouse_;
        HOUSE_POOL = housePool_;
    }

    /// @inheritdoc IOrderLifecycleBook
    function currentExecutionConfigHash() external view override returns (bytes32 configHash) {
        IOrderLifecycleRouterConfigView router = IOrderLifecycleRouterConfigView(ROUTER);
        IOrderLifecycleEngineConfigView engine = IOrderLifecycleEngineConfigView(ENGINE);
        address routerAdmin = router.admin();
        address engineAdmin = engine.admin();
        // Both fragments contain only static ABI values. Concatenating their encodings is byte-for-byte equivalent to
        // one flat abi.encode call, while keeping low-optimization documentation builds below the Yul stack limit.
        bytes memory routerConfig = abi.encode(
            CONFIG_SCHEMA_HASH,
            block.chainid,
            address(this),
            ROUTER,
            ENGINE,
            CLEARINGHOUSE,
            HOUSE_POOL,
            router.policyEvaluator(),
            router.executionSidecar(),
            router.pletherOracle(),
            routerAdmin,
            IOrderLifecycleAdminConfigView(routerAdmin).activeConfigVersion()
        );
        bytes memory engineConfig = abi.encode(
            engine.planner(),
            engine.settlementSidecar(),
            engine.terminalNavBook(),
            engineAdmin,
            IOrderLifecycleAdminConfigView(engineAdmin).activeConfigVersion(),
            engine.protocolTreasury(),
            IOrderLifecyclePoolConfigView(HOUSE_POOL).markStalenessLimit()
        );
        return keccak256(bytes.concat(routerConfig, engineConfig));
    }

    /// @inheritdoc IOrderLifecycleBook
    function hashOrderRequest(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) public view override returns (bytes32 intentHash) {
        // OrderRequest and its nested ExecutionBounds contain only static ABI values in the canonical field order.
        // Encoding the tuple directly therefore produces the same flat words named by INTENT_TYPEHASH without keeping
        // all twenty-two values live on the compiler stack.
        return keccak256(abi.encode(INTENT_TYPEHASH, block.chainid, ROUTER, account, request));
    }

    /// @inheritdoc IOrderLifecycleBook
    function resolveClientIntent(
        address account,
        OrderV2Types.OrderRequest calldata request
    )
        external
        view
        override
        returns (OrderV2Types.ClientIntentResolution resolution, uint64 orderId, bytes32 intentHash)
    {
        intentHash = hashOrderRequest(account, request);
        OrderV2Types.ClientIntent memory existing = _clientIntents[account][request.clientOrderId];
        orderId = existing.orderId;
        if (orderId == 0) {
            return (OrderV2Types.ClientIntentResolution.Unused, 0, intentHash);
        }
        if (existing.intentHash == intentHash) {
            return (OrderV2Types.ClientIntentResolution.ExactReplay, orderId, intentHash);
        }
        return (OrderV2Types.ClientIntentResolution.Conflict, orderId, intentHash);
    }

    /// @inheritdoc IOrderLifecycleBook
    function registerPending(
        address account,
        uint64 proposedOrderId,
        OrderV2Types.OrderRequest calldata request,
        uint256 executionBountyUsdc
    ) external override onlyRouter returns (uint64 resolvedOrderId, bytes32 intentHash, bool replayed) {
        if (account == address(0)) {
            revert OrderLifecycleBook__ZeroAccount();
        }
        if (request.clientOrderId == bytes32(0)) {
            revert OrderLifecycleBook__ZeroClientOrderId();
        }

        intentHash = hashOrderRequest(account, request);
        OrderV2Types.ClientIntent memory existing = _clientIntents[account][request.clientOrderId];
        if (existing.orderId != 0) {
            if (existing.intentHash != intentHash) {
                revert OrderLifecycleBook__ClientIdConflict(
                    account, request.clientOrderId, existing.intentHash, intentHash
                );
            }
            return (existing.orderId, intentHash, true);
        }

        bool protocolIntent = request.bounds.expectedConfigHash == bytes32(0);
        if (OrderV2Types.isProtocolClientOrderId(request.clientOrderId) != protocolIntent) {
            revert OrderLifecycleBook__ClientIdDomainMismatch(request.clientOrderId, protocolIntent);
        }

        if (proposedOrderId == 0) {
            revert OrderLifecycleBook__ZeroOrderId();
        }
        if (executionBountyUsdc > request.bounds.maxExecutionBountyUsdc) {
            revert OrderLifecycleBook__ExecutionBountyAboveBound(
                executionBountyUsdc, request.bounds.maxExecutionBountyUsdc
            );
        }
        if (
            _pendingIntents[proposedOrderId].account != address(0)
                || _outcomes[proposedOrderId].status != OrderV2Types.LifecycleStatus.None
        ) {
            revert OrderLifecycleBook__OrderIdAlreadyUsed(proposedOrderId);
        }

        _clientIntents[account][request.clientOrderId] =
            OrderV2Types.ClientIntent({orderId: proposedOrderId, intentHash: intentHash});
        StoredPendingIntent storage pending = _pendingIntents[proposedOrderId];
        pending.account = account;
        pending.clientOrderId = request.clientOrderId;
        pending.intentHash = intentHash;
        pending.executionBountyUsdc = executionBountyUsdc;
        pending.closeMode = request.closeMode;
        if (request.closeMode == OrderV2Types.CloseMode.CallerPaidFullExit) {
            pendingTerminalExitId[account] = proposedOrderId;
        }
        pending.bounds = request.bounds;

        emit IntentRegistered(proposedOrderId, account, request.clientOrderId, intentHash, executionBountyUsdc, request);
        return (proposedOrderId, intentHash, false);
    }

    function recordCommitment(
        uint64 orderId,
        CfdEnginePlanTypes.CloseCommitment calldata effects,
        uint64 epoch,
        CfdTypes.Side side,
        uint256 size
    ) external onlyRouter {
        StoredPendingIntent storage pending = _pendingIntents[orderId];
        if (pending.account == address(0)) {
            revert OrderLifecycleBook__OrderNotPending(orderId);
        }
        uint256 gross = effects.carryCollectedUsdc + pending.executionBountyUsdc;
        if (gross > pending.bounds.maxGrossAccountDebitUsdc) {
            revert OrderLifecycleBook__CommitmentBoundExceeded(
                OrderV2Types.ConstraintKind.GrossAccountDebit, gross, pending.bounds.maxGrossAccountDebitUsdc
            );
        }
        if (effects.carryCollectedUsdc > pending.bounds.maxActionChargeUsdc) {
            revert OrderLifecycleBook__CommitmentBoundExceeded(
                OrderV2Types.ConstraintKind.ActionCharge, effects.carryCollectedUsdc, pending.bounds.maxActionChargeUsdc
            );
        }
        if (
            effects.settlementBeforeUsdc != effects.settlementAfterUsdc + effects.carryCollectedUsdc
                || effects.bountyFromFreeUsdc + effects.bountyFromPledgeUsdc != pending.executionBountyUsdc
        ) {
            revert OrderLifecycleBook__InvalidCommitmentEffects();
        }
        pending.commitment = StoredCommitment({
            carryCollectedUsdc: effects.carryCollectedUsdc,
            carryOutstandingUsdc: effects.carryOutstandingUsdc,
            bountyFromFreeUsdc: SafeCast.toUint96(effects.bountyFromFreeUsdc),
            bountyFromPledgeUsdc: SafeCast.toUint96(effects.bountyFromPledgeUsdc),
            settlementAfterUsdc: effects.settlementAfterUsdc,
            freeSettlementAfterUsdc: effects.freeSettlementAfterUsdc
        });
        if (pending.closeMode == OrderV2Types.CloseMode.CallerPaidFullExit) {
            pending.positionEpoch = epoch;
            pending.positionSide = side;
            pending.positionSize = size;
        }
    }

    /// @inheritdoc IOrderLifecycleBook
    function registerProtectionAttempt(
        uint64 orderId
    ) external override onlyRouter {
        StoredPendingIntent storage pending = _pendingIntents[orderId];
        if (pending.account == address(0) || pending.bounds.expectedConfigHash != bytes32(0)) {
            revert OrderLifecycleBook__InvalidProtectionAttempt(orderId);
        }
        if (_protectionAttempts[orderId]) {
            revert OrderLifecycleBook__ProtectionAttemptAlreadyRegistered(orderId);
        }
        _protectionAttempts[orderId] = true;
        emit ProtectionAttemptRegistered(orderId);
    }

    /// @inheritdoc IOrderLifecycleBook
    function isProtectionAttempt(
        uint64 orderId
    ) external view override returns (bool registered) {
        return _protectionAttempts[orderId];
    }

    /// @inheritdoc IOrderLifecycleBook
    function finalize(
        OrderV2Types.OrderReceipt calldata receipt
    ) external override onlyRouter returns (bytes32 receiptHash) {
        StoredPendingIntent storage pending = _pendingIntents[receipt.orderId];
        if (pending.account == address(0)) {
            revert OrderLifecycleBook__OrderNotPending(receipt.orderId);
        }
        if (
            receipt.account != pending.account || receipt.clientOrderId != pending.clientOrderId
                || receipt.intentHash != pending.intentHash
                || receipt.expectedConfigHash != pending.bounds.expectedConfigHash
                || receipt.closeMode != pending.closeMode
                || keccak256(abi.encode(receipt.commitment))
                    != keccak256(abi.encode(_expandCommitment(pending.commitment)))
                || receipt.bounty.bountyEntitlementUsdc != pending.executionBountyUsdc
                || (receipt.reason != OrderV2Types.TerminalReason.ExpiredReservationMismatch
                    && receipt.bountyUsdc != pending.executionBountyUsdc)
        ) {
            revert OrderLifecycleBook__ReceiptIdentityMismatch(receipt.orderId);
        }
        _validateTerminalOutcome(receipt, pending.bounds);
        if (block.number > type(uint64).max || block.timestamp > type(uint64).max) {
            revert OrderLifecycleBook__TerminalClockOverflow();
        }

        uint64 terminalBlock = uint64(block.number);
        uint64 terminalTime = uint64(block.timestamp);
        receiptHash = keccak256(
            abi.encode(RECEIPT_TYPEHASH, block.chainid, address(this), ROUTER, terminalBlock, terminalTime, receipt)
        );

        OrderV2Types.FailureDetails calldata failure = receipt.failure;
        _outcomes[receipt.orderId] = OrderV2Types.CompactOutcome({
            account: receipt.account,
            clientOrderId: receipt.clientOrderId,
            intentHash: receipt.intentHash,
            expectedConfigHash: receipt.expectedConfigHash,
            observedConfigHash: receipt.observedConfigHash,
            status: receipt.status,
            reason: receipt.reason,
            executionMode: receipt.executionMode,
            priceSource: receipt.priceSource,
            bountyDisposition: receipt.bountyDisposition,
            terminalBlock: terminalBlock,
            terminalTime: terminalTime,
            oraclePublishTime: receipt.oraclePublishTime,
            executor: receipt.executor,
            bountyRecipient: receipt.bountyRecipient,
            executionPrice: receipt.executionPrice,
            bountyUsdc: receipt.bountyUsdc,
            failureSelector: failure.selector,
            failureCategory: failure.category,
            failureCode: failure.code,
            failedConstraint: failure.constraint,
            revertDataHash: failure.revertDataHash,
            receiptHash: receiptHash
        });
        if (
            pending.closeMode == OrderV2Types.CloseMode.CallerPaidFullExit
                && pendingTerminalExitId[receipt.account] == receipt.orderId
        ) {
            delete pendingTerminalExitId[receipt.account];
        }
        delete _pendingIntents[receipt.orderId];
        delete _protectionAttempts[receipt.orderId];

        emit OrderFinalized(
            receipt.orderId, receipt.account, receipt.clientOrderId, receiptHash, terminalBlock, terminalTime, receipt
        );
    }

    /// @inheritdoc IOrderLifecycleBook
    function clientIntent(
        address account,
        bytes32 clientOrderId
    ) external view override returns (OrderV2Types.ClientIntent memory intent) {
        return _clientIntents[account][clientOrderId];
    }

    /// @inheritdoc IOrderLifecycleBook
    function pendingIntent(
        uint64 orderId
    ) external view override returns (OrderV2Types.PendingIntent memory intent) {
        StoredPendingIntent storage stored = _pendingIntents[orderId];
        intent.account = stored.account;
        intent.clientOrderId = stored.clientOrderId;
        intent.intentHash = stored.intentHash;
        intent.executionBountyUsdc = stored.executionBountyUsdc;
        intent.closeMode = stored.closeMode;
        if (intent.closeMode == OrderV2Types.CloseMode.CallerPaidFullExit) {
            intent.positionEpoch = stored.positionEpoch;
            intent.positionSide = stored.positionSide;
            intent.positionSize = stored.positionSize;
        }
        intent.commitment = _expandCommitment(stored.commitment);
        intent.bounds = stored.bounds;
    }

    function _expandCommitment(
        StoredCommitment storage stored
    ) private view returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        effects.carryCollectedUsdc = stored.carryCollectedUsdc;
        effects.carryOutstandingUsdc = stored.carryOutstandingUsdc;
        effects.bountyFromFreeUsdc = stored.bountyFromFreeUsdc;
        effects.bountyFromPledgeUsdc = stored.bountyFromPledgeUsdc;
        effects.settlementAfterUsdc = stored.settlementAfterUsdc;
        effects.settlementBeforeUsdc = effects.settlementAfterUsdc + effects.carryCollectedUsdc;
        effects.freeSettlementAfterUsdc = stored.freeSettlementAfterUsdc;
    }

    /// @inheritdoc IOrderLifecycleBook
    function pendingPolicy(
        uint64 orderId
    ) external view override returns (OrderV2Types.ExecutionBounds memory bounds) {
        return _pendingIntents[orderId].bounds;
    }

    /// @inheritdoc IOrderLifecycleBook
    function lifecycleStatus(
        uint64 orderId
    ) external view override returns (OrderV2Types.LifecycleStatus status) {
        if (_pendingIntents[orderId].account != address(0)) {
            return OrderV2Types.LifecycleStatus.Pending;
        }
        return _outcomes[orderId].status;
    }

    /// @inheritdoc IOrderLifecycleBook
    function outcome(
        uint64 orderId
    ) external view override returns (OrderV2Types.CompactOutcome memory terminalOutcome) {
        return _outcomes[orderId];
    }

    /// @notice Enforces monotonic and semantically valid terminal transitions.
    function _validateTerminalOutcome(
        OrderV2Types.OrderReceipt calldata receipt,
        OrderV2Types.ExecutionBounds storage bounds
    ) private view {
        if (receipt.executor == address(0)) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
        if (receipt.reason == OrderV2Types.TerminalReason.ExpiredReservationMismatch) {
            if (
                receipt.status != OrderV2Types.LifecycleStatus.Failed || block.timestamp <= bounds.validUntil
                    || receipt.bounty.discrepancy == OrderV2Types.ReservationDiscrepancy.None
                    || receipt.bounty.bountyPaidUsdc != 0 || receipt.bounty.bountyRetainedUsdc != 0
                    || receipt.bounty.bountyForfeitedUsdc != 0
                    || receipt.bountyUsdc != receipt.bounty.bountyRefundedUsdc || !_isEmptyFailure(receipt.failure)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            if (receipt.bountyUsdc == 0
                    ? (receipt.bountyRecipient != address(0)
                            || receipt.bountyDisposition != OrderV2Types.BountyDisposition.None)
                    : (receipt.bountyRecipient != receipt.account
                            || receipt.bountyDisposition != OrderV2Types.BountyDisposition.RefundedToAccount)) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            _validateNoPriceEvidence(receipt);
            return;
        }
        if (
            receipt.bounty.discrepancy != OrderV2Types.ReservationDiscrepancy.None
                || receipt.bounty.bountyPaidUsdc + receipt.bounty.bountyRefundedUsdc + receipt.bounty.bountyRetainedUsdc
                        + receipt.bounty.bountyForfeitedUsdc != receipt.bountyUsdc
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
        _validateBountyDisposition(receipt);

        if (receipt.status == OrderV2Types.LifecycleStatus.Executed) {
            if (
                receipt.reason != OrderV2Types.TerminalReason.Executed || !receipt.priceReachedEngine
                    || !_isEmptyFailure(receipt.failure)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            _validateOracleEvidence(receipt);
            return;
        }
        if (
            receipt.status != OrderV2Types.LifecycleStatus.Failed || receipt.reason == OrderV2Types.TerminalReason.None
                || receipt.reason == OrderV2Types.TerminalReason.Executed
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }

        OrderV2Types.TerminalReason reason = receipt.reason;
        if (reason == OrderV2Types.TerminalReason.RiskOff) {
            _validateNoPriceEvidence(receipt);
            if (!_isEmptyFailure(receipt.failure)) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (reason == OrderV2Types.TerminalReason.AccountLiquidated) {
            if (
                receipt.executionMode != OrderV2Types.ExecutionMode.None
                    || receipt.priceSource != OrderV2Types.PriceSource.Liquidation || receipt.executionPrice == 0
                    || receipt.neutralMarkPrice == 0 || receipt.oraclePublishTime == 0 || receipt.priceReachedEngine
                    || !_isEmptyFailure(receipt.failure)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (
            reason == OrderV2Types.TerminalReason.Expired || reason == OrderV2Types.TerminalReason.ConfigMismatch
                || reason == OrderV2Types.TerminalReason.TerminalPositionChanged
        ) {
            _validateNoPriceEvidence(receipt);
            if (
                !_isEmptyFailure(receipt.failure)
                    || (reason == OrderV2Types.TerminalReason.ConfigMismatch
                        && receipt.expectedConfigHash == receipt.observedConfigHash)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }

        _validateOracleEvidence(receipt);
        if (reason == OrderV2Types.TerminalReason.Slippage) {
            if (receipt.priceReachedEngine || !_isEmptyFailure(receipt.failure)) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (reason == OrderV2Types.TerminalReason.ExecutionModeDisallowed) {
            OrderV2Types.FailureDetails calldata failure = receipt.failure;
            if (
                receipt.priceReachedEngine
                    || failure.selector
                        != ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed.selector
                    || failure.category != 0 || failure.code != 0
                    || failure.constraint != OrderV2Types.ConstraintKind.None
                    || failure.actual != uint256(receipt.executionMode) || failure.limit != bounds.allowedExecutionModes
                    || failure.revertDataHash == bytes32(0)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (reason == OrderV2Types.TerminalReason.ConstraintViolation) {
            OrderV2Types.FailureDetails calldata failure = receipt.failure;
            if (
                receipt.priceReachedEngine
                    || failure.selector
                        != ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector
                    || failure.category != 0 || failure.code != 0
                    || failure.constraint == OrderV2Types.ConstraintKind.None
                    || failure.limit != _constraintLimit(bounds, failure.constraint)
                    || failure.revertDataHash == bytes32(0)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (reason == OrderV2Types.TerminalReason.PlannerRejected) {
            OrderV2Types.FailureDetails calldata failure = receipt.failure;
            if (
                failure.selector != ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector || failure.category == 0
                    || failure.category > 2 || failure.code == 0
                    || failure.constraint != OrderV2Types.ConstraintKind.None || failure.actual != 0
                    || failure.limit != 0 || failure.revertDataHash == bytes32(0)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        revert OrderLifecycleBook__InvalidTerminalOutcome();
    }

    function _validateBountyDisposition(
        OrderV2Types.OrderReceipt calldata receipt
    ) private view {
        OrderV2Types.BountyDisposition disposition = receipt.bountyDisposition;
        if (
            (disposition == OrderV2Types.BountyDisposition.Paid && receipt.bounty.bountyPaidUsdc != receipt.bountyUsdc)
                || (disposition == OrderV2Types.BountyDisposition.RefundedToAccount
                    && receipt.bounty.bountyRefundedUsdc != receipt.bountyUsdc)
                || (disposition == OrderV2Types.BountyDisposition.Forfeited
                    && receipt.bounty.bountyForfeitedUsdc != receipt.bountyUsdc)
                || (disposition == OrderV2Types.BountyDisposition.RetainedForProtectionRetry
                    && receipt.bounty.bountyRetainedUsdc != receipt.bountyUsdc)
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
        if (receipt.bountyUsdc == 0) {
            if (
                (receipt.bountyDisposition != OrderV2Types.BountyDisposition.None
                        && !(receipt.bountyDisposition == OrderV2Types.BountyDisposition.RetainedForProtectionRetry
                            && _protectionAttempts[receipt.orderId])) || receipt.bountyRecipient != address(0)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (receipt.bountyDisposition == OrderV2Types.BountyDisposition.RetainedForProtectionRetry) {
            if (
                !_protectionAttempts[receipt.orderId] || receipt.status != OrderV2Types.LifecycleStatus.Failed
                    || receipt.reason == OrderV2Types.TerminalReason.RiskOff
                    || receipt.reason == OrderV2Types.TerminalReason.AccountLiquidated
                    || receipt.bountyRecipient != address(0)
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (receipt.reason == OrderV2Types.TerminalReason.RiskOff) {
            if (
                receipt.bountyDisposition != OrderV2Types.BountyDisposition.RefundedToAccount
                    || receipt.bountyRecipient != receipt.account
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (receipt.reason == OrderV2Types.TerminalReason.AccountLiquidated) {
            if (
                receipt.bountyDisposition != OrderV2Types.BountyDisposition.Forfeited
                    || receipt.bountyRecipient != IOrderLifecycleEngineConfigView(ENGINE).protocolTreasury()
            ) {
                revert OrderLifecycleBook__InvalidTerminalOutcome();
            }
            return;
        }
        if (
            receipt.bountyDisposition != OrderV2Types.BountyDisposition.Paid
                || receipt.bountyRecipient != receipt.executor
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
    }

    function _validateOracleEvidence(
        OrderV2Types.OrderReceipt calldata receipt
    ) private pure {
        // A zero expectation is the internal protected-order marker; its receipt still carries the observed digest.
        if (
            receipt.executionMode == OrderV2Types.ExecutionMode.None
                || receipt.priceSource != OrderV2Types.PriceSource.OracleExecution || receipt.executionPrice == 0
                || receipt.neutralMarkPrice == 0 || receipt.oraclePublishTime == 0
                || (receipt.expectedConfigHash != bytes32(0)
                    && receipt.expectedConfigHash != receipt.observedConfigHash)
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
    }

    function _validateNoPriceEvidence(
        OrderV2Types.OrderReceipt calldata receipt
    ) private pure {
        if (
            receipt.executionMode != OrderV2Types.ExecutionMode.None
                || receipt.priceSource != OrderV2Types.PriceSource.None || receipt.executionPrice != 0
                || receipt.oraclePublishTime != 0 || receipt.priceReachedEngine
        ) {
            revert OrderLifecycleBook__InvalidTerminalOutcome();
        }
    }

    function _isEmptyFailure(
        OrderV2Types.FailureDetails calldata failure
    ) private pure returns (bool) {
        return failure.selector == bytes4(0) && failure.category == 0 && failure.code == 0
            && failure.constraint == OrderV2Types.ConstraintKind.None && failure.actual == 0 && failure.limit == 0
            && failure.revertDataHash == bytes32(0);
    }

    function _constraintLimit(
        OrderV2Types.ExecutionBounds storage bounds,
        OrderV2Types.ConstraintKind constraint
    ) private view returns (uint256 limit) {
        if (constraint == OrderV2Types.ConstraintKind.ExecutionBounty) {
            return bounds.maxExecutionBountyUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.ExecutionNotional) {
            return bounds.maxExecutionNotionalUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.GrossAccountDebit) {
            return bounds.maxGrossAccountDebitUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.ActionCharge) {
            return bounds.maxActionChargeUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.ExplicitFees) {
            return bounds.maxExplicitFeesUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.PostPositionSize) {
            return bounds.maxPostPositionSize;
        }
        if (constraint == OrderV2Types.ConstraintKind.PostSettlementBalance) {
            return bounds.minPostSettlementBalanceUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.PostPositionEquity) {
            return bounds.minPostPositionEquityUsdc;
        }
        if (constraint == OrderV2Types.ConstraintKind.PostLeverage) {
            return bounds.maxPostLeverageBps;
        }
        revert OrderLifecycleBook__InvalidTerminalOutcome();
    }

    }
