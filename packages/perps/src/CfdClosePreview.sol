// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluator, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

interface ICfdClosePreviewRouter {

    function closeOrderExecutionBountyUsdc() external view returns (uint256);

}

/// @title CfdClosePreview
/// @notice Read-only preview of a prospective close after projecting commitment carry and a new bounty reservation.
/// @dev Deployable alongside an existing engine; it is not a replacement for the router's execution evaluator.
contract CfdClosePreview is CfdOrderPolicyEvaluator {

    error CfdClosePreview__NotCloseOrder();

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
            if (order.sizeDelta != snapshot.position.size) {
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
            _reserveBounty(snapshot, preview.executionBountyUsdc);
        }
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snapshot, order, executionPrice, publishTime);
        preview.assessment =
            _evaluateClose(snapshot, delta, bounds, preview.executionBountyUsdc, executor == order.account);
    }

    /// @dev The router checks side and partial-close dust before reserving even a zero bounty. Its queued-position
    ///      projection is deliberately not reproduced here; callers must still simulate the actual commitment.
    function _validateRouterCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order calldata order
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
