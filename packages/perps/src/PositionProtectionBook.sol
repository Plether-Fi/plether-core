// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
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
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";

/// @notice Narrow engine view surface used by the passive position-protection state book.
interface IPositionProtectionEngine is ICfdEngineRiskParamsView {

    function clearinghouse() external view returns (address);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function CAP_PRICE() external view returns (uint256);

    function planner() external view returns (address);

    function isFadWindow() external view returns (bool);

    function degradedMode() external view returns (bool);

    function unsettledCarryUsdc(
        address account
    ) external view returns (uint256);

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

    function positionEntryCostUsdcAtoms(
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
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

}

/// @notice Dynamic router configuration and accounting views consumed by the position-protection book.
interface IPositionProtectionRouterHost {

    function admin() external view returns (address);

    function pletherOracle() external view returns (IPletherOracle);

    function positionProtectionCommitsEnabled() external view returns (bool);

    function positionProtectionTriggerBountyUsdc() external view returns (uint256);

    function closeOrderExecutionBountyUsdc() external view returns (uint256);

    function maxOrderAge() external view returns (uint256);

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

/// @notice Book-only bounded-order surface for atomically attaching protection to a newly committed open.
/// @dev The Router authenticates this explicit-account host call by requiring this immutable Book as caller.
interface IPositionProtectionOrderCommitHost {

