// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {Vm} from "forge-std/Vm.sol";

import {CfdClosePreviewTestBase} from "./CfdClosePreviewTestBase.sol";

contract CfdClosePreviewTest is CfdClosePreviewTestBase {

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
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 10_000_200_000,
            totalLockedMarginUsdc: 10_000e6,
            activePositionMarginUsdc: 10_000e6,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 200_000
        });
        IMarginClearinghouse.LockedMarginBuckets memory locked = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 10_000e6,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: 10_000e6
        });
        vm.mockCall(
            address(clearinghouse),
            abi.encodeWithSignature("getAccountUsdcBuckets(address)", ACCOUNT),
            abi.encode(buckets)
        );
        vm.mockCall(
            address(clearinghouse),
            abi.encodeWithSignature("getLockedMarginBuckets(address)", ACCOUNT),
            abi.encode(locked)
        );
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, size);
        uint256 adversePrice = entry * 999 / 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, 0, 200_000
            )
        );
        policyEvaluator.assessOrder(
            address(engine), o, KEEPER, adversePrice, 1_000_000_000e6, uint64(block.timestamp), _bounds(), 200_000
        );
        CfdClosePreview.ClosePreview memory p = _preview(o, adversePrice, KEEPER);
        assertEq(p.assessment.preSettlementBalanceUsdc, 10_000_200_000);
        assertEq(p.assessment.postSettlementBalanceUsdc, 0);
        assertEq(p.assessment.actionChargeCollectedUsdc, 0);
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

    function test_ExactFundingChangesCollectedCharges() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        OrderV2Types.ExecutionAssessment memory unreserved = policyEvaluator.assessOrder(
            address(engine), o, KEEPER, 95_000_000, pool.totalAssets(), uint64(block.timestamp), _bounds(), 200_000
        );
        (, CfdClosePreview.ClosePreview memory p) = _commitParity(o, 95_000_000, KEEPER);
        assertEq(unreserved.actionChargeCollectedUsdc, 200_000);
        assertEq(p.assessment.actionChargeCollectedUsdc, 0);
        assertEq(p.assessment.postSettlementBalanceUsdc, unreserved.postSettlementBalanceUsdc + 200_000);
    }

    function test_OneAtomicUnitShortMatchesCommitFundingError() public {
        _openNormally(CfdTypes.Side.LONG, 199_999);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE);
        bytes memory err = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector, 200_000, 199_999, 0
        );
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
    }

    function test_OtherOrderBountyIsNotTheProspectiveBounty() public {
        _openNormally(CfdTypes.Side.LONG, 2_400_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE / 2);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 200_000);
        _commitParity(o, PRICE, KEEPER);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 400_000);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 2e6);
    }

    function test_StaleStoredMarkStillAllowsCommit() public {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        _commitParity(_order(CfdTypes.Side.LONG, SIZE), PRICE, KEEPER);
    }

    function test_UnhealthyPartialCloseMatchesCommitError() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE / 2);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
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
        vm.mockCall(address(router), abi.encodeWithSignature("closeOrderExecutionBountyUsdc()"), abi.encode(uint256(0)));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE);
        CfdClosePreview.ClosePreview memory p = _preview(o, PRICE, KEEPER);
        assertEq(p.commitmentCarryUsdc, 0);
        assertEq(p.executionBountyUsdc, 0);
        OrderV2Types.ExecutionAssessment memory a = policyEvaluator.assessOrder(
            address(engine), o, KEEPER, PRICE, pool.totalAssets(), uint64(block.timestamp), _bounds(), 0
        );
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
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), reserveBefore + 200_000);
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
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, p.assessment);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), p.assessment.postTraderClaimUsdc);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), p.assessment.postSettlementBalanceUsdc);
    }

    function test_InvalidSizesAndMissingMarkUseCommitErrors() public {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 0);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        o.sizeDelta = SIZE + CfdTypes.SIZE_QUANTUM;
        vm.expectRevert(ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        o.sizeDelta = SIZE - 1;
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidCloseSizeQuantum.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        o.sizeDelta = SIZE;
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkTime()"), abi.encode(uint64(0)));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
    }

    function test_Runtime_ClosePreviewFitsEip170() public view {
        assertLe(address(previewer).code.length, 24_576);
    }

}

