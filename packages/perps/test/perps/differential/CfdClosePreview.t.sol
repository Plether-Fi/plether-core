// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {CfdClosePreviewTestBase} from "../CfdClosePreviewTestBase.sol";

import {CfdClosePreviewTestFixture, ILegacyClosePreview} from "../shared/CfdClosePreviewFixture.sol";

contract CfdClosePreviewTest is CfdClosePreviewTestFixture {

    function test_SyntheticCounterexampleUsesReservationAwarePreview() public {
        uint256 size = 15_927_400e18;
        uint256 entry = 98_895_064;
        uint256 maxProfit = size / 1e20 * (2e8 - entry);
        uint256 entryCost = size / 1e20 * entry;
        vm.mockCall(
            address(engine),
            abi.encodeWithSignature("positions(address)", ACCOUNT),
            abi.encode(size, 10_000e6, entry, maxProfit, CfdTypes.Side.SHORT, uint64(block.timestamp), int256(0))
        );
        vm.mockCall(
            address(engine),
            abi.encodeWithSignature("positionEntryCostUsdcAtoms(address)", ACCOUNT),
            abi.encode(entryCost)
        );
        vm.mockCall(
            address(engine),
            abi.encodeWithSignature("sides(uint256)", uint256(1)),
            abi.encode(maxProfit, size, entryCost * 1e12, 10_000e6)
        );
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkPrice()"), abi.encode(entry));
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkTime()"), abi.encode(uint64(block.timestamp)));
        vm.mockCall(address(pool), abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(1_000_000_000e6)));
        IMarginClearinghouse.PnlIsolationBuckets memory buckets = IMarginClearinghouse.PnlIsolationBuckets({
            settlementBalanceUsdc: 10_000_200_000,
            pnlPledgeUsdc: 10_000e6,
            liquidationReserveUsdc: 0,
            orderMarginUsdc: 0,
            actionReserveUsdc: 0,
            vpiRebateReserveUsdc: 0,
            totalLockedUsdc: 10_000e6,
            freeSettlementUsdc: 200_000
        });
        vm.mockCall(
            address(clearinghouse),
            abi.encodeWithSignature("getPnlIsolationBuckets(address)", ACCOUNT),
            abi.encode(buckets)
        );
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, size);
        uint256 adversePrice = entry * 999 / 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, 0, 200_000
            )
        );
        policyEvaluator.assessOrder(address(engine), o, KEEPER, adversePrice, 1_000_000_000e6, _bounds(), 200_000);
        CfdClosePreview.ClosePreview memory p = _preview(o, adversePrice, KEEPER);
        assertEq(p.assessment.preSettlementBalanceUsdc, 10_000_200_000);
        assertEq(p.assessment.postSettlementBalanceUsdc, 0);
        assertEq(p.assessment.actionChargeCollectedUsdc, 200_000);
        assertEq(p.commitmentCarryUsdc, 0);
    }

    function test_FullLongAtCurrentPrice() public {
        _lifecycle(CfdTypes.Side.LONG, SIZE, PRICE, false);
    }

    function test_FullShortAtAdversePrice() public {
        _lifecycle(CfdTypes.Side.SHORT, SIZE, 95_000_000, false);
    }

    function test_FullLongAtAdversePriceSelfExecution() public {
        _lifecycle(CfdTypes.Side.LONG, SIZE, 105_000_000, true);
    }

    function test_FullShortGain() public {
        _lifecycle(CfdTypes.Side.SHORT, SIZE, 105_000_000, false);
    }

    function test_PartialLong() public {
        _lifecycle(CfdTypes.Side.LONG, SIZE / 2, PRICE, false);
    }

    function test_PartialShortSelfExecution() public {
        _lifecycle(CfdTypes.Side.SHORT, SIZE / 2, PRICE, true);
    }

    function test_ExactFundingPreservesBountyWhileReleasedReservePaysCharges() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        OrderV3Types.ExecutionAssessment memory unreserved =
            policyEvaluator.assessOrder(address(engine), o, KEEPER, 95_000_000, pool.totalAssets(), _bounds(), 0);
        (, CfdClosePreview.ClosePreview memory p) = _commitParity(o, 95_000_000, KEEPER);
        assertEq(unreserved.actionChargeCollectedUsdc, _engineExecutionFeeUsdc(SIZE, 95_000_000));
        assertEq(p.assessment.actionChargeCollectedUsdc, unreserved.actionChargeCollectedUsdc);
        assertEq(p.assessment.postSettlementBalanceUsdc, unreserved.postSettlementBalanceUsdc);
    }

    function test_OneAtomicUnitShortUsesPledgeAndMatchesCommit() public {
        _openNormally(CfdTypes.Side.LONG, 199_999);
        (, CfdClosePreview.ClosePreview memory p) = _commitParity(_order(CfdTypes.Side.LONG, SIZE), PRICE, KEEPER);
        assertEq(p.commitment.bountyFromFreeUsdc, 0);
    }

    function test_OtherOrderBountyIsNotTheProspectiveBounty() public {
        _openNormally(CfdTypes.Side.LONG, 2_400_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE / 2);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        _commitParity(o, PRICE, KEEPER);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 2_400_000);
    }

    function test_StaleStoredMarkStillAllowsCommit() public {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        _commitParity(_order(CfdTypes.Side.LONG, SIZE), PRICE, KEEPER);
    }

    function test_UnhealthyPartialCloseMatchesCommitError() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(vm.getBlockTimestamp()));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE / 2);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
    }

    function test_FrozenFullCloseCommitParity() public {
        _openNormally(CfdTypes.Side.LONG, 40e6);
        vm.warp(1_710_021_600);
        assertTrue(engine.isOracleFrozen());
        _commitParity(_order(CfdTypes.Side.LONG, SIZE), PRICE, KEEPER);
    }

    function test_ZeroBountyPreviewDoesNotInventReservation() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE);
        CfdClosePreview.ClosePreview memory p = _preview(o, PRICE, KEEPER);
        assertEq(p.commitmentCarryUsdc, 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        OrderV3Types.ExecutionAssessment memory a =
            policyEvaluator.assessOrder(address(engine), o, KEEPER, PRICE, pool.totalAssets(), _bounds(), 0);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(p.assessment)));
    }

    function test_ExistingActionAndVpiReservesMatchLiveCommitment() public {
        _openNormally(CfdTypes.Side.LONG, 40e6);
        vm.startPrank(address(engine));
        clearinghouse.lockReservedSettlement(ACCOUNT, 3e6);
        clearinghouse.lockVpiRebateReserve(ACCOUNT, 5e6);
        vm.stopPrank();
        vm.prank(address(router.positionProtectionBook()));
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionTrigger, 99, 3e6);
        uint256 reserveBefore = clearinghouse.actionReserveUsdc(ACCOUNT);
        _commitParity(_order(CfdTypes.Side.LONG, SIZE / 2), PRICE, KEEPER);
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), reserveBefore);
        assertEq(clearinghouse.vpiRebateReserveUsdc(ACCOUNT), 5e6);
        assertEq(
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionTrigger, 99).amountUsdc, 3e6
        );
    }

    function test_PendingOpenMarginRemainsClassifiedDuringPreview() public {
        _openNormally(CfdTypes.Side.LONG, 200e6);
        vm.prank(ACCOUNT);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, PRICE, false);
        uint256 committed = clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc;
        assertEq(committed, 100e6);
        _commitParity(_order(CfdTypes.Side.LONG, SIZE), PRICE, KEEPER);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc, committed);
    }

    function test_DeferredClaimReceiptAndSettlementParity() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        // Model unavailable pool cash after a normal open, without forging account buckets or a close delta.
        usdc.burn(address(pool), usdc.balanceOf(address(pool)));
        (uint64 id, CfdClosePreview.ClosePreview memory p) =
            _commitParity(_order(CfdTypes.Side.SHORT, SIZE), 105_000_000, KEEPER);
        assertGt(p.assessment.postTraderClaimUsdc, 0);
        bytes[] memory update = _mockPythUpdateData(105_000_000);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, p.assessment);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), p.assessment.postTraderClaimUsdc);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), p.assessment.postSettlementBalanceUsdc);
    }

    function test_InvalidSizesAndMissingMarkUseCommitErrors() public {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 0);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        o.sizeDelta = SIZE + CfdTypes.SIZE_QUANTUM;
        vm.expectRevert(ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        o.sizeDelta = SIZE - 1;
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidCloseSizeQuantum.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        o.sizeDelta = SIZE;
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkTime()"), abi.encode(uint64(0)));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
    }

}

