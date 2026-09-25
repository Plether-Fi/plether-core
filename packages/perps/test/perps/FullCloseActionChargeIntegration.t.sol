// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "./CfdClosePreviewTestBase.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Vm} from "forge-std/Vm.sol";

contract FullCloseActionChargeIntegrationTest is CfdClosePreviewTestBase {

    address private constant SKEW_TRADER = address(0x5CE0);
    uint256 private constant CLOSE_PRICE = 102_200_000;
    bytes32 private constant CARRY_SETTLED = keccak256("CarryRealized(address,uint256,uint256,uint256,uint256)");
    bytes32 private constant ACTION_SETTLED = keccak256("ActionChargeSettled(address,uint256,uint256,uint256)");

    struct CloseFixture {
        uint64 closeId;
        uint64 commitTime;
        uint64 commitBlock;
        uint64 firstPendingId;
        uint64 secondPendingId;
        uint256 vpiBacking;
        uint256 settlement;
        uint256 poolCash;
        uint256 treasury;
        uint256 keeper;
        uint256 bounties;
        uint256 closeBounty;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 500;
        params.vpiFactor = 0.1e18;
    }

    function test_RouterFullClose_CarryVpiBackingAndReleasedSurplusBeforeFifoCollection() public {
        CloseFixture memory f = _prepareClose();
        // Remain within the ordinary order deadline while accruing nonzero execution-time carry.
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory update = _mockPythUpdateData(CLOSE_PRICE);
        (CfdEnginePlanTypes.CloseDelta memory d, OrderV2Types.ExecutionAssessment memory assessment) = _planAndAssess(f);
        _assertCombinedFunding(d, f.vpiBacking);
        assertEq(assessment.carryUsdc, d.pendingCarryUsdc);
        assertEq(assessment.actionChargeCollectedUsdc, d.realizedCarryUsdc + d.actionChargeCollectedUsdc);
        assertEq(assessment.actionChargeAssessedUsdc, d.realizedCarryUsdc + d.actionChargeAssessedUsdc);

        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(f.closeId, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertReceipt(logs, f.closeId, assessment);
        _assertSettlementEvents(logs, d);
        _assertFinalState(f, d, assessment);
    }

    function _planAndAssess(
        CloseFixture memory f
    ) private returns (CfdEnginePlanTypes.CloseDelta memory d, OrderV2Types.ExecutionAssessment memory assessment) {
        uint64 publishTime = uint64(_mockHistoricalPublishTime());
        CfdTypes.Order memory order = _order(CfdTypes.Side.LONG, SIZE);
        order.orderId = f.closeId;
        order.commitTime = f.commitTime;
        order.commitBlock = f.commitBlock;
        uint256 depth = pool.totalAssets();
        {
            ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
            vm.prank(address(engine));
            CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(ACCOUNT, depth);
            d = engine.planner().planClose(snap, order, CLOSE_PRICE, publishTime);
        }
        assessment = policyEvaluator.assessOrder(
            address(engine), order, KEEPER, CLOSE_PRICE, depth, publishTime, _bounds(), f.closeBounty
        );
    }

    function _prepareClose() private returns (CloseFixture memory f) {
        // All balances, VPI backing, and reservations originate from deposits and router trades.
        _fundTrader(SKEW_TRADER, 50_000e6);
        _openSkew(200_000e18, 20_000e6);
        _openNormally(CfdTypes.Side.LONG, 200e6);
        (,,,,,, int256 accruedVpi) = engine.positions(ACCOUNT);
        assertLt(accruedVpi, 0, "Minority open must earn a backed rebate");
        f.vpiBacking = clearinghouse.vpiRebateReserveUsdc(ACCOUNT);
        assertEq(f.vpiBacking, uint256(-accruedVpi));
        assertGt(f.vpiBacking, 0);
        // Additional short interest makes the close's positive VPI exceed the original backed rebate.
        _openSkew(100_000e18, 10_000e6);

        f.commitTime = uint64(vm.getBlockTimestamp());
        f.commitBlock = uint64(vm.getBlockNumber());
        vm.startPrank(ACCOUNT);
        f.closeId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 0, type(uint256).max, true);
        f.firstPendingId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 20e6, PRICE, false);
        f.secondPendingId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, PRICE, false);
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc);
        vm.stopPrank();
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 0);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc, 120e6);
        assertEq(clearinghouse.vpiRebateReserveUsdc(ACCOUNT), f.vpiBacking);
        f.settlement = clearinghouse.balanceUsdc(ACCOUNT);
        f.poolCash = pool.totalAssets();
        f.treasury = clearinghouse.balanceUsdc(engine.protocolTreasury());
        f.keeper = clearinghouse.balanceUsdc(KEEPER);
        f.bounties = clearinghouse.totalBountyReservationsUsdc(ACCOUNT);
        f.closeBounty = _executionBountyReserve(f.closeId);
    }

    function _openSkew(
        uint256 size,
        uint256 margin
    ) private {
        vm.prank(SKEW_TRADER);
        uint64 id = router.commitOrder(CfdTypes.Side.SHORT, size, margin, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
    }

    function _assertCombinedFunding(
        CfdEnginePlanTypes.CloseDelta memory d,
        uint256 backing
    ) private pure {
        assertTrue(d.valid);
        assertGt(d.pendingCarryUsdc, 0, "Carry must accrue after reservations are installed");
        assertEq(d.realizedCarryUsdc, d.pendingCarryUsdc);
        assertGt(d.pricePnlPledgeConsumedUsdc, 0);
        assertGt(d.unlockMarginUsdc, 0, "Unused pledge must contribute to action collection");
        assertGt(d.liquidationReserveReleaseUsdc, 0);
        assertGt(d.closeState.vpiDeltaUsdc, int256(backing));
        assertEq(d.vpiRebateReserveConsumedUsdc, backing);
        assertEq(d.vpiRebateReserveAfterUsdc, 0);
        assertEq(d.actionReserveConsumedUsdc, 0, "Generic collection must protect execution bounties");
        assertEq(d.actionChargeWithheldUsdc, 0);
        assertEq(d.actionChargeWaivedUsdc, 0);
        assertEq(d.actionChargeCollectedUsdc, d.actionChargeAssessedUsdc);
        assertEq(d.actionChargeAssessedUsdc, uint256(d.closeState.vpiDeltaUsdc) + d.closeState.executionFeeUsdc);
        uint256 releasedSurplus = d.unlockMarginUsdc + d.liquidationReserveReleaseUsdc;
        assertEq(d.actionCommittedMarginConsumedUsdc, d.actionChargeAssessedUsdc - backing - releasedSurplus);
        assertGt(d.actionCommittedMarginConsumedUsdc, 20e6, "First reservation must be exhausted");
        assertLt(d.actionCommittedMarginConsumedUsdc, 120e6, "Second reservation must retain its unused balance");
    }

    function _assertSettlementEvents(
        Vm.Log[] memory logs,
        CfdEnginePlanTypes.CloseDelta memory d
    ) private view {
        uint256 carryEvents;
        uint256 actionEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 2 || logs[i].topics[1] != bytes32(uint256(uint160(ACCOUNT)))) {
                continue;
            }
            if (logs[i].emitter == address(engine) && logs[i].topics[0] == CARRY_SETTLED) {
                (uint256 collected, uint256 free, uint256 pledge, uint256 unpaid) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(collected, d.realizedCarryUsdc);
                assertEq(pledge, collected);
                assertEq(free, 0);
                assertEq(unpaid, 0);
                ++carryEvents;
            }
            if (logs[i].emitter == address(engine.settlementSidecar()) && logs[i].topics[0] == ACTION_SETTLED) {
                (uint256 assessed, uint256 recovered, uint256 waived) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(assessed, d.actionChargeAssessedUsdc);
                assertEq(recovered, assessed);
                assertEq(waived, 0);
                ++actionEvents;
            }
        }
        assertEq(carryEvents, 1, "Carry must be collected exactly once");
        assertEq(actionEvents, 1, "Action charge must be collected exactly once");
    }

    function _assertFinalState(
        CloseFixture memory f,
        CfdEnginePlanTypes.CloseDelta memory d,
        OrderV2Types.ExecutionAssessment memory assessment
    ) private view {
        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(f.firstPendingId);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(f.secondPendingId);
        assertEq(uint8(first.status), uint8(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(first.remainingAmountUsdc, 0);
        assertEq(uint8(second.status), uint8(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(second.remainingAmountUsdc, 120e6 - d.actionCommittedMarginConsumedUsdc);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginUsdc, second.remainingAmountUsdc);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), f.bounties - f.closeBounty);
        assertEq(
            _executionBountyReserve(f.firstPendingId) + _executionBountyReserve(f.secondPendingId),
            f.bounties - f.closeBounty
        );
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), f.bounties - f.closeBounty);
        assertEq(clearinghouse.balanceUsdc(KEEPER) - f.keeper, f.closeBounty);
        assertEq(router.pendingOrderCounts(ACCOUNT), 2);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 0);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.vpiRebateReserveUsdc(ACCOUNT), 0);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 0);
        assertEq(terminalNavBook.curveHashOf(ACCOUNT), bytes32(0));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 0);
        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        assertEq(balance, assessment.postSettlementBalanceUsdc);
        assertEq(balance, second.remainingAmountUsdc + f.bounties - f.closeBounty);
        assertEq(
            f.settlement - balance,
            d.realizedCarryUsdc + d.pricePnlPledgeConsumedUsdc + d.actionChargeCollectedUsdc + f.closeBounty
        );
        uint256 treasuryCredit = clearinghouse.balanceUsdc(engine.protocolTreasury()) - f.treasury;
        assertEq(treasuryCredit, d.actionProtocolFeeCreditedUsdc + d.protocolFeeTopUpUsdc);
        assertEq(treasuryCredit, d.executionFeeUsdc);
        assertEq(pool.totalAssets() + treasuryCredit + balance + f.closeBounty, f.poolCash + f.settlement);
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().effectiveSolvencyAssetsUsdc,
            d.solvency.effectiveAssetsAfterUsdc
        );
    }

}
