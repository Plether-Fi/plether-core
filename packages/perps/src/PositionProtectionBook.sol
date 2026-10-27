// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {ExecutionBlockNumberLib} from "@plether/perps/libraries/ExecutionBlockNumberLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";

/// @notice Narrow engine view surface used by position-protection actions and lifecycle validation.
interface IPositionProtectionEngine is ICfdEngineRiskParamsView {

    function clearinghouse() external view returns (address);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function CAP_PRICE() external view returns (uint256);

    function planner() external view returns (address);

    function isFadWindow() external view returns (bool);

    function degradedMode() external view returns (bool);

    function unsettledCarryAssets(
        address account
    ) external view returns (uint256);

    function traderClaimBalanceAssets(
        address account
    ) external view returns (uint256);

    function positionEntryCostAssetAtoms(
        address account
    ) external view returns (uint256);

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitAssets,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

}

/// @notice Dynamic router configuration and accounting views consumed by the position-protection book.
interface IPositionProtectionRouterHost {

    function admin() external view returns (address);

    function pletherOracle() external view returns (IPletherOracle);

    function positionProtectionTriggerBountyAssets() external view returns (uint256);

    function nextCommitId() external view returns (uint64);

    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    function accountHeadOrderId(
        address account
    ) external view returns (uint64);

    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId);

}

/// @notice Book-only bounded-order surface for attached opens and atomic protection cancellation with a full close.
/// @dev The Router authenticates this explicit-account host call by requiring this immutable Book as caller.
interface IPositionProtectionOrderCommitHost {

    function commitProtectedOpen(
        address account,
        OrderV3Types.OrderRequest calldata request
    ) external returns (uint64 orderId);

    function commitProtectedClose(
        address account,
        OrderV3Types.OrderRequest calldata request,
        uint256 triggerBountyRefundAssets
    ) external returns (uint64 orderId);

}

/// @notice Book-only host surface for appending a fresh unpaid protection close attempt.
/// @dev The Router authenticates this explicit-account call by requiring its immutable Book as caller.
interface IPositionProtectionCloseAttemptHost {

    function commitProtectionCloseAttempt(
        uint64 protectionId,
        address account,
        CfdTypes.Side side,
        uint256 size
    ) external returns (uint64 orderId);

}

/// @notice Narrow emergency-pause view exposed by the router's dedicated admin.
interface IPositionProtectionAdmin {

    function paused() external view returns (bool);

}