contract CfdClosePreviewCommitGatesTest is CfdClosePreviewTestBase {

    function _setCloseFloor(
        uint256 minimumUsdc
    ) private {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.minOpenNotionalUsdc = minimumUsdc;
        _setRouterConfig(config);
    }

    function test_WrongSideMatchesRouterCommitError() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
    }

    function test_PartialCloseDustBoundaryMatchesRouterCommit() public {
        _setCloseFloor(1000e6);
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(101_000_000, uint64(vm.getBlockTimestamp()));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 9 * CfdTypes.SIZE_QUANTUM);
        bytes memory err = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11);
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, 101_000_000, _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        o.sizeDelta = 10 * CfdTypes.SIZE_QUANTUM;
        _commitParity(o, 101_000_000, KEEPER);
    }

    function test_DustChecksRejectMissingMarkAndUseCappedMarkEvenWithZeroBounty() public {
        _setCloseFloor(1000e6);
        _openNormally(CfdTypes.Side.LONG, 20e6);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 9 * CfdTypes.SIZE_QUANTUM);
        bytes memory err = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11);
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkPrice()"), abi.encode(uint256(0)));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__MarkPriceUnavailable.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        vm.expectRevert(IOrderRouterErrors.OrderRouter__MarkPriceUnavailable.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkPrice()"), abi.encode(uint256(3e8)));
        o.sizeDelta = 4 * CfdTypes.SIZE_QUANTUM;
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
    }

    function test_FullCloseBelowDustFloorMatchesRouterCommit() public {
        // Opens must support the minimum liquidation charge; a valid partial close can leave a smaller remainder.
        _setCloseFloor(1000e6);
        _openNormally(CfdTypes.Side.LONG, 20e6);
        (uint64 id,) = _commitParity(_order(CfdTypes.Side.LONG, SIZE - 9 * CfdTypes.SIZE_QUANTUM), PRICE, KEEPER);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 9 * CfdTypes.SIZE_QUANTUM);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(101_000_000, uint64(vm.getBlockTimestamp()));
        _commitParity(_order(CfdTypes.Side.LONG, size), 101_000_000, KEEPER);
    }

    function test_PartialCloseTracksGovernedMinimumWhileFullCloseRemainsExempt() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(101_000_000, uint64(block.timestamp));

        CfdTypes.Order memory order = _order(CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM);
        uint256 snapshot = vm.snapshotState();
        _commitParity(order, 101_000_000, KEEPER);
        assertTrue(vm.revertToState(snapshot));
        vm.deleteStateSnapshot(snapshot);

        _setCloseFloor(1000e6);
        order.sizeDelta = 9 * CfdTypes.SIZE_QUANTUM;
        bytes memory dustError = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11);
        vm.expectRevert(dustError);
        previewer.previewClose(address(engine), order, KEEPER, 101_000_000, _bounds());
        vm.expectRevert(dustError);
        vm.prank(ACCOUNT);
        router.commitOrder(order.side, order.sizeDelta, 0, order.targetPrice, true);

        order.sizeDelta = 10 * CfdTypes.SIZE_QUANTUM;
        _commitParity(order, 101_000_000, KEEPER);
    }

}

