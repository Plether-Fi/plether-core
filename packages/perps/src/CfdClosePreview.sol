// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

interface ICfdClosePreviewRouter {

    function closeOrderExecutionBountyUsdc() external view returns (uint256);
    function lifecycleBook() external view returns (address);
    function positionProtectionBook() external view returns (address);
    function pendingOrderCounts(
        address account
    ) external view returns (uint256);
    function maxOrderAge() external view returns (uint256);

}

interface ICfdClosePreviewProtection {

    function activePositionProtectionId(
        address account
    ) external view returns (uint64);

}

/// @title CfdClosePreview
/// @notice Read-only preview of a prospective close after projecting commitment carry and a new bounty reservation.
/// @dev Deployable alongside an existing engine; it is not a replacement for the router's execution evaluator.
contract CfdClosePreview is CfdOrderPolicyEvaluatorBase {

    error CfdClosePreview__NotCloseOrder();
    error CfdClosePreview__SponsoredDeploymentMismatch();
    error CfdClosePreview__SponsoredIntentInvalid();
    error CfdClosePreview__SponsoredAccountBusy();
    error CfdClosePreview__UncoveredCarry(uint256 unpaidCarryUsdc);
    error CfdClosePreview__SubsidyMismatch(uint256 expectedUsdc, uint256 requiredUsdc);

    uint256 public constant MAX_CLOSE_SUBSIDY_USDC = 200_000;
    address public constant SPONSORED_ENGINE = address(bytes20(hex"afece93321be41aa73474457e2f47cf7b2fb738f"));

    struct SponsoredClosePreview {
        uint256 subsidyUsdc;
        uint256 depositCarryUsdc;
        uint256 commitmentCarryUsdc;
        uint256 executionBountyUsdc;
        OrderV2Types.ExecutionAssessment assessment;
    }

    struct ClosePreview {
        uint256 commitmentCarryUsdc;
        uint256 executionBountyUsdc;
        OrderV2Types.ExecutionAssessment assessment;
    }

    /// @notice Projects commitment now and close execution at the supplied price, using canonical pool depth.
    /// @dev Always adds a new reservation, even if other orders already reserve bounties for this account. Assessment
    ///      starts AFTER projected commitment; commitmentCarryUsdc is a separate debit. No future carry, oracle update,
    ///      router queue admission, deadline or config-hash validation is simulated. Side and dust checks use the live
    ///      position; pending opens/closes can change the router's queued projection. Re-preview if state changes.
    function previewClose(
        address engineAddress,
        CfdTypes.Order calldata order,
        address executor,
        uint256 executionPrice,
        uint64 publishTime,
        OrderV2Types.ExecutionBounds calldata bounds
    ) external view returns (ClosePreview memory preview) {
        if (!order.isClose) {
            revert CfdClosePreview__NotCloseOrder();
        }
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, IHousePool(engine.pool()).totalAssets());
        return _previewSnapshot(engine, planner, snapshot, order, executor, executionPrice, publishTime, bounds);
    }

    /// @notice Reviews an exact testnet bounty grant followed by deposit, commitment and execution.
    /// @dev Does not simulate queue admission or future execution. The account must execute the guard immediately
    ///      before mint/approve/deposit/commit in a reverting batch. There is deliberately no campaign expiry.
    function previewSponsoredClose(
        address engineAddress,
        address account,
        OrderV2Types.OrderRequest calldata request,
        address executor,
        uint256 executionPrice,
        uint64 publishTime
    ) external view returns (SponsoredClosePreview memory result) {
        _validateSponsoredIntent(engineAddress, account, request, false);
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot;
        (snapshot, result.subsidyUsdc, result.depositCarryUsdc) = _sponsoredSnapshot(engine, planner, account);
        ClosePreview memory close = _previewSnapshot(
            engine,
            planner,
            snapshot,
            _requestOrder(account, request),
            executor,
            executionPrice,
            publishTime,
            request.bounds
        );
        result.commitmentCarryUsdc = close.commitmentCarryUsdc;
        result.executionBountyUsdc = close.executionBountyUsdc;
        result.assessment = close.assessment;
    }

    /// @notice First call of the sponsored smart-account batch; a reused intent must never mint another grant.
    function validateSponsoredClose(
        address engineAddress,
        OrderV2Types.OrderRequest calldata request,
        uint256 expectedSubsidyUsdc
    ) external view {
        _validateSponsoredIntent(engineAddress, msg.sender, request, true);
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        (CfdEnginePlanTypes.RawSnapshot memory snapshot, uint256 requiredUsdc,) =
            _sponsoredSnapshot(engine, planner, msg.sender);
        if (requiredUsdc == 0 || requiredUsdc != expectedSubsidyUsdc) {
            revert CfdClosePreview__SubsidyMismatch(expectedSubsidyUsdc, requiredUsdc);
        }
        CfdTypes.Order memory order = _requestOrder(msg.sender, request);
        _validateRouterCommit(snapshot, order);
        _validateCommit(snapshot, order.sizeDelta);
        _validatePartialClose(planner, snapshot, order.sizeDelta);
    }

    function _sponsoredEngine() internal view virtual returns (address) {
        return SPONSORED_ENGINE;
    }

    function _validateSponsoredIntent(
        address engineAddress,
        address account,
        OrderV2Types.OrderRequest calldata request,
        bool finalRequest
    ) private view {
        if (block.chainid != 421_614 || engineAddress != _sponsoredEngine()) {
            revert CfdClosePreview__SponsoredDeploymentMismatch();
        }
        ICfdClosePreviewRouter router = ICfdClosePreviewRouter(ICfdOrderPolicyEngineView(engineAddress).orderRouter());
        IOrderLifecycleBook book = IOrderLifecycleBook(router.lifecycleBook());
        (OrderV2Types.ClientIntentResolution resolution,,) = book.resolveClientIntent(account, request);
        uint8 modes = request.bounds.allowedExecutionModes;
        if (
            !request.isClose || request.marginDelta != 0 || request.targetPrice == 0
                || request.clientOrderId == bytes32(0) || bytes8(request.clientOrderId) == hex"504c455448455221"
                || resolution != OrderV2Types.ClientIntentResolution.Unused
                || request.bounds.validUntil < block.timestamp
                || request.bounds.validUntil > block.timestamp + router.maxOrderAge()
                || request.bounds.expectedConfigHash != book.currentExecutionConfigHash()
                || (modes == 0 || modes > 7 || (finalRequest && modes != 1 && modes != 2 && modes != 4))
                || request.bounds.maxExecutionBountyUsdc < router.closeOrderExecutionBountyUsdc()
        ) {
            revert CfdClosePreview__SponsoredIntentInvalid();
        }
        if (
            router.pendingOrderCounts(account) != 0
                || ICfdClosePreviewProtection(router.positionProtectionBook()).activePositionProtectionId(account) != 0
        ) {
            revert CfdClosePreview__SponsoredAccountBusy();
        }
    }

    function _sponsoredSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        address account
    ) private view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot, uint256 subsidy, uint256 depositCarry) {
        uint256 poolAssets = IHousePool(engine.pool()).totalAssets();
        snapshot = _buildRawSnapshot(engine, planner, account, poolAssets);
        CfdEnginePlanLib.projectCloseCommitCarry(snapshot);
        if (snapshot.unsettledCarryUsdc != 0) {
            revert CfdClosePreview__UncoveredCarry(snapshot.unsettledCarryUsdc);
        }
        uint256 bounty = ICfdClosePreviewRouter(engine.orderRouter()).closeOrderExecutionBountyUsdc();
        if (bounty > MAX_CLOSE_SUBSIDY_USDC) {
            revert CfdClosePreview__SubsidyMismatch(MAX_CLOSE_SUBSIDY_USDC, bounty);
        }
        subsidy = bounty > snapshot.accountBuckets.freeSettlementUsdc
            ? bounty - snapshot.accountBuckets.freeSettlementUsdc
            : 0;
        // Reload the ORIGINAL snapshot: deposit credits custody before invoking the carry hook.
        snapshot = _buildRawSnapshot(engine, planner, account, poolAssets);
        if (subsidy != 0) {
            snapshot.accountBuckets.settlementBalanceUsdc += subsidy;
            snapshot.accountBuckets.freeSettlementUsdc += subsidy;
            depositCarry = CfdEnginePlanLib.projectCloseCommitCarry(snapshot);
        }
    }

    function _requestOrder(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) private view returns (CfdTypes.Order memory order) {
        order = CfdTypes.Order(
            account,
            request.sizeDelta,
            request.marginDelta,
            request.targetPrice,
            uint64(block.timestamp),
            uint64(block.number),
            0,
            request.side,
            request.isClose
        );
    }

    function _previewSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order,
        address executor,
        uint256 executionPrice,
        uint64 publishTime,
        OrderV2Types.ExecutionBounds calldata bounds
    ) private view returns (ClosePreview memory preview) {
        preview.executionBountyUsdc = ICfdClosePreviewRouter(engine.orderRouter()).closeOrderExecutionBountyUsdc();
        _validateRouterCommit(snapshot, order);

        // Match the engine's commitment path, whose zero-bounty branch skips carry and funding validation.
        if (preview.executionBountyUsdc != 0) {
            _validateCommit(snapshot, order.sizeDelta);
            preview.commitmentCarryUsdc = CfdEnginePlanLib.projectCloseCommitCarry(snapshot);
            uint256 freeUsdc = snapshot.accountBuckets.freeSettlementUsdc;
            if (freeUsdc < preview.executionBountyUsdc) {
                revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking(
                    preview.executionBountyUsdc, freeUsdc, snapshot.unsettledCarryUsdc
                );
            }
            _validatePartialClose(planner, snapshot, order.sizeDelta);
            _reserveBounty(snapshot, preview.executionBountyUsdc);
        }
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snapshot, order, executionPrice, publishTime);
        preview.assessment =
            _evaluateClose(snapshot, delta, bounds, preview.executionBountyUsdc, executor == order.account);
    }

    function _validatePartialClose(
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint256 size
    ) private view {
        if (size != snapshot.position.size) {
            uint256 requiredBps =
                snapshot.isFadWindow ? snapshot.riskParams.fadMarginBps : snapshot.riskParams.maintMarginBps;
            if (planner.isExactPriceRiskLiquidatable(
                    snapshot.position,
                    snapshot.positionEntryCostUsdcAtoms,
                    snapshot.lastMarkPrice,
                    snapshot.capPrice,
                    snapshot.position.margin + snapshot.traderClaimBalanceForAccount,
                    requiredBps
                )) {
                revert ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy();
            }
        }
    }

    /// @dev The router checks side and partial-close dust before reserving even a zero bounty. Its queued-position
    ///      projection is deliberately not reproduced here; callers must still simulate the actual commitment.
    function _validateRouterCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order
    ) private pure {
        if (snapshot.position.size != 0 && order.side != snapshot.position.side) {
            revert IOrderRouterErrors.OrderRouter__SideMismatch();
        }
        if (
            order.sizeDelta == 0 || order.sizeDelta >= snapshot.position.size
                || order.sizeDelta % CfdTypes.SIZE_QUANTUM != 0
        ) {
            return;
        }
        uint256 commitPrice = snapshot.lastMarkPrice == 0 ? 1e8 : snapshot.lastMarkPrice;
        commitPrice = Math.min(commitPrice, snapshot.capPrice);
        uint256 minNotionalUsdc =
            Math.mulDiv(snapshot.riskParams.minBountyUsdc, 10_000, snapshot.riskParams.bountyBps, Math.Rounding.Ceil);
        uint256 minCloseSizeDelta =
            Math.mulDiv(minNotionalUsdc, DecimalConstants.USDC_TO_TOKEN_SCALE, commitPrice, Math.Rounding.Ceil);
        if (order.sizeDelta < minCloseSizeDelta) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(11);
        }
    }

    function _validateCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint256 size
    ) private pure {
        if (snapshot.position.size == 0) {
            revert ICfdEngineTypes.CfdEngine__NoOpenPosition();
        }
        if (size == 0) {
            revert ICfdEngineTypes.CfdEngine__ZeroAmount();
        }
        if (size > snapshot.position.size) {
            revert ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition();
        }
        if (size % CfdTypes.SIZE_QUANTUM != 0) {
            revert ICfdEngineTypes.CfdEngine__InvalidCloseSizeQuantum();
        }
        // CloseCommitFallback accepts any stored mark age, but requires both a price and a publish timestamp.
        if (snapshot.lastMarkPrice == 0 || snapshot.lastMarkTime == 0) {
            revert ICfdEngineTypes.CfdEngine__MarkPriceStale();
        }
    }

    function _reserveBounty(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint256 bounty
    ) private pure {
        snapshot.actionReserveUsdc += bounty;
        snapshot.protectedExecutionBountyUsdc += bounty;
        snapshot.lockedBuckets.reservedSettlementUsdc += bounty;
        snapshot.accountBuckets = MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
            snapshot.accountBuckets.settlementBalanceUsdc,
            snapshot.lockedBuckets.positionMarginUsdc,
            snapshot.liquidationReserveUsdc,
            snapshot.lockedBuckets.committedOrderMarginUsdc,
            snapshot.actionReserveUsdc
        );
        snapshot.lockedBuckets.totalLockedMarginUsdc = snapshot.accountBuckets.totalLockedMarginUsdc;
    }

}