/// @title PositionProtectionBook
/// @notice Custody-free direct action and lifecycle store for one full-position OCO protection per account.
/// @dev Trigger calls receive ETH only transiently and forward the full call value to the router's ordinary mark-refresh
///      entrypoint. This contract never intentionally custodies tokens or mutates an order queue directly. The immutable
///      router remains responsible for queue mutation and keeper credits. The trigger bounty reads its clearinghouse
///      reservation; protection close attempts carry no execution bounty.
contract PositionProtectionBook is IPositionProtectionBook, IOrderRouterErrors, ReentrancyGuardTransient {

    struct StoredProtection {
        uint64 protectionId;
        uint64 parentOrderId;
        uint64 linkedOrderId;
        address account;
        CfdTypes.Side side;
        uint256 size;
        uint256 takeProfitTriggerPrice;
        uint256 stopLossTriggerPrice;
        PositionProtectionTypes.CloseFinancialLimits closeLimits;
        uint64 armedAt;
        uint64 armedBlock;
        uint64 armedPublishTime;
        uint256 triggerMarkPrice;
        uint64 triggerPublishTime;
        PositionProtectionTypes.PositionProtectionTriggerLeg triggeredLeg;
        PositionProtectionTypes.PositionProtectionStatus status;
    }

    bytes4 private constant UPDATE_MARK_PRICE_SELECTOR = bytes4(keccak256("updateMarkPrice(bytes[])"));

    /// @notice Immutable router authorized to invoke terminal and trigger-activation lifecycle hooks.
    address public immutable ROUTER;
    /// @notice Immutable engine whose cached mark, positions, and risk configuration bind protection validation.
    IPositionProtectionEngine public immutable ENGINE;

    /// @notice Next protection id assigned by a successful creation; starts at one.
    uint64 public nextPositionProtectionId = 1;

    mapping(uint64 protectionId => StoredProtection protection) private _protections;
    mapping(address account => uint64 protectionId) private _activeProtectionIds;
    mapping(uint64 parentOrderId => uint64 protectionId) private _parentProtectionIds;
    mapping(uint64 linkedOrderId => uint64 protectionId) private _attemptProtectionIds;

    /// @notice Deployment requires a nonzero router and engine.
    error PositionProtectionBook__ZeroAddress();
    /// @notice Trigger bounty disagrees with current settings.
    error PositionProtectionBook__BountyMismatch();
    /// @notice An activation supplied a zero or already-bound linked close id.
    error PositionProtectionBook__InvalidLinkedOrder();
    /// @notice A Router host returned an unexpected order id or data for a no-return entrypoint.
    error PositionProtectionBook__InvalidHostResponse();
    /// @notice The Router supplied a reason that cannot represent a failed retryable close attempt.
    error PositionProtectionBook__InvalidTerminalReason();
    /// @notice The accepted live basket has not been installed as the Engine mark.
    error PositionProtectionBook__OracleMarkAhead();

    modifier onlyRouter() {
        _requireRouter();
        _;
    }

    function _requireRouter() private view {
        if (msg.sender != ROUTER) {
            revert OrderRouter__Unauthorized();
        }
    }

    constructor(
        address router,
        address engine
    ) {
        if (router == address(0) || engine == address(0)) {
            revert PositionProtectionBook__ZeroAddress();
        }
        ROUTER = router;
        ENGINE = IPositionProtectionEngine(engine);
    }

    /// @inheritdoc IPositionProtectionActions
    function createPositionProtection(
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external nonReentrant returns (uint64 protectionId) {
        uint256 triggerBountyAssets = _configuredTriggerBounty();
        _clearinghouse().lockReservedSettlement(msg.sender, triggerBountyAssets);
        return _create(msg.sender, params, triggerBountyAssets);
    }

    function _create(
        address account,
        PositionProtectionTypes.PositionProtectionParams memory params,
        uint256 triggerBountyAssets
    ) private returns (uint64 protectionId) {
        _validateProtectionCommitAllowed();
        _requireProtectionAccountAvailable(account, 0);
        _validateBountySnapshot(triggerBountyAssets);

        CfdTypes.Position memory position = _loadPosition(account);
        if (position.size == 0) {
            revert OrderRouter__NoOpenPosition();
        }

        (uint256 cachedMarkPrice, uint256 currentMarkPrice, uint64 currentPublishTime) = _freshProtectionObservation();
        _validateProtectionPrices(position.side, currentMarkPrice, params);
        _validatePostLockRisk(account, position, cachedMarkPrice);

        protectionId = nextPositionProtectionId++;
        StoredProtection storage protection = _protections[protectionId];
        protection.protectionId = protectionId;
        protection.account = account;
        protection.side = position.side;
        protection.size = position.size;
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;
        _setCloseLimits(protection, params.closeLimits);
        _clearinghouse()
            .recordBountyReservation(
                account, IMarginClearinghouse.BountyKind.ProtectionTrigger, protectionId, triggerBountyAssets
            );
        _arm(protection, currentPublishTime);
        _activeProtectionIds[account] = protectionId;

        emit PositionProtectionCreated(
            protectionId, account, 0, params.takeProfitTriggerPrice, params.stopLossTriggerPrice, triggerBountyAssets
        );
        _emitCloseLimitsUpdated(protection);
        _emitArmed(protection);
    }

    /// @inheritdoc IPositionProtectionActions
    function replacePositionProtection(
        uint64 protectionId,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external nonReentrant {
        _replace(msg.sender, protectionId, params);
    }

    function _replace(
        address account,
        uint64 protectionId,
        PositionProtectionTypes.PositionProtectionParams memory params
    ) private {
        _validateProtectionCommitAllowed();
        StoredProtection storage protection = _ownedActiveProtection(protectionId, account);
        PositionProtectionTypes.PositionProtectionStatus status = protection.status;
        if (
            status != PositionProtectionTypes.PositionProtectionStatus.PendingOpen
                && status != PositionProtectionTypes.PositionProtectionStatus.Armed
        ) {
            revert OrderRouter__ProtectionNotArmed();
        }

        if (status == PositionProtectionTypes.PositionProtectionStatus.PendingOpen) {
            uint256 pendingOrders = IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(account);
            if (pendingOrders == 0) {
                revert OrderRouter__ProtectionNotArmed();
            }
            if (pendingOrders != 1) {
                revert OrderRouter__PendingOrdersExist();
            }
            _requireMatchingPendingParent(account, protection.parentOrderId, protection.side, protection.size);
        } else {
            _requireMatchingPosition(protection);
            if (IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(account) != 0) {
                revert OrderRouter__PendingOrdersExist();
            }
        }

        (, uint256 currentMarkPrice, uint64 currentPublishTime) = _freshProtectionObservation();
        _validateProtectionPrices(protection.side, currentMarkPrice, params);
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;
        _setCloseLimits(protection, params.closeLimits);

        if (status == PositionProtectionTypes.PositionProtectionStatus.Armed) {
            _arm(protection, currentPublishTime);
        }

        emit PositionProtectionReplaced(
            protectionId, account, params.takeProfitTriggerPrice, params.stopLossTriggerPrice
        );
        _emitCloseLimitsUpdated(protection);
        if (status == PositionProtectionTypes.PositionProtectionStatus.Armed) {
            _emitArmed(protection);
        }
    }

    /// @inheritdoc IPositionProtectionActions
    function amendLatchedPositionProtectionCloseLimits(
        uint64 protectionId,
        PositionProtectionTypes.CloseFinancialLimits calldata limits
    ) external nonReentrant {
        StoredProtection storage protection = _ownedActiveProtection(protectionId, msg.sender);
        if (protection.status != PositionProtectionTypes.PositionProtectionStatus.Latched) {
            revert OrderRouter__ProtectionNotLatched();
        }
        if (IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(msg.sender) != 0) {
            revert OrderRouter__PendingOrdersExist();
        }
        _setCloseLimits(protection, limits);
        _emitCloseLimitsUpdated(protection);
    }

    /// @inheritdoc IPositionProtectionActions
    function cancelPositionProtection(
        uint64 protectionId
    ) external nonReentrant {
        (address refundAccount, uint256 refundAssets) = _cancel(msg.sender, protectionId);
        if (refundAssets != 0) {
            _clearinghouse().unlockReservedSettlement(refundAccount, refundAssets);
        }
    }

    /// @inheritdoc IPositionProtectionActions
    function cancelPositionProtectionAndCommitClose(
        uint64 protectionId,
        OrderV3Types.OrderRequest calldata request
    ) external nonReentrant returns (uint64 orderId) {
        StoredProtection storage protection = _ownedActiveProtection(protectionId, msg.sender);
        if (protection.status != PositionProtectionTypes.PositionProtectionStatus.Armed) {
            revert OrderRouter__ProtectionNotArmed();
        }
        _requireMatchingPosition(protection);
        if (!request.isClose) {
            revert OrderRouter__NotCloseOrder();
        }
        if (request.side != protection.side || request.sizeDelta != protection.size) {
            revert OrderRouter__PositionChanged();
        }
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        if (router.pendingOrderCounts(msg.sender) != 0) {
            revert OrderRouter__PendingOrdersExist();
        }

        (address refundAccount, uint256 refundAssets) = _cancel(msg.sender, protectionId);
        uint64 expectedOrderId = router.nextCommitId();
        orderId = IPositionProtectionOrderCommitHost(ROUTER).commitProtectedClose(refundAccount, request, refundAssets);
        // A historical exact replay must not cancel protection without committing a new exit.
        if (orderId != expectedOrderId) {
            revert PositionProtectionBook__InvalidHostResponse();
        }
    }

    /// @inheritdoc IPositionProtectionActions
    function triggerPositionProtection(
        uint64 protectionId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint64 linkedOrderId) {
        bytes memory refreshCall = abi.encodeWithSelector(UPDATE_MARK_PRICE_SELECTOR, pythUpdateData);
        bytes memory callData = bytes.concat(refreshCall, abi.encode(msg.sender, uint256(protectionId)));
        linkedOrderId = IPositionProtectionRouterHost(ROUTER).nextCommitId();
        _callRouterNoReturn(callData, msg.value);
    }

    /// @inheritdoc IPositionProtectionActions
    function retryPositionProtectionClose(
        uint64 protectionId
    ) external nonReentrant returns (uint64 linkedOrderId) {
        StoredProtection storage protection = _activeProtection(protectionId);
        if (protection.status != PositionProtectionTypes.PositionProtectionStatus.Latched) {
            revert OrderRouter__ProtectionNotLatched();
        }
        _requireMatchingPosition(protection);

        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        if (router.pendingOrderCounts(protection.account) != 0) {
            revert OrderRouter__PendingOrdersExist();
        }

        if (protection.linkedOrderId == 0 || _attemptProtectionIds[protection.linkedOrderId] != 0) {
            revert PositionProtectionBook__InvalidLinkedOrder();
        }
        uint64 expectedOrderId = router.nextCommitId();
        linkedOrderId = IPositionProtectionCloseAttemptHost(ROUTER)
            .commitProtectionCloseAttempt(protectionId, protection.account, protection.side, protection.size);
        if (linkedOrderId != expectedOrderId) {
            revert PositionProtectionBook__InvalidHostResponse();
        }
        _recordCloseAttempt(protection, linkedOrderId);
    }

    function _cancel(
        address account,
        uint64 protectionId
    ) private returns (address refundAccount, uint256 refundAssets) {
        StoredProtection storage protection = _ownedActiveProtection(protectionId, account);
        PositionProtectionTypes.PositionProtectionStatus status = protection.status;
        if (
            status != PositionProtectionTypes.PositionProtectionStatus.PendingOpen
                && status != PositionProtectionTypes.PositionProtectionStatus.Armed
        ) {
            revert OrderRouter__ProtectionNotArmed();
        }

        if (status == PositionProtectionTypes.PositionProtectionStatus.PendingOpen) {
            delete _parentProtectionIds[protection.parentOrderId];
        }
        delete _activeProtectionIds[account];
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Cancelled;
        refundAccount = account;
        refundAssets = _takeUnpaidBounties(protection);
        emit PositionProtectionCancelled(protectionId, account);
    }

    /// @inheritdoc IPositionProtectionActions
    function commitOpenOrderWithProtection(
        OrderV3Types.OrderRequest calldata request,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external nonReentrant returns (uint64 parentOrderId, uint64 protectionId) {
        uint256 triggerBountyAssets = _configuredTriggerBounty();
        _clearinghouse().lockReservedSettlement(msg.sender, triggerBountyAssets);
        parentOrderId = _commitOpen(msg.sender, request);
        protectionId =
            _stageAttached(msg.sender, parentOrderId, request.side, request.sizeDelta, params, triggerBountyAssets);
    }

    function _stageAttached(
        address account,
        uint64 parentOrderId,
        CfdTypes.Side side,
        uint256 size,
        PositionProtectionTypes.PositionProtectionParams memory params,
        uint256 triggerBountyAssets
    ) private returns (uint64 protectionId) {
        _validateProtectionCommitAllowed();
        _requireProtectionAccountAvailable(account, 1);
        _validateBountySnapshot(triggerBountyAssets);
        if (parentOrderId == 0 || size == 0 || _parentProtectionIds[parentOrderId] != 0) {
            revert OrderRouter__PositionChanged();
        }
        if (_loadPosition(account).size != 0) {
            revert OrderRouter__PositionChanged();
        }

        _requireMatchingPendingParent(account, parentOrderId, side, size);

        (, uint256 currentMarkPrice,) = _freshProtectionObservation();
        _validateProtectionPrices(side, currentMarkPrice, params);

        protectionId = nextPositionProtectionId++;
        StoredProtection storage protection = _protections[protectionId];
        protection.protectionId = protectionId;
        protection.parentOrderId = parentOrderId;
        protection.account = account;
        protection.side = side;
        protection.size = size;
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;
        _setCloseLimits(protection, params.closeLimits);
        _clearinghouse()
            .recordBountyReservation(
                account, IMarginClearinghouse.BountyKind.ProtectionTrigger, protectionId, triggerBountyAssets
            );
        protection.status = PositionProtectionTypes.PositionProtectionStatus.PendingOpen;
        _activeProtectionIds[account] = protectionId;
        _parentProtectionIds[parentOrderId] = protectionId;

        emit PositionProtectionCreated(
            protectionId,
            account,
            parentOrderId,
            params.takeProfitTriggerPrice,
            params.stopLossTriggerPrice,
            triggerBountyAssets
        );
        _emitCloseLimitsUpdated(protection);
    }

    /// @inheritdoc IPositionProtectionBook
    function activate(
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime,
        uint64 linkedOrderId
    ) external onlyRouter returns (TriggerPlan memory plan) {
        PositionProtectionTypes.PositionProtectionTriggerLeg leg;
        (plan, leg) = _prepareActivation(protectionId, markPrice, publishTime);
        _recordActivation(protectionId, markPrice, publishTime, linkedOrderId, leg);
    }

    function _prepareActivation(
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime
    ) private view returns (TriggerPlan memory plan, PositionProtectionTypes.PositionProtectionTriggerLeg leg) {
        StoredProtection storage protection = _protections[protectionId];
        if (protection.account == address(0)) {
            revert OrderRouter__ProtectionNotFound();
        }
        if (protection.status != PositionProtectionTypes.PositionProtectionStatus.Armed) {
            revert OrderRouter__ProtectionNotArmed();
        }
        if (_activeProtectionIds[protection.account] != protectionId) {
            revert OrderRouter__ProtectionNotFound();
        }
        if (_activeOracle().isOracleFrozen()) {
            revert OrderRouter__ConditionalTriggerFrozen();
        }
        if (ExecutionBlockNumberLib.current() <= protection.armedBlock) {
            revert OrderRouter__SameBlockTrigger();
        }
        if (publishTime <= protection.armedPublishTime) {
            revert OrderRouter__TriggerPublishTimeNotAdvanced();
        }
        _requireMatchingPosition(protection);
        if (IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(protection.account) != 0) {
            revert OrderRouter__PendingOrdersExist();
        }

        leg = _triggeredLeg(protection, markPrice);
        if (leg == PositionProtectionTypes.PositionProtectionTriggerLeg.None) {
            revert OrderRouter__TriggerNotMet();
        }

        plan.account = protection.account;
        plan.side = protection.side;
        plan.size = protection.size;
        plan.triggerBountyAssets = _triggerBounty(protection);
    }

    function _recordActivation(
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime,
        uint64 linkedOrderId,
        PositionProtectionTypes.PositionProtectionTriggerLeg leg
    ) private {
        StoredProtection storage protection = _protections[protectionId];
        _clearinghouse()
            .takeBountyReservation(protection.account, IMarginClearinghouse.BountyKind.ProtectionTrigger, protectionId);
        protection.triggerMarkPrice = markPrice;
        protection.triggerPublishTime = publishTime;
        protection.triggeredLeg = leg;
        emit PositionProtectionTriggered(protectionId, protection.account, linkedOrderId, leg, markPrice, publishTime);
        _recordCloseAttempt(protection, linkedOrderId);
    }

    function _recordCloseAttempt(
        StoredProtection storage protection,
        uint64 linkedOrderId
    ) private {
        if (linkedOrderId == 0 || _attemptProtectionIds[linkedOrderId] != 0) {
            revert PositionProtectionBook__InvalidLinkedOrder();
        }
        uint64 previousLinkedOrderId = protection.linkedOrderId;
        protection.linkedOrderId = linkedOrderId;
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Triggered;
        _attemptProtectionIds[linkedOrderId] = protection.protectionId;
        emit PositionProtectionCloseAttemptQueued(
            protection.protectionId, protection.account, linkedOrderId, previousLinkedOrderId
        );
    }

    /// @inheritdoc IPositionProtectionBook
    function afterOrderTerminal(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) external onlyRouter {
        uint64 protectionId = _parentProtectionIds[orderId];
        if (protectionId != 0) {
            delete _parentProtectionIds[orderId];
            StoredProtection storage parentProtection = _protections[protectionId];
            if (parentProtection.status != PositionProtectionTypes.PositionProtectionStatus.PendingOpen) {
                return;
            }
            if (parentProtection.account != account) {
                revert OrderRouter__PositionChanged();
            }
            if (terminalStatus == IOrderRouterAccounting.OrderStatus.Executed) {
                _requireMatchingPosition(parentProtection);
                if (!_acceptedMarkInstalled()) {
                    _failPendingParent(parentProtection);
                    return;
                }
                _arm(parentProtection, ENGINE.lastMarkTime());
                _emitArmed(parentProtection);
                return;
            }
            _failPendingParent(parentProtection);
            return;
        }

        protectionId = _attemptProtectionIds[orderId];
        if (protectionId == 0) {
            return;
        }
        StoredProtection storage triggeredProtection = _protections[protectionId];
        if (
            triggeredProtection.status != PositionProtectionTypes.PositionProtectionStatus.Triggered
                || triggeredProtection.linkedOrderId != orderId
                || _activeProtectionIds[triggeredProtection.account] != protectionId
        ) {
            delete _attemptProtectionIds[orderId];
            return;
        }
        if (triggeredProtection.account != account) {
            revert OrderRouter__PositionChanged();
        }
        delete _attemptProtectionIds[orderId];
        PositionProtectionTypes.PositionProtectionStatus protectionStatus = terminalStatus
            == IOrderRouterAccounting.OrderStatus.Executed
            ? PositionProtectionTypes.PositionProtectionStatus.Executed
            : PositionProtectionTypes.PositionProtectionStatus.Failed;
        triggeredProtection.status = protectionStatus;
        delete _activeProtectionIds[account];
        emit PositionProtectionTerminal(protectionId, account, orderId, protectionStatus);
    }

    /// @inheritdoc IPositionProtectionBook
    function handleFailedProtectionAttempt(
        uint64 orderId,
        address account,
        OrderV3Types.TerminalReason reason
    ) external onlyRouter returns (bool retained) {
        uint64 protectionId = _attemptProtectionIds[orderId];
        if (protectionId == 0) {
            return false;
        }

        StoredProtection storage protection = _protections[protectionId];
        if (protection.account != account) {
            revert OrderRouter__PositionChanged();
        }
        if (
            protection.status != PositionProtectionTypes.PositionProtectionStatus.Triggered
                || protection.linkedOrderId != orderId || _activeProtectionIds[account] != protectionId
        ) {
            delete _attemptProtectionIds[orderId];
            return false;
        }
        if (!_isFailedProtectionAttemptReason(reason)) {
            revert PositionProtectionBook__InvalidTerminalReason();
        }

        delete _attemptProtectionIds[orderId];
        retained = _positionMatches(protection);
        emit PositionProtectionCloseAttemptFailed(protectionId, account, orderId, reason, retained);
        if (retained) {
            protection.status = PositionProtectionTypes.PositionProtectionStatus.Latched;
            return true;
        }

        protection.status = PositionProtectionTypes.PositionProtectionStatus.Failed;
        delete _activeProtectionIds[account];
        emit PositionProtectionTerminal(
            protectionId, account, orderId, PositionProtectionTypes.PositionProtectionStatus.Failed
        );
    }

    /// @inheritdoc IPositionProtectionBook
    function failPendingOpenForRiskOff(
        uint64 parentOrderId,
        address account
    ) external onlyRouter returns (uint256 refundableProtectionBountyAssets) {
        uint64 protectionId = _parentProtectionIds[parentOrderId];
        if (protectionId == 0) {
            return 0;
        }

        StoredProtection storage protection = _protections[protectionId];
        if (
            protection.status != PositionProtectionTypes.PositionProtectionStatus.PendingOpen
                || protection.account != account || protection.parentOrderId != parentOrderId
                || _activeProtectionIds[account] != protectionId
        ) {
            revert OrderRouter__PositionChanged();
        }

        delete _parentProtectionIds[parentOrderId];
        delete _activeProtectionIds[account];
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Failed;
        refundableProtectionBountyAssets = _takeUnpaidBounties(protection);
        emit PositionProtectionTerminal(
            protectionId, account, 0, PositionProtectionTypes.PositionProtectionStatus.Failed
        );
    }

    /// @inheritdoc IPositionProtectionBook
    function forfeitOnLiquidation(
        address account
    ) external onlyRouter returns (uint256 forfeitedAssets) {
        uint64 protectionId = _activeProtectionIds[account];
        if (protectionId == 0) {
            return 0;
        }
        StoredProtection storage protection = _protections[protectionId];
        forfeitedAssets = _takeUnpaidBounties(protection);
        if (protection.parentOrderId != 0) {
            delete _parentProtectionIds[protection.parentOrderId];
        }
        if (protection.linkedOrderId != 0) {
            delete _attemptProtectionIds[protection.linkedOrderId];
        }
        delete _activeProtectionIds[account];
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Liquidated;
        emit PositionProtectionTerminal(
            protectionId, account, protection.linkedOrderId, PositionProtectionTypes.PositionProtectionStatus.Liquidated
        );
    }

    /// @inheritdoc IPositionProtectionViews
    function activePositionProtectionId(
        address account
    ) external view returns (uint64 protectionId) {
        return _activeProtectionIds[account];
    }

    /// @inheritdoc IPositionProtectionViews
    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection) {
        StoredProtection storage stored = _protections[protectionId];
        protection.protectionId = stored.protectionId;
        protection.parentOrderId = stored.parentOrderId;
        protection.linkedOrderId = stored.linkedOrderId;
        protection.account = stored.account;
        protection.side = stored.side;
        protection.size = stored.size;
        protection.takeProfitTriggerPrice = stored.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = stored.stopLossTriggerPrice;
        protection.armedAt = stored.armedAt;
        protection.armedBlock = stored.armedBlock;
        protection.triggerMarkPrice = stored.triggerMarkPrice;
        protection.triggerPublishTime = stored.triggerPublishTime;
        protection.triggeredLeg = stored.triggeredLeg;
        protection.status = stored.status;
        protection.triggerBountyAssets = _triggerBounty(stored);
    }

    /// @inheritdoc IPositionProtectionViews
    function closeFinancialLimits(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.CloseFinancialLimits memory limits) {
        return _protections[protectionId].closeLimits;
    }

    /// @inheritdoc IPositionProtectionBook
    function unpaidBounties(
        address account
    ) external view returns (uint256 unpaidBountyAssets) {
        StoredProtection storage protection = _protections[_activeProtectionIds[account]];
        return _triggerBounty(protection);
    }

    function _triggerBounty(
        StoredProtection storage protection
    ) private view returns (uint256) {
        return _clearinghouse()
        .getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionTrigger, protection.protectionId)
        .amountAssets;
    }

    function _configuredTriggerBounty() private view returns (uint256 triggerBountyAssets) {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        return router.positionProtectionTriggerBountyAssets();
    }

    function _clearinghouse() private view returns (IMarginClearinghouse) {
        return IMarginClearinghouse(ENGINE.clearinghouse());
    }

    function _commitOpen(
        address account,
        OrderV3Types.OrderRequest calldata request
    ) private returns (uint64 parentOrderId) {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        parentOrderId = router.nextCommitId();

        uint64 committedOrderId = IPositionProtectionOrderCommitHost(ROUTER).commitProtectedOpen(account, request);
        if (committedOrderId != parentOrderId) {
            revert PositionProtectionBook__InvalidHostResponse();
        }
    }

    function _callRouterNoReturn(
        bytes memory callData,
        uint256 value
    ) private {
        (bool success, bytes memory returnData) = ROUTER.call{value: value}(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        if (returnData.length != 0) {
            revert PositionProtectionBook__InvalidHostResponse();
        }
    }

    function _validateProtectionCommitAllowed() private view {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        if (IPositionProtectionAdmin(router.admin()).paused()) {
            revert Pausable.EnforcedPause();
        }
    }

    function _requireProtectionAccountAvailable(
        address account,
        uint256 expectedPendingOrders
    ) private view {
        if (_activeProtectionIds[account] != 0) {
            revert OrderRouter__ProtectionAlreadyActive();
        }
        if (IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(account) != expectedPendingOrders) {
            revert OrderRouter__PendingOrdersExist();
        }
    }

    function _requireMatchingPendingParent(
        address account,
        uint64 parentOrderId,
        CfdTypes.Side side,
        uint256 size
    ) private view {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        (IOrderRouterAccounting.PendingOrderView memory parent, uint64 nextAccountOrderId) =
            router.getPendingOrderView(parentOrderId);
        if (
            router.accountHeadOrderId(account) != parentOrderId || nextAccountOrderId != 0
                || parent.orderId != parentOrderId || parent.isClose || parent.side != side || parent.sizeDelta != size
        ) {
            revert OrderRouter__PositionChanged();
        }
    }

    function _validateBountySnapshot(
        uint256 triggerBountyAssets
    ) private view {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        if (triggerBountyAssets != router.positionProtectionTriggerBountyAssets()) {
            revert PositionProtectionBook__BountyMismatch();
        }
    }

    function _freshProtectionObservation()
        private
        view
        returns (uint256 cachedMarkPrice, uint256 currentMarkPrice, uint64 currentPublishTime)
    {
        IPletherOracle oracle = _activeOracle();
        IPletherOracle.PolicySnapshot memory policy = oracle.getOrderExecutionPolicy(true);
        if (policy.oracleFrozen) {
            revert OrderRouter__ConditionalTriggerFrozen();
        }
        uint64 markTime = ENGINE.lastMarkTime();
        cachedMarkPrice = ENGINE.lastMarkPrice();
        if (
            cachedMarkPrice == 0 || markTime == 0
                || OracleFreshnessPolicyLib.isStale(markTime, policy.maxStaleness, block.timestamp)
        ) {
            revert OrderRouter__ProtectionMarkTooStale();
        }
        IPletherOracle.PriceSnapshot memory current = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);
        currentMarkPrice = current.markPrice;
        currentPublishTime = current.publishTime;
        if (!_acceptedMarkInstalled()) {
            revert PositionProtectionBook__OracleMarkAhead();
        }
    }

    function _acceptedMarkInstalled() private view returns (bool) {
        (bool accepted, uint256 acceptedPrice, uint64 acceptedTime) = _activeOracle().getAcceptedBasketMark();
        if (!accepted) {
            return true;
        }
        uint64 markTime = ENGINE.lastMarkTime();
        return acceptedTime < markTime || (acceptedTime == markTime && acceptedPrice == ENGINE.lastMarkPrice());
    }

    function _failPendingParent(
        StoredProtection storage protection
    ) private {
        delete _activeProtectionIds[protection.account];
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Failed;
        uint256 refundAssets = _takeUnpaidBounties(protection);
        emit PositionProtectionTerminal(
            protection.protectionId, protection.account, 0, PositionProtectionTypes.PositionProtectionStatus.Failed
        );
        if (refundAssets != 0) {
            _clearinghouse().unlockReservedSettlement(protection.account, refundAssets);
        }
    }

    function _validateProtectionPrices(
        CfdTypes.Side side,
        uint256 markPrice,
        PositionProtectionTypes.PositionProtectionParams memory params
    ) private view {
        uint256 takeProfit = params.takeProfitTriggerPrice;
        uint256 stopLoss = params.stopLossTriggerPrice;
        uint256 capPrice = ENGINE.CAP_PRICE();
        if (takeProfit == 0 && stopLoss == 0) {
            revert OrderRouter__InvalidProtectionPrices();
        }
        if (takeProfit > capPrice || stopLoss > capPrice) {
            revert OrderRouter__InvalidProtectionPrices();
        }
        if (takeProfit != 0 && stopLoss != 0) {
            bool invalidOrdering = side == CfdTypes.Side.LONG ? takeProfit >= stopLoss : stopLoss >= takeProfit;
            if (invalidOrdering) {
                revert OrderRouter__InvalidProtectionPrices();
            }
        }

        bool alreadyTriggered = side == CfdTypes.Side.LONG
            ? (takeProfit != 0 && markPrice <= takeProfit) || (stopLoss != 0 && markPrice >= stopLoss)
            : (takeProfit != 0 && markPrice >= takeProfit) || (stopLoss != 0 && markPrice <= stopLoss);
        if (alreadyTriggered) {
            revert OrderRouter__ProtectionTriggerAlreadyMet();
        }
    }

    /// @dev Runs after the protection reserve lock, whose clearinghouse callback checkpoints and realizes carry. Any
    ///      remaining `unsettledCarryAssets` is therefore independently uncovered. Price risk is delegated to the same
    ///      exact-basis planner predicate as canonical account actions and excludes free settlement and action reserves.
    function _validatePostLockRisk(
        address account,
        CfdTypes.Position memory position,
        uint256 markPrice
    ) private view {
        CfdTypes.RiskParams memory riskParams = ENGINE.riskParams();
        uint256 activeMarginBps = ENGINE.isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        uint256 requiredMarginBps =
            riskParams.initMarginBps > activeMarginBps ? riskParams.initMarginBps : activeMarginBps;

        IMarginClearinghouse clearinghouse = _clearinghouse();
        if (
            ENGINE.unsettledCarryAssets(account) != 0
                || clearinghouse.vpiRebateReserveAssets(account) < _negativeVpiReserveTarget(position.vpiAccrued)
        ) {
            revert OrderRouter__InsufficientFreeEquity();
        }

        uint256 priceCollateralAssets = position.margin + ENGINE.traderClaimBalanceAssets(account);
        if (ICfdEnginePlanner(ENGINE.planner())
                .isExactPriceRiskLiquidatable(
                    position,
                    ENGINE.positionEntryCostAssetAtoms(account),
                    markPrice,
                    ENGINE.CAP_PRICE(),
                    priceCollateralAssets,
                    requiredMarginBps
                )) {
            revert OrderRouter__InsufficientFreeEquity();
        }
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedAssets
    ) private pure returns (uint256 targetAssets) {
        if (vpiAccruedAssets < 0) {
            targetAssets = uint256(-(vpiAccruedAssets + 1)) + 1;
        }
    }

    function _ownedActiveProtection(
        uint64 protectionId,
        address account
    ) private view returns (StoredProtection storage protection) {
        protection = _activeProtection(protectionId);
        if (protection.account != account) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _activeProtection(
        uint64 protectionId
    ) private view returns (StoredProtection storage protection) {
        protection = _protections[protectionId];
        if (protection.account == address(0) || _activeProtectionIds[protection.account] != protectionId) {
            revert OrderRouter__ProtectionNotFound();
        }
    }

    function _requireMatchingPosition(
        StoredProtection storage protection
    ) private view {
        if (!_positionMatches(protection)) {
            revert OrderRouter__PositionChanged();
        }
    }

    function _positionMatches(
        StoredProtection storage protection
    ) private view returns (bool matches) {
        (uint256 size,,,, CfdTypes.Side side,,) = ENGINE.positions(protection.account);
        return size != 0 && size == protection.size && side == protection.side;
    }

    function _isFailedProtectionAttemptReason(
        OrderV3Types.TerminalReason reason
    ) private pure returns (bool) {
        return reason != OrderV3Types.TerminalReason.None && reason != OrderV3Types.TerminalReason.Executed
            && reason != OrderV3Types.TerminalReason.RiskOff && reason != OrderV3Types.TerminalReason.AccountLiquidated;
    }

    function _triggeredLeg(
        StoredProtection storage protection,
        uint256 markPrice
    ) private view returns (PositionProtectionTypes.PositionProtectionTriggerLeg) {
        if (markPrice == 0) {
            return PositionProtectionTypes.PositionProtectionTriggerLeg.None;
        }
        uint256 takeProfit = protection.takeProfitTriggerPrice;
        uint256 stopLoss = protection.stopLossTriggerPrice;
        if (
            takeProfit != 0
                && (protection.side == CfdTypes.Side.LONG ? markPrice <= takeProfit : markPrice >= takeProfit)
        ) {
            return PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit;
        }
        if (stopLoss != 0 && (protection.side == CfdTypes.Side.LONG ? markPrice >= stopLoss : markPrice <= stopLoss)) {
            return PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss;
        }
        return PositionProtectionTypes.PositionProtectionTriggerLeg.None;
    }

    function _loadPosition(
        address account
    ) private view returns (CfdTypes.Position memory position) {
        (
            position.size,
            position.margin,
            position.entryPrice,
            position.maxProfitAssets,
            position.side,
            position.lastUpdateTime,
            position.vpiAccrued
        ) = ENGINE.positions(account);
    }

    function _arm(
        StoredProtection storage protection,
        uint64 publishTime
    ) private {
        protection.armedAt = uint64(block.timestamp);
        protection.armedBlock = ExecutionBlockNumberLib.current();
        protection.armedPublishTime = publishTime;
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Armed;
    }

    function _setCloseLimits(
        StoredProtection storage protection,
        PositionProtectionTypes.CloseFinancialLimits memory limits
    ) private {
        protection.closeLimits = limits;
    }

    function _emitCloseLimitsUpdated(
        StoredProtection storage protection
    ) private {
        PositionProtectionTypes.CloseFinancialLimits storage limits = protection.closeLimits;
        emit PositionProtectionCloseLimitsUpdated(
            protection.protectionId,
            protection.account,
            limits.maxExecutionNotionalAssets,
            limits.maxGrossAccountDebitAssets,
            limits.maxActionChargeAssets,
            limits.maxExplicitFeesAssets
        );
    }

    function _emitArmed(
        StoredProtection storage protection
    ) private {
        emit PositionProtectionArmed(
            protection.protectionId,
            protection.account,
            protection.side,
            protection.size,
            protection.armedAt,
            protection.armedBlock
        );
    }

    function _takeUnpaidBounties(
        StoredProtection storage protection
    ) private returns (uint256 amountAssets) {
        IMarginClearinghouse clearinghouse = _clearinghouse();
        amountAssets = clearinghouse.takeBountyReservation(
            protection.account, IMarginClearinghouse.BountyKind.ProtectionTrigger, protection.protectionId
        );
    }

    function _activeOracle() private view returns (IPletherOracle) {
        return IPositionProtectionRouterHost(ROUTER).pletherOracle();
    }

}