contract CfdClosePreviewCarryTest is CfdClosePreviewTestBase {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 500;
    }

    /// @dev Under default risk parameters, a full close pays action fees from released liquidation reserve while
    ///      preserving the committed execution bounty. Unreserved assessment, committed preview, and live execution
    ///      must agree on the resulting settlement balances.
    function test_AdverseFullConsumptionRegression() public {
        _fundTrader(ACCOUNT, 250_400_000);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 250e6, PRICE, false);
        bytes[] memory openUpdate = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory opened = router.executeOrder(openId, openUpdate);
        assertEq(uint8(opened.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 200_000);
        assertGe(clearinghouse.liquidationReserveUsdc(ACCOUNT), 200_000);

        uint256 adversePrice = 1025e5;
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE);
        OrderV3Types.ExecutionAssessment memory unreserved =
            policyEvaluator.assessOrder(address(engine), o, KEEPER, adversePrice, pool.totalAssets(), _bounds(), 0);
        assertEq(unreserved.actionChargeCollectedUsdc, _engineExecutionFeeUsdc(SIZE, adversePrice));
        (uint64 closeId, CfdClosePreview.ClosePreview memory p) = _commitParity(o, adversePrice, KEEPER);
        assertEq(p.assessment.actionChargeCollectedUsdc, unreserved.actionChargeCollectedUsdc);
        assertEq(p.assessment.postSettlementBalanceUsdc, unreserved.postSettlementBalanceUsdc);

        bytes[] memory closeUpdate = _mockPythUpdateData(adversePrice);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory closed = router.executeOrder(closeId, closeUpdate);
        assertEq(uint8(closed.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(ACCOUNT);
        assertEq(sizeAfter, p.assessment.postPositionSize);
        // The oracle fixture advances one second, so carry can accrue after the preview.
        assertApproxEqAbs(marginAfter, p.assessment.postPositionMarginUsdc, 2000);
        assertApproxEqAbs(clearinghouse.balanceUsdc(ACCOUNT), p.assessment.postSettlementBalanceUsdc, 2000);
        assertApproxEqAbs(engine.traderClaimBalanceUsdc(ACCOUNT), p.assessment.postTraderClaimUsdc, 2000);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
    }

    function test_CommitCarryIsSeparateAndMatchesLiveCheckpoint() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        vm.warp(block.timestamp + 1 hours);
        (, CfdClosePreview.ClosePreview memory p) = _commitParity(_order(CfdTypes.Side.SHORT, SIZE), PRICE, KEEPER);
        assertGt(p.commitmentCarryUsdc, 0);
        assertEq(p.assessment.carryUsdc, p.commitmentCarryUsdc);
    }

    function test_CarryExhaustingFreeSettlementStillAllowsFullClose() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        vm.warp(block.timestamp + 200 * 365 days);
        assertGt(_expectedIndexedCarryUsdc(ACCOUNT), clearinghouse.pnlPledgeUsdc(ACCOUNT) + 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        (, CfdClosePreview.ClosePreview memory p) = _commitParity(o, PRICE, KEEPER);
        assertGt(p.commitment.carryOutstandingUsdc, 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(ACCOUNT), 0);
    }

}

