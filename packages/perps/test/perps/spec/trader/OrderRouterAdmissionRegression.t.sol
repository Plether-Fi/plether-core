// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract OrderRouterAdmissionRegressionTest is SourceBoundBountyFixture {

    function test_ExpiredFullCloseCannotAdmitOpposingOpen() public {
        _position(CfdTypes.Side.SHORT);
        uint64 closeId = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        vm.warp(router.lifecycleBook().orderTiming(closeId).executionDeadline + 1);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
        assertEq(router.pendingCloseSize(BOUNTY_TRADER), BOUNTY_SIZE);
        _bountyExpire(closeId, BOUNTY_KEEPER);
        assertEq(router.pendingCloseSize(BOUNTY_TRADER), 0);
    }

    function test_ConfigInvalidFullCloseCannotAdmitOpposingOpen() public {
        _position(CfdTypes.Side.LONG);
        engineAdmin.proposeCalendarConfig(_engineCalendarConfig());
        uint256 activation = engineAdmin.calendarConfigActivationTime();
        vm.warp(activation - 1);
        _mark(BOUNTY_PRICE);
        uint64 closeId = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        vm.warp(activation);
        engineAdmin.finalizeCalendarConfig();
        _mark(BOUNTY_PRICE);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), closeId);
    }

    function test_ExpiredOpenDoesNotBlockOpposingOpenOrReleaseItsLocks() public {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        uint64 oldId = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6);
        vm.warp(router.lifecycleBook().orderTiming(oldId).executionDeadline + 1);
        _mark(BOUNTY_PRICE);
        uint256 oldBounty = _bountyReservation(oldId).amountAssets;
        uint256 lockedBefore = clearinghouse.getLockedMarginBuckets(BOUNTY_TRADER).totalLockedMarginAssets;
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6);
        assertEq(_bountyReservation(oldId).amountAssets, oldBounty);
        assertEq(
            clearinghouse.getLockedMarginBuckets(BOUNTY_TRADER).totalLockedMarginAssets,
            lockedBefore + 1000e6 + _bountyReservation(id).amountAssets
        );
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 2);
        _bountyExpire(oldId, BOUNTY_KEEPER);
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
    }

    function test_ImpossibleCloseNotionalRejectedBeforeItCanSupportAFlip() public {
        _position(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        request.bounds.maxExecutionNotionalAssets = 0;
        _rejectImpossible(request);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
    }

    function test_ImpossibleShortCloseTargetRejectedBeforeItCanSupportAFlip() public {
        _position(CfdTypes.Side.SHORT);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        request.targetPrice = CAP_PRICE + 1;
        _rejectImpossible(request);
    }

    function test_ImpossiblePartialCloseCannotSupportAnOpposingOpen() public {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        _open(BOUNTY_TRADER, CfdTypes.Side.LONG, 3 * BOUNTY_SIZE, 1000e6, BOUNTY_PRICE);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        // Full closes ignore this bound, but the first reduction necessarily leaves a position.
        request.bounds.minPostPositionEquityAssets = type(uint256).max;
        vm.prank(BOUNTY_TRADER);
        uint64 first = router.commitOrder(request);
        uint64 second = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, 2 * BOUNTY_SIZE, 0);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
        _bountyExecute(first, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Failed);
        _bountyExecute(second, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, BOUNTY_SIZE, "the impossible predecessor cannot erase this residual exposure");
    }

    function test_ImpossibleCloseFeeAndActionBoundsCannotSupportAFlip() public {
        _position(CfdTypes.Side.SHORT);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        request.targetPrice = BOUNTY_PRICE;
        request.bounds.maxExplicitFeesAssets = 0;
        _rejectImpossible(request);
        request.bounds.maxExplicitFeesAssets = type(uint256).max;
        request.bounds.maxActionChargeAssets = 0;
        _rejectImpossible(request);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
    }

    function test_IncreaseMustRespectCumulativePositionSizeBound() public {
        _position(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6);
        request.bounds.maxPostPositionSize = BOUNTY_SIZE;
        _rejectImpossible(request);
        request.bounds.maxPostPositionSize = 2 * BOUNTY_SIZE;
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(request);
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, 2 * BOUNTY_SIZE);
    }

    function test_NotionalAndFeeCeilingsCannotHideImpossibleReplacementMinimum() public {
        _position(CfdTypes.Side.SHORT);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6);
        request.bounds.maxExecutionNotionalAssets = 999e6;
        _rejectOpen(request, CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL);
        request.bounds.maxExecutionNotionalAssets = type(uint256).max;
        // The smallest planner-valid $1000 position costs $0.40 at four bps.
        request.bounds.maxExplicitFeesAssets = 400_000 - 1;
        _rejectOpen(request, CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL);
    }

    function test_UnavoidableFeesCannotConsumeTheReplacementReserve() public {
        _position(CfdTypes.Side.SHORT);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1e6),
            CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED
        );
    }

    function test_ImpossibleOpenTargetAndPostSizeRejected() public {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6);
        request.targetPrice = CAP_PRICE + 1;
        _rejectImpossible(request);
        request.targetPrice = 1;
        request.bounds.maxPostPositionSize = BOUNTY_SIZE - 1;
        _rejectImpossible(request);
    }

    function test_AboveCapUpperTargetsRemainExecutable() public {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6);
        request.targetPrice = type(uint256).max;
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(request);
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        // LONG CLOSE also has an upper target; a value above CAP must not be treated as impossible.
        _fundTrader(BOUNTY_OTHER, 5000e6);
        _open(BOUNTY_OTHER, CfdTypes.Side.LONG, BOUNTY_SIZE, 1000e6, BOUNTY_PRICE);
        request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        request.targetPrice = type(uint256).max;
        vm.prank(BOUNTY_OTHER);
        router.commitOrder(request);
    }

    function test_ValidCloseDoesNotHideTooSmallReplacementEvenWithStaleMark() public {
        _position(CfdTypes.Side.LONG);
        vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        OrderV3Types.OrderRequest memory request =
            _bountyRequest(CfdTypes.Side.SHORT, false, CfdTypes.SIZE_QUANTUM, 1000e6);
        _rejectOpen(request, CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL);
    }

    function test_ValidCloseDoesNotHideUnfundedReplacement() public {
        _position(CfdTypes.Side.LONG);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 0),
            CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED
        );
    }

    function test_ValidCloseDoesNotHideTerminalBookSizeLimit() public {
        _position(CfdTypes.Side.LONG);
        _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        uint256 size = (uint256(int256(type(int112).max)) + 1) * CfdTypes.SIZE_QUANTUM;
        _rejectOpen(
            _bountyRequest(CfdTypes.Side.SHORT, false, size, 1000e6),
            CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED
        );
    }

    function test_ValidQueuedFlipsExecuteInBothDirectionsWithFreshAndStaleMarks() public {
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 stale; stale < 2; ++stale) {
                uint256 saved = vm.snapshotState();
                CfdTypes.Side side = CfdTypes.Side(direction);
                _position(side);
                if (stale != 0) {
                    vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
                }
                uint64 closeId = _bountyCommit(BOUNTY_TRADER, side, true, BOUNTY_SIZE, 0);
                uint64 openId = _bountyCommit(BOUNTY_TRADER, _opposite(side), false, BOUNTY_SIZE, 1000e6);
                _bountyExecute(closeId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
                _bountyExecute(openId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
                (uint256 size,,,, CfdTypes.Side liveSide,,) = engine.positions(BOUNTY_TRADER);
                assertEq(size, BOUNTY_SIZE);
                assertEq(uint8(liveSide), uint8(_opposite(side)));
                assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
                assertTrue(vm.revertToStateAndDelete(saved));
            }
        }
    }

    function test_StackedPartialClosesPermitAValidReplacement() public {
        _position(CfdTypes.Side.LONG);
        uint64 first = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        uint64 second = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        uint64 opening = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6);
        _bountyExecute(first, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _bountyExecute(second, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _bountyExecute(opening, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(router.pendingCloseSize(BOUNTY_TRADER), 0);
    }

    function test_DeadlineEqualityStillCountsTheClose() public {
        _position(CfdTypes.Side.LONG);
        uint64 closeId = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        bytes[] memory data = _mockPythUpdateData(BOUNTY_PRICE);
        vm.warp(router.lifecycleBook().orderTiming(closeId).executionDeadline);
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 1000e6);
        // Retain the first authored historical tick and execute at equality rather than after expiry.
        vm.roll(block.number + 1);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(closeId, data);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
    }

    function test_ExactReplaySurvivesExpiryAndConfigurationChange() public {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 1000e6);
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(request);
        engineAdmin.proposeCalendarConfig(_engineCalendarConfig());
        vm.warp(engineAdmin.calendarConfigActivationTime());
        engineAdmin.finalizeCalendarConfig();
        bytes32 beforeState = _state(request.clientOrderId);
        vm.prank(BOUNTY_TRADER);
        assertEq(router.commitOrder(request), id);
        assertEq(_state(request.clientOrderId), beforeState);
    }

    function test_OwnBountyCannotInvalidateFreshOpenAtUnchangedPrice() public {
        uint256 margin = _bountyBoundary();
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, margin);
        request.targetPrice = CAP_PRICE;
        assertEq(
            engineLens.previewOpenRevertCode(BOUNTY_TRADER, request.side, BOUNTY_SIZE, margin, CAP_PRICE),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "unreserved preview passes"
        );
        _rejectOpen(request, CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN);
        // The nearby funded control must survive its own bounty lock and execute at the same price.
        _fundTrader(BOUNTY_TRADER, 1e6);
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(request);
        _bountyExecute(id, CAP_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
    }

    function _bountyBoundary() private returns (uint256 margin) {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.05e18;
        _setRiskParams(params);
        _mark(CAP_PRICE);
        _fundTrader(BOUNTY_OTHER, 100_000e6);
        _open(BOUNTY_OTHER, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, CAP_PRICE);
        _mark(CAP_PRICE);
        _fundTrader(BOUNTY_TRADER, 1000e6);
        ICfdEngineTypes.OpenPreview memory quote =
            engineLens.previewOpen(BOUNTY_TRADER, CfdTypes.Side.LONG, BOUNTY_SIZE, 1000e6, CAP_PRICE);
        assertLt(quote.vpiAssets, -int256(quote.executionFeeAssets));
        uint256 notional = (BOUNTY_SIZE / CfdTypes.SIZE_QUANTUM) * CAP_PRICE;
        uint256 reserve = notional * params.bountyBps / 10_000;
        if (reserve < params.minBountyAssets) {
            reserve = params.minBountyAssets;
        }
        uint256 bounty = notional * router.openOrderExecutionBountyBps() / 10_000;
        if (bounty < router.minOpenOrderExecutionBountyAssets()) {
            bounty = router.minOpenOrderExecutionBountyAssets();
        }
        if (bounty > router.maxOpenOrderExecutionBountyAssets()) {
            bounty = router.maxOpenOrderExecutionBountyAssets();
        }
        margin = quote.initialMarginRequirementAssets + reserve + quote.executionFeeAssets - bounty + 1;
        uint256 free = clearinghouse.getAccountAssetBuckets(BOUNTY_TRADER).freeSettlementAssets;
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdraw(BOUNTY_TRADER, free - margin - bounty);
    }

    function _position(
        CfdTypes.Side side
    ) private {
        _fundTrader(BOUNTY_TRADER, 5000e6);
        _open(BOUNTY_TRADER, side, BOUNTY_SIZE, 1000e6, BOUNTY_PRICE);
    }

    function _mark(
        uint256 price
    ) private {
        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
    }

    function _opposite(
        CfdTypes.Side side
    ) private pure returns (CfdTypes.Side) {
        return side == CfdTypes.Side.LONG ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
    }

    function _rejectOpen(
        OrderV3Types.OrderRequest memory request,
        CfdEnginePlanTypes.OpenRevertCode code
    ) private {
        _reject(
            request,
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, uint8(code))
        );
    }

    function _rejectImpossible(
        OrderV3Types.OrderRequest memory request
    ) private {
        _reject(request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ImpossibleExecutionRequest.selector));
    }

    function _reject(
        OrderV3Types.OrderRequest memory request,
        bytes memory reason
    ) private {
        bytes32 beforeState = _state(request.clientOrderId);
        vm.expectRevert(reason);
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(request);
        assertEq(_state(request.clientOrderId), beforeState, "rejection leaves identity, queue and custody unchanged");
    }

    function _state(
        bytes32 clientOrderId
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                router.nextCommitId(),
                router.nextExecuteId(),
                router.getAccountReservations(BOUNTY_TRADER),
                router.lifecycleBook().clientIntent(BOUNTY_TRADER, clientOrderId),
                clearinghouse.getAccountAssetBuckets(BOUNTY_TRADER),
                clearinghouse.totalBountyReservationsAssets(BOUNTY_TRADER),
                clearinghouse.balanceAssets(BOUNTY_KEEPER),
                engine.positionEpoch(BOUNTY_TRADER),
                pool.totalAssets()
            )
        );
    }

}