    function commitProtectedOpen(
        address account,
        OrderV2Types.OrderRequest calldata request
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
///      router remains responsible for queue mutation and keeper credits. All bounty fields are current unpaid amounts
///      and are zeroed exactly when transferred back into router-owned accounting.
contract PositionProtectionBook is IPositionProtectionBook, IOrderRouterErrors, ReentrancyGuardTransient {

    bytes4 private constant UPDATE_MARK_PRICE_SELECTOR = bytes4(keccak256("updateMarkPrice(bytes[])"));

    /// @notice Immutable router authorized to invoke terminal and trigger-activation lifecycle hooks.
    address public immutable ROUTER;
    /// @notice Immutable engine whose cached mark, positions, and risk configuration bind protection validation.
    IPositionProtectionEngine public immutable ENGINE;

    /// @notice Next protection id assigned by a successful creation; starts at one.
    uint64 public nextPositionProtectionId = 1;

    mapping(uint64 protectionId => PositionProtectionTypes.PositionProtectionView protection) private _protections;
    mapping(address account => uint64 protectionId) private _activeProtectionIds;
    mapping(uint64 parentOrderId => uint64 protectionId) private _parentProtectionIds;
    mapping(uint64 linkedOrderId => uint64 protectionId) private _triggeredProtectionIds;

    /// @notice Deployment requires a nonzero router and engine.
    error PositionProtectionBook__ZeroAddress();
    /// @notice Locally snapshotted bounties do not match the router's current timelocked configuration.
    error PositionProtectionBook__BountyMismatch();
    /// @notice An activation supplied a zero or already-bound linked close id.
    error PositionProtectionBook__InvalidLinkedOrder();
    /// @notice A reused router entrypoint returned data despite its canonical no-return ABI.
    error PositionProtectionBook__InvalidHostResponse();

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
        (uint256 triggerBountyUsdc, uint256 executionBountyUsdc) = _configuredBounties();
        _clearinghouse().lockReservedSettlement(msg.sender, triggerBountyUsdc + executionBountyUsdc);
        return _create(msg.sender, params, triggerBountyUsdc, executionBountyUsdc);
    }

    function _create(
        address account,
        PositionProtectionTypes.PositionProtectionParams memory params,
        uint256 triggerBountyUsdc,
        uint256 executionBountyUsdc
    ) private returns (uint64 protectionId) {
        _validateProtectionCommitAllowed();
        if (ENGINE.degradedMode()) {
            revert OrderRouter__DegradedMode();
        }
        _requireProtectionAccountAvailable(account, 0);
        _validateBountySnapshot(triggerBountyUsdc, executionBountyUsdc);

        CfdTypes.Position memory position = _loadPosition(account);
        if (position.size == 0) {
            revert OrderRouter__NoOpenPosition();
        }

        uint256 markPrice = _freshCachedProtectionMark();
        _validateProtectionPrices(position.side, markPrice, params);
        _validatePostLockRisk(account, position, markPrice);

        protectionId = nextPositionProtectionId++;
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
        protection.protectionId = protectionId;
        protection.account = account;
        protection.side = position.side;
        protection.size = position.size;
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;
        protection.triggerBountyUsdc = triggerBountyUsdc;
        protection.executionBountyUsdc = executionBountyUsdc;
        _arm(protection);
        _activeProtectionIds[account] = protectionId;

        emit PositionProtectionCreated(
            protectionId,
            account,
            0,
            params.takeProfitTriggerPrice,
            params.stopLossTriggerPrice,
            triggerBountyUsdc,
            executionBountyUsdc
        );
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
        PositionProtectionTypes.PositionProtectionView storage protection =
            _ownedActiveProtection(protectionId, account);
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

        uint256 markPrice = _freshCachedProtectionMark();
        _validateProtectionPrices(protection.side, markPrice, params);
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;

        if (status == PositionProtectionTypes.PositionProtectionStatus.Armed) {
            _arm(protection);
        }

        emit PositionProtectionReplaced(
            protectionId, account, params.takeProfitTriggerPrice, params.stopLossTriggerPrice
        );
        if (status == PositionProtectionTypes.PositionProtectionStatus.Armed) {
            _emitArmed(protection);
        }
    }

    /// @inheritdoc IPositionProtectionActions
    function cancelPositionProtection(
        uint64 protectionId
    ) external nonReentrant {
        (address refundAccount, uint256 refundUsdc) = _cancel(msg.sender, protectionId);
        if (refundUsdc != 0) {
            _clearinghouse().unlockReservedSettlement(refundAccount, refundUsdc);
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

    function _cancel(
        address account,
        uint64 protectionId
    ) private returns (address refundAccount, uint256 refundUsdc) {
        PositionProtectionTypes.PositionProtectionView storage protection =
            _ownedActiveProtection(protectionId, account);
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
        refundUsdc = _takeUnpaidBounties(protection);
        emit PositionProtectionCancelled(protectionId, account);
    }

    /// @inheritdoc IPositionProtectionActions
    function commitOpenOrderWithProtection(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external nonReentrant returns (uint64 parentOrderId, uint64 protectionId) {
        (uint256 triggerBountyUsdc, uint256 executionBountyUsdc) = _configuredBounties();
        _clearinghouse().lockReservedSettlement(msg.sender, triggerBountyUsdc + executionBountyUsdc);
        parentOrderId = _commitOpen(msg.sender, side, sizeDelta, marginDelta, targetPrice);
        protectionId =
            _stageAttached(msg.sender, parentOrderId, side, sizeDelta, params, triggerBountyUsdc, executionBountyUsdc);
    }

    function _stageAttached(
        address account,
        uint64 parentOrderId,
        CfdTypes.Side side,
        uint256 size,
        PositionProtectionTypes.PositionProtectionParams memory params,
        uint256 triggerBountyUsdc,
        uint256 executionBountyUsdc
    ) private returns (uint64 protectionId) {
        _validateProtectionCommitAllowed();
        _requireProtectionAccountAvailable(account, 1);
        _validateBountySnapshot(triggerBountyUsdc, executionBountyUsdc);
        if (parentOrderId == 0 || size == 0 || _parentProtectionIds[parentOrderId] != 0) {
            revert OrderRouter__PositionChanged();
        }
        if (_loadPosition(account).size != 0) {
            revert OrderRouter__PositionChanged();
        }

        _requireMatchingPendingParent(account, parentOrderId, side, size);

        uint256 markPrice = _freshCachedProtectionMark();
        _validateProtectionPrices(side, markPrice, params);

        protectionId = nextPositionProtectionId++;
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
        protection.protectionId = protectionId;
        protection.parentOrderId = parentOrderId;
        protection.account = account;
        protection.side = side;
        protection.size = size;
        protection.takeProfitTriggerPrice = params.takeProfitTriggerPrice;
        protection.stopLossTriggerPrice = params.stopLossTriggerPrice;
        protection.triggerBountyUsdc = triggerBountyUsdc;
        protection.executionBountyUsdc = executionBountyUsdc;
        protection.status = PositionProtectionTypes.PositionProtectionStatus.PendingOpen;
        _activeProtectionIds[account] = protectionId;
        _parentProtectionIds[parentOrderId] = protectionId;

        emit PositionProtectionCreated(
            protectionId,
            account,
            parentOrderId,
            params.takeProfitTriggerPrice,
            params.stopLossTriggerPrice,
            triggerBountyUsdc,
            executionBountyUsdc
        );
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
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
        if (protection.account == address(0)) {
            revert OrderRouter__ProtectionNotFound();
        }
        if (protection.status != PositionProtectionTypes.PositionProtectionStatus.Armed) {
            revert OrderRouter__ProtectionNotArmed();
        }
        if (_activeOracle().isOracleFrozen()) {
            revert OrderRouter__ConditionalTriggerFrozen();
        }
        if (block.number <= protection.armedBlock || publishTime <= protection.armedAt) {
            revert OrderRouter__SameBlockTrigger();
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
        plan.triggerBountyUsdc = protection.triggerBountyUsdc;
        plan.executionBountyUsdc = protection.executionBountyUsdc;
    }

    function _recordActivation(
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime,
        uint64 linkedOrderId,
        PositionProtectionTypes.PositionProtectionTriggerLeg leg
    ) private {
        if (linkedOrderId == 0 || _triggeredProtectionIds[linkedOrderId] != 0) {
            revert PositionProtectionBook__InvalidLinkedOrder();
        }
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
        protection.triggerBountyUsdc = 0;
        protection.executionBountyUsdc = 0;
        protection.linkedOrderId = linkedOrderId;
        protection.triggerMarkPrice = markPrice;
        protection.triggerPublishTime = publishTime;
        protection.triggeredLeg = leg;
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Triggered;
        _triggeredProtectionIds[linkedOrderId] = protectionId;

        emit PositionProtectionTriggered(protectionId, protection.account, linkedOrderId, leg, markPrice, publishTime);
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
            PositionProtectionTypes.PositionProtectionView storage parentProtection = _protections[protectionId];
            if (parentProtection.status != PositionProtectionTypes.PositionProtectionStatus.PendingOpen) {
                return;
            }
            if (parentProtection.account != account) {
                revert OrderRouter__PositionChanged();
            }
            if (terminalStatus == IOrderRouterAccounting.OrderStatus.Executed) {
                _requireMatchingPosition(parentProtection);
                _arm(parentProtection);
                _emitArmed(parentProtection);
                return;
            }

            delete _activeProtectionIds[account];
            parentProtection.status = PositionProtectionTypes.PositionProtectionStatus.Failed;
            uint256 refundUsdc = _takeUnpaidBounties(parentProtection);
            emit PositionProtectionTerminal(
                protectionId, account, 0, PositionProtectionTypes.PositionProtectionStatus.Failed
            );
            if (refundUsdc != 0) {
                _clearinghouse().unlockReservedSettlement(account, refundUsdc);
            }
            return;
        }

        protectionId = _triggeredProtectionIds[orderId];
        if (protectionId == 0) {
            return;
        }
        delete _triggeredProtectionIds[orderId];
        PositionProtectionTypes.PositionProtectionView storage triggeredProtection = _protections[protectionId];
        if (triggeredProtection.status != PositionProtectionTypes.PositionProtectionStatus.Triggered) {
            return;
        }
        if (triggeredProtection.account != account) {
            revert OrderRouter__PositionChanged();
        }
        PositionProtectionTypes.PositionProtectionStatus protectionStatus = terminalStatus
            == IOrderRouterAccounting.OrderStatus.Executed
            ? PositionProtectionTypes.PositionProtectionStatus.Executed
            : PositionProtectionTypes.PositionProtectionStatus.Failed;
        triggeredProtection.status = protectionStatus;
        delete _activeProtectionIds[account];
        emit PositionProtectionTerminal(protectionId, account, orderId, protectionStatus);
    }

    /// @inheritdoc IPositionProtectionBook
    function failPendingOpenForRiskOff(
        uint64 parentOrderId,
        address account
    ) external onlyRouter returns (uint256 refundableProtectionBountyUsdc) {
        uint64 protectionId = _parentProtectionIds[parentOrderId];
        if (protectionId == 0) {
            return 0;
        }

        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
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
        refundableProtectionBountyUsdc = _takeUnpaidBounties(protection);
        emit PositionProtectionTerminal(
            protectionId, account, 0, PositionProtectionTypes.PositionProtectionStatus.Failed
        );
    }

    /// @inheritdoc IPositionProtectionBook
    function forfeitOnLiquidation(
        address account
    ) external onlyRouter returns (uint256 forfeitedUsdc) {
        uint64 protectionId = _activeProtectionIds[account];
        if (protectionId == 0) {
            return 0;
        }
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[protectionId];
        forfeitedUsdc = _takeUnpaidBounties(protection);
        if (protection.parentOrderId != 0) {
            delete _parentProtectionIds[protection.parentOrderId];
        }
        if (protection.linkedOrderId != 0) {
            delete _triggeredProtectionIds[protection.linkedOrderId];
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
        return _protections[protectionId];
    }

    /// @inheritdoc IPositionProtectionBook
    function unpaidBounties(
        address account
    ) external view returns (uint256 unpaidBountyUsdc) {
        PositionProtectionTypes.PositionProtectionView storage protection = _protections[_activeProtectionIds[account]];
        return protection.triggerBountyUsdc + protection.executionBountyUsdc;
    }

    function _configuredBounties() private view returns (uint256 triggerBountyUsdc, uint256 executionBountyUsdc) {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        return (router.positionProtectionTriggerBountyUsdc(), router.closeOrderExecutionBountyUsdc());
    }

    function _clearinghouse() private view returns (IMarginClearinghouse) {
        return IMarginClearinghouse(ENGINE.clearinghouse());
    }

    function _commitOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) private returns (uint64 parentOrderId) {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        parentOrderId = router.nextCommitId();

        // Solidity zero-initializes the fields intentionally omitted from this synthetic permissive request.
        // slither-disable-next-line uninitialized-local
        OrderV2Types.OrderRequest memory request;
        request.clientOrderId = keccak256(
            abi.encode("PLETHER_POSITION_PROTECTION_PARENT_V2", block.chainid, ROUTER, account, parentOrderId)
        );
        request.side = side;
        request.sizeDelta = sizeDelta;
        request.marginDelta = marginDelta;
        request.targetPrice = targetPrice == 0 ? (side == CfdTypes.Side.BULL ? 1 : ENGINE.CAP_PRICE()) : targetPrice;
        request.bounds.validUntil = uint64(block.timestamp + router.maxOrderAge());
        request.bounds.allowedExecutionModes = 1 | 2 | 4;
        // Zero is a Router-authenticated internal wildcard. Public V2 commits reject it.
        request.bounds.expectedConfigHash = bytes32(0);
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;

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
        if (!router.positionProtectionCommitsEnabled()) {
            revert OrderRouter__ProtectionDisabled();
        }
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
        uint256 triggerBountyUsdc,
        uint256 executionBountyUsdc
    ) private view {
        IPositionProtectionRouterHost router = IPositionProtectionRouterHost(ROUTER);
        if (
            triggerBountyUsdc != router.positionProtectionTriggerBountyUsdc()
                || executionBountyUsdc != router.closeOrderExecutionBountyUsdc()
        ) {
            revert PositionProtectionBook__BountyMismatch();
        }
    }

    function _freshCachedProtectionMark() private view returns (uint256 markPrice) {
        IPletherOracle.PolicySnapshot memory policy = _activeOracle().getOrderExecutionPolicy(true);
        if (policy.oracleFrozen) {
            revert OrderRouter__ConditionalTriggerFrozen();
        }
        uint64 markTime = ENGINE.lastMarkTime();
        markPrice = ENGINE.lastMarkPrice();
        if (
            markPrice == 0 || markTime == 0
                || OracleFreshnessPolicyLib.isStale(markTime, policy.maxStaleness, block.timestamp)
        ) {
            revert OrderRouter__ProtectionMarkTooStale();
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
            bool invalidOrdering = side == CfdTypes.Side.BULL ? takeProfit >= stopLoss : stopLoss >= takeProfit;
            if (invalidOrdering) {
                revert OrderRouter__InvalidProtectionPrices();
            }
        }

        bool alreadyTriggered = side == CfdTypes.Side.BULL
            ? (takeProfit != 0 && markPrice <= takeProfit) || (stopLoss != 0 && markPrice >= stopLoss)
            : (takeProfit != 0 && markPrice >= takeProfit) || (stopLoss != 0 && markPrice <= stopLoss);
        if (alreadyTriggered) {
            revert OrderRouter__ProtectionTriggerAlreadyMet();
        }
    }

    /// @dev Runs after the protection reserve lock, whose clearinghouse callback checkpoints and realizes carry. Any
    ///      remaining `unsettledCarryUsdc` is therefore independently uncovered. Price risk is delegated to the same
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
            ENGINE.unsettledCarryUsdc(account) != 0
                || clearinghouse.vpiRebateReserveUsdc(account) < _negativeVpiReserveTarget(position.vpiAccrued)
        ) {
            revert OrderRouter__InsufficientFreeEquity();
        }

        uint256 priceCollateralUsdc = position.margin + ENGINE.traderClaimBalanceUsdc(account);
        if (ICfdEnginePlanner(ENGINE.planner())
                .isExactPriceRiskLiquidatable(
                    position,
                    ENGINE.positionEntryCostUsdcAtoms(account),
                    markPrice,
                    ENGINE.CAP_PRICE(),
                    priceCollateralUsdc,
                    requiredMarginBps
                )) {
            revert OrderRouter__InsufficientFreeEquity();
        }
    }

    function _negativeVpiReserveTarget(
        int256 vpiAccruedUsdc
    ) private pure returns (uint256 targetUsdc) {
        if (vpiAccruedUsdc < 0) {
            targetUsdc = uint256(-(vpiAccruedUsdc + 1)) + 1;
        }
    }

    function _ownedActiveProtection(
        uint64 protectionId,
        address account
    ) private view returns (PositionProtectionTypes.PositionProtectionView storage protection) {
        protection = _protections[protectionId];
        if (protection.account == address(0) || _activeProtectionIds[account] != protectionId) {
            revert OrderRouter__ProtectionNotFound();
        }
        if (protection.account != account) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _requireMatchingPosition(
        PositionProtectionTypes.PositionProtectionView storage protection
    ) private view {
        (uint256 size,,,, CfdTypes.Side side,,) = ENGINE.positions(protection.account);
        if (size == 0 || size != protection.size || side != protection.side) {
            revert OrderRouter__PositionChanged();
        }
    }

    function _triggeredLeg(
        PositionProtectionTypes.PositionProtectionView storage protection,
        uint256 markPrice
    ) private view returns (PositionProtectionTypes.PositionProtectionTriggerLeg) {
        if (markPrice == 0) {
            return PositionProtectionTypes.PositionProtectionTriggerLeg.None;
        }
        uint256 takeProfit = protection.takeProfitTriggerPrice;
        uint256 stopLoss = protection.stopLossTriggerPrice;
        if (
            takeProfit != 0
                && (protection.side == CfdTypes.Side.BULL ? markPrice <= takeProfit : markPrice >= takeProfit)
        ) {
            return PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit;
        }
        if (stopLoss != 0 && (protection.side == CfdTypes.Side.BULL ? markPrice >= stopLoss : markPrice <= stopLoss)) {
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
            position.maxProfitUsdc,
            position.side,
            position.lastUpdateTime,
            position.vpiAccrued
        ) = ENGINE.positions(account);
    }

    function _arm(
        PositionProtectionTypes.PositionProtectionView storage protection
    ) private {
        protection.armedAt = uint64(block.timestamp);
        protection.armedBlock = uint64(block.number);
        protection.status = PositionProtectionTypes.PositionProtectionStatus.Armed;
    }

    function _emitArmed(
        PositionProtectionTypes.PositionProtectionView storage protection
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
        PositionProtectionTypes.PositionProtectionView storage protection
    ) private returns (uint256 amountUsdc) {
        amountUsdc = protection.triggerBountyUsdc + protection.executionBountyUsdc;
        protection.triggerBountyUsdc = 0;
        protection.executionBountyUsdc = 0;
    }

    function _activeOracle() private view returns (IPletherOracle) {
        return IPositionProtectionRouterHost(ROUTER).pletherOracle();
    }

}