/// @dev Regressions migrated from the retired USDC-grant preview: use the canonical V3 request all the way through
///      preview, commitment and execution. No grant, deposit or account funding occurs while closing.
contract CfdClosePreviewRequestTest is CfdClosePreviewTestBase {

    function test_ConflictingClientIdMatchesSubmissionEvenAfterDeadline() public {
        _openNormally(CfdTypes.Side.LONG, 40e6);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE / 2);
        IOrderLifecycleBook book = router.lifecycleBook();
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        bytes32 existingHash = book.clientIntent(ACCOUNT, request.clientOrderId).intentHash;
        request.sizeDelta = SIZE;
        vm.warp(uint256(request.bounds.submitBy) + 1);
        bytes memory expected = abi.encodeWithSelector(
            IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
            ACCOUNT,
            request.clientOrderId,
            existingHash,
            book.hashOrderRequest(ACCOUNT, request)
        );
        vm.expectRevert(expected);
        _requestPreview(request, PRICE);
        vm.expectRevert(expected);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
    }

    function test_ReservedClientIdMatchesSubmissionRejection() public {
        _openNormally(CfdTypes.Side.SHORT, 40e6);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        request.clientOrderId = OrderV3Types.protocolClientOrderId(keccak256("reserved-close"));
        bytes memory expected = abi.encodeWithSelector(
            IOrderLifecycleBook.OrderLifecycleBook__ClientIdDomainMismatch.selector, request.clientOrderId, false
        );
        vm.expectRevert(expected);
        _requestPreview(request, PRICE);
        vm.expectRevert(expected);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function test_PendingExactReplayReturnsIdentityWithoutAnotherClose() public {
        _openNormally(CfdTypes.Side.LONG, 40e6);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE);
        (uint64 id,) = _requestCommitParity(request, PRICE);
        // A second fresh full close would fail queued-position admission; an identical retry is a no-op.
        _assertReplay(request, id);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
        vm.warp(uint256(request.bounds.submitBy) + 1);
        _assertReplay(request, id);
    }

    function test_TerminalExactReplayIgnoresCurrentPositionAndConfiguration() public {
        _openNormally(CfdTypes.Side.SHORT, 40e6);
        OrderV3Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE);
        (uint64 id,) = _requestCommitParity(request, PRICE);
        _executeRequest(id, PRICE, 0);
        vm.warp(uint256(request.bounds.submitBy) + 1);
        routerAdmin.pause();
        vm.mockCall(
            address(router.lifecycleBook()),
            abi.encodeWithSelector(IOrderLifecycleBook.currentExecutionConfigHash.selector),
            abi.encode(keccak256("changed-after-execution"))
        );
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("planner()"), bytes("must not plan a replay"));
        _assertReplay(request, id);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function _assertReplay(
        OrderV3Types.OrderRequest memory request,
        uint64 id
    ) private {
        uint64 nextId = router.nextCommitId();
        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        CfdClosePreview.ClosePreview memory expected;
        expected.replayOrderId = id;
        CfdClosePreview.ClosePreview memory actual = _requestPreview(request, type(uint256).max);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "Replay must contain identity only");
        vm.prank(ACCOUNT);
        assertEq(router.commitOrder(request), id, "Submission must return the same existing order");
        assertEq(router.nextCommitId(), nextId);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balance);
    }

    function _request(
        CfdTypes.Side side,
        uint256 size
    ) internal view returns (OrderV3Types.OrderRequest memory r) {
        r.clientOrderId = keccak256("zero-bounty-close-preview");
        r.side = side;
        r.sizeDelta = size;
        r.targetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
        r.isClose = true;
        r.bounds = _bounds();
        r.bounds.submitBy = uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds());
        r.bounds.executionWindowSeconds = uint32(router.maxExecutionWindowSeconds());
        r.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
    }

    function _requestPreview(
        OrderV3Types.OrderRequest memory r,
        uint256 price
    ) internal view returns (CfdClosePreview.ClosePreview memory) {
        return previewer.previewClose(address(engine), ACCOUNT, r, KEEPER, price);
    }

    function _requestCommitParity(
        OrderV3Types.OrderRequest memory r,
        uint256 price
    ) internal returns (uint64 id, CfdClosePreview.ClosePreview memory p) {
        p = _requestPreview(r, price);
        CfdClosePreview.ClosePreview memory orderPreview =
            previewer.previewClose(address(engine), _order(r.side, r.sizeDelta), KEEPER, price, r.bounds);
        assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(orderPreview)), "both preview overloads agree");
        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        vm.prank(ACCOUNT);
        id = router.commitOrder(r);
        assertEq(settlementBefore - clearinghouse.balanceUsdc(ACCOUNT), p.commitmentCarryUsdc);
        OrderV3Types.ExecutionAssessment memory actual =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, price);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(p.assessment)));
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
    }

    function _executeRequest(
        uint64 id,
        uint256 price,
        uint256 expectedRemaining
    ) internal {
        uint256 supply = usdc.totalSupply();
        uint256 keeperBefore = clearinghouse.balanceUsdc(KEEPER);
        bytes[] memory update = _mockPythUpdateData(price);
        // The oracle fixture advances a second. Assess that exact execution timestamp, including any new carry.
        OrderV3Types.ExecutionAssessment memory expected =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, price);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, expected);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, expectedRemaining);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), expected.postSettlementBalanceUsdc);
        assertEq(usdc.totalSupply(), supply, "close requires no USDC grant");
        assertEq(clearinghouse.balanceUsdc(KEEPER), keeperBefore);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
    }

    function _requestLifecycle(
        CfdTypes.Side side,
        uint256 size,
        uint256 free
    ) internal {
        _openNormally(side, free);
        uint256 price = size == SIZE ? PRICE : (side == CfdTypes.Side.LONG ? PRICE - 1_000_000 : PRICE + 1_000_000);
        (uint64 id,) = _requestCommitParity(_request(side, size), price);
        _executeRequest(id, price, SIZE - size);
    }

    function test_RequestFullCloseFromZeroFreeSettlement() public {
        _requestLifecycle(CfdTypes.Side.LONG, SIZE, 0);
    }

    function test_RequestPartialCloseFromZeroFreeSettlement() public {
        _requestLifecycle(CfdTypes.Side.LONG, SIZE / 2, 0);
    }

    function test_RequestShortFullCloseWithSmallFreeSettlement() public {
        _requestLifecycle(CfdTypes.Side.SHORT, SIZE, 2000);
    }

    function test_RequestShortPartialCloseWithOneAtomFreeSettlement() public {
        _requestLifecycle(CfdTypes.Side.SHORT, SIZE / 2, 1);
    }

    function test_RequestPartialCloseFundsChargesFromSafeRelease() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(CfdTypes.Side.LONG, SIZE / 2);
        (uint64 id, CfdClosePreview.ClosePreview memory p) = _requestCommitParity(r, PRICE);
        assertGt(p.assessment.close.actionChargeFromReleasedMarginUsdc, 0);
        assertEq(p.assessment.close.actionChargeWaivedUsdc, 0);
        _executeRequest(id, PRICE, SIZE / 2);
    }

    function test_MaxOpenThenFullCloseWithoutTopUp() public {
        _maxOpenThenClose(false);
    }

    function test_MaxOpenThenPartialCloseWithoutTopUp() public {
        _maxOpenThenClose(true);
    }

    function _maxOpenThenClose(
        bool isPartial
    ) private {
        _fundTrader(ACCOUNT, 1000e6);
        uint256 margin = 1000e6 - router.maxOpenOrderExecutionBountyUsdc();
        ICfdEngineLens.MaxOpenQuote memory quote = engineLens.quoteMaxOpen(ACCOUNT, CfdTypes.Side.LONG, margin, PRICE);
        assertGt(quote.maxSizeDelta, 0);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, quote.maxSizeDelta, margin, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory opened = router.executeOrder(openId, update);
        assertEq(uint8(opened.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, quote.maxSizeDelta);
        assertLt(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 200_000);
        uint256 closeSize = isPartial ? (size / 2 / CfdTypes.SIZE_QUANTUM) * CfdTypes.SIZE_QUANTUM : size;
        uint256 price = isPartial ? PRICE - 1_000_000 : PRICE;
        (uint64 id,) = _requestCommitParity(_request(CfdTypes.Side.LONG, closeSize), price);
        _executeRequest(id, price, size - closeSize);
    }

}