contract CfdClosePreviewCommitGatesTest is CfdClosePreviewTestBase {

    function test_WrongSideMatchesRouterCommitError() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        vm.mockCall(address(router), abi.encodeWithSignature("closeOrderExecutionBountyUsdc()"), abi.encode(uint256(0)));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
    }

    function test_PartialCloseDustBoundaryMatchesRouterCommit() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.prank(address(router));
        engine.updateMarkPrice(101_000_000, uint64(block.timestamp));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 9 * CfdTypes.SIZE_QUANTUM);
        bytes memory err = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11);
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, 101_000_000, uint64(block.timestamp), _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        o.sizeDelta = 10 * CfdTypes.SIZE_QUANTUM;
        _commitParity(o, 101_000_000, KEEPER);
    }

    function test_DustChecksUseFallbackAndCappedMarkEvenWithZeroBounty() public {
        _openNormally(CfdTypes.Side.LONG, 20e6);
        vm.mockCall(address(router), abi.encodeWithSignature("closeOrderExecutionBountyUsdc()"), abi.encode(uint256(0)));
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, 9 * CfdTypes.SIZE_QUANTUM);
        bytes memory err = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11);
        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkPrice()"), abi.encode(uint256(0)));
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);

        vm.mockCall(address(engine), abi.encodeWithSignature("lastMarkPrice()"), abi.encode(uint256(3e8)));
        o.sizeDelta = 4 * CfdTypes.SIZE_QUANTUM;
        vm.expectRevert(err);
        previewer.previewClose(address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds());
        vm.expectRevert(err);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
    }

    function test_FullCloseBelowDustFloorMatchesRouterCommit() public {
        // Opens must support the minimum liquidation charge; a valid partial close can leave a smaller remainder.
        _openNormally(CfdTypes.Side.LONG, 20e6);
        (uint64 id,) = _commitParity(_order(CfdTypes.Side.LONG, SIZE - 9 * CfdTypes.SIZE_QUANTUM), PRICE, KEEPER);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 9 * CfdTypes.SIZE_QUANTUM);
        vm.prank(address(router));
        engine.updateMarkPrice(101_000_000, uint64(vm.getBlockTimestamp()));
        _commitParity(_order(CfdTypes.Side.LONG, size), 101_000_000, KEEPER);
    }

}

contract CfdClosePreviewCarryTest is CfdClosePreviewTestBase {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 500;
    }

    /// @dev Default-risk real-stack regression: the liquidation reserve prevents underflow, but an unreserved
    ///      assessment spends the bounty backing on fees. The hardened evaluator's guard is not reached here;
    ///      this successful-path mispricing is shared with the v1.2.3 evaluator.
    function test_AdverseFullConsumptionRegression() public {
        _fundTrader(ACCOUNT, 250_400_000);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 250e6, PRICE, false);
        bytes[] memory openUpdate = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory opened = router.executeOrder(openId, openUpdate);
        assertEq(uint8(opened.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 200_000);
        assertGe(clearinghouse.liquidationReserveUsdc(ACCOUNT), 200_000);

        uint256 adversePrice = 1025e5;
        CfdTypes.Order memory o = _order(CfdTypes.Side.LONG, SIZE);
        OrderV2Types.ExecutionAssessment memory unreserved = policyEvaluator.assessOrder(
            address(engine), o, KEEPER, adversePrice, pool.totalAssets(), uint64(block.timestamp), _bounds(), 200_000
        );
        assertEq(unreserved.actionChargeCollectedUsdc, 200_000);
        (uint64 closeId, CfdClosePreview.ClosePreview memory p) = _commitParity(o, adversePrice, KEEPER);
        assertEq(p.assessment.actionChargeCollectedUsdc, 0);
        assertEq(p.assessment.postSettlementBalanceUsdc, unreserved.postSettlementBalanceUsdc + 200_000);

        bytes[] memory closeUpdate = _mockPythUpdateData(adversePrice);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory closed = router.executeOrder(closeId, closeUpdate);
        assertEq(uint8(closed.status), uint8(OrderV2Types.LifecycleStatus.Executed));
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
        assertEq(p.assessment.carryUsdc, 0);
    }

    function test_CarryExhaustingFreeSettlementMatchesFundingFailure() public {
        _openNormally(CfdTypes.Side.SHORT, 200_000);
        vm.warp(block.timestamp + 200 * 365 days);
        assertGt(_expectedIndexedCarryUsdc(ACCOUNT), clearinghouse.pnlPledgeUsdc(ACCOUNT) + 200_000);
        CfdTypes.Order memory o = _order(CfdTypes.Side.SHORT, SIZE);
        (bool previewOk, bytes memory previewError) = address(previewer)
            .staticcall(
                abi.encodeCall(
                    previewer.previewClose, (address(engine), o, KEEPER, PRICE, uint64(block.timestamp), _bounds())
                )
            );
        assertFalse(previewOk);
        assertEq(bytes4(previewError), ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        vm.expectRevert(previewError);
        vm.prank(ACCOUNT);
        router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
    }

}