contract CfdClosePreviewRequestCarryTest is CfdClosePreviewRequestTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 500;
    }

    function test_RequestCommitmentCarryIsCollectedExactlyOnce() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint64 id, CfdClosePreview.ClosePreview memory p) =
            _requestCommitParity(_request(CfdTypes.Side.LONG, SIZE), PRICE);
        assertGt(p.commitmentCarryUsdc, 0);
        assertEq(p.assessment.carryUsdc, p.commitmentCarryUsdc);
        _executeRequest(id, PRICE, 0);
    }

    function test_RequestCarryIncludedInActionChargeBound() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        OrderV3Types.OrderRequest memory r = _request(CfdTypes.Side.LONG, SIZE);
        CfdClosePreview.ClosePreview memory p = _requestPreview(r, PRICE);
        assertGt(p.commitmentCarryUsdc, 0);
        r.bounds.maxActionChargeUsdc = p.assessment.actionChargeAssessedUsdc;
        _requestPreview(r, PRICE);
        r.bounds.maxActionChargeUsdc -= 1;
        bytes memory err = abi.encodeWithSelector(
            ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
            OrderV3Types.ConstraintKind.ActionCharge,
            p.assessment.actionChargeAssessedUsdc,
            r.bounds.maxActionChargeUsdc
        );
        vm.expectRevert(err);
        previewer.previewClose(address(engine), ACCOUNT, r, KEEPER, PRICE);
        vm.expectRevert(err);
        previewer.previewClose(address(engine), _order(r.side, r.sizeDelta), KEEPER, PRICE, r.bounds);
    }

    function test_RequestUnpaidCarryAllowsFullCloseButRejectsPartialClose() public {
        _openNormally(CfdTypes.Side.SHORT, 0);
        vm.warp(vm.getBlockTimestamp() + 200 * 365 days);
        OrderV3Types.OrderRequest memory r = _request(CfdTypes.Side.SHORT, SIZE);
        CfdClosePreview.ClosePreview memory p = _requestPreview(r, PRICE);
        assertGt(p.commitment.carryOutstandingUsdc, 0);
        r.sizeDelta = SIZE / 2;
        bytes memory err = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__PartialCloseCarryUnfunded.selector, p.commitment.carryOutstandingUsdc
        );
        vm.expectRevert(err);
        previewer.previewClose(address(engine), ACCOUNT, r, KEEPER, PRICE);
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(r);
        r.sizeDelta = SIZE;
        _requestCommitParity(r, PRICE);
    }

}
