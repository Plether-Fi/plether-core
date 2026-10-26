// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "../../CfdClosePreviewTestBase.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
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
        (CfdEnginePlanTypes.CloseDelta memory d, OrderV3Types.ExecutionAssessment memory assessment) = _planAndAssess(f);
        _assertCombinedFunding(d, f.vpiBacking);
        assertEq(assessment.carryAssets, d.pendingCarryAssets);
        assertEq(assessment.actionChargeCollectedAssets, d.realizedCarryAssets + d.actionChargeCollectedAssets);
        assertEq(assessment.actionChargeAssessedAssets, d.realizedCarryAssets + d.actionChargeAssessedAssets);

        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(f.closeId, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertReceipt(logs, f.closeId, assessment);
        _assertSettlementEvents(logs, d);
        _assertFinalState(f, d, assessment);
    }

    function _planAndAssess(
        CloseFixture memory f
    ) private returns (CfdEnginePlanTypes.CloseDelta memory d, OrderV3Types.ExecutionAssessment memory assessment) {
        CfdTypes.Order memory order = _order(CfdTypes.Side.LONG, SIZE);
        order.orderId = f.closeId;
        order.commitTime = f.commitTime;
        order.commitBlock = f.commitBlock;
        uint256 depth = pool.totalAssets();
        {
            ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
            vm.prank(address(engine));
            CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(ACCOUNT, depth);
            d = engine.planner().planClose(snap, order, CLOSE_PRICE);
        }
        assessment = policyEvaluator.assessCommittedOrder(address(engine), f.closeId, KEEPER, CLOSE_PRICE);
    }

    function _prepareClose() private returns (CloseFixture memory f) {
        // All balances, VPI backing, and reservations originate from deposits and router trades.
        _fundTrader(SKEW_TRADER, 50_000e6);
        _openSkew(200_000e18, 20_000e6);
        _openNormally(CfdTypes.Side.LONG, 200e6);
        (,,,,,, int256 accruedVpi) = engine.positions(ACCOUNT);
        assertLt(accruedVpi, 0, "Minority open must earn a backed rebate");
        f.vpiBacking = clearinghouse.vpiRebateReserveAssets(ACCOUNT);
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
        clearinghouse.withdraw(ACCOUNT, clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets);
        vm.stopPrank();
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginAssets, 120e6);
        assertEq(clearinghouse.vpiRebateReserveAssets(ACCOUNT), f.vpiBacking);
        f.settlement = clearinghouse.balanceAssets(ACCOUNT);
        f.poolCash = pool.totalAssets();
        f.treasury = clearinghouse.balanceAssets(engine.protocolTreasury());
        f.keeper = clearinghouse.balanceAssets(KEEPER);
        f.bounties = clearinghouse.totalBountyReservationsAssets(ACCOUNT);
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
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
    }

    function _assertCombinedFunding(
        CfdEnginePlanTypes.CloseDelta memory d,
        uint256 backing
    ) private pure {
        assertTrue(d.valid);
        assertGt(d.pendingCarryAssets, 0, "Carry must accrue after reservations are installed");
        assertEq(d.realizedCarryAssets, d.pendingCarryAssets);
        assertGt(d.pricePnlPledgeConsumedAssets, 0);
        assertGt(d.unlockMarginAssets, 0, "Unused pledge must contribute to action collection");
        assertGt(d.liquidationReserveReleaseAssets, 0);
        assertGt(d.closeState.vpiDeltaAssets, int256(backing));
        assertEq(d.vpiRebateReserveConsumedAssets, backing);
        assertEq(d.vpiRebateReserveAfterAssets, 0);
        assertEq(d.actionReserveConsumedAssets, 0, "Generic collection must protect execution bounties");
        assertEq(d.actionChargeWithheldAssets, 0);
        assertEq(d.actionChargeWaivedAssets, 0);
        assertEq(d.actionChargeCollectedAssets, d.actionChargeAssessedAssets);
        assertEq(d.actionChargeAssessedAssets, uint256(d.closeState.vpiDeltaAssets) + d.closeState.executionFeeAssets);
        uint256 releasedSurplus = d.unlockMarginAssets + d.liquidationReserveReleaseAssets;
        assertEq(d.actionCommittedMarginConsumedAssets, d.actionChargeAssessedAssets - backing - releasedSurplus);
        assertGt(d.actionCommittedMarginConsumedAssets, 20e6, "First reservation must be exhausted");
        assertLt(d.actionCommittedMarginConsumedAssets, 120e6, "Second reservation must retain its unused balance");
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
                assertEq(collected, d.realizedCarryAssets);
                assertEq(pledge, collected);
                assertEq(free, 0);
                assertEq(unpaid, 0);
                ++carryEvents;
            }
            if (logs[i].emitter == address(engine.settlementSidecar()) && logs[i].topics[0] == ACTION_SETTLED) {
                (uint256 assessed, uint256 recovered, uint256 waived) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(assessed, d.actionChargeAssessedAssets);
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
        OrderV3Types.ExecutionAssessment memory assessment
    ) private view {
        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(f.firstPendingId);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(f.secondPendingId);
        assertEq(uint8(first.status), uint8(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(first.remainingAmountAssets, 0);
        assertEq(uint8(second.status), uint8(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(second.remainingAmountAssets, 120e6 - d.actionCommittedMarginConsumedAssets);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).committedOrderMarginAssets, second.remainingAmountAssets);
        assertEq(clearinghouse.totalBountyReservationsAssets(ACCOUNT), f.bounties - f.closeBounty);
        assertEq(
            _executionBountyReserve(f.firstPendingId) + _executionBountyReserve(f.secondPendingId),
            f.bounties - f.closeBounty
        );
        assertEq(clearinghouse.actionReserveAssets(ACCOUNT), f.bounties - f.closeBounty);
        assertEq(clearinghouse.balanceAssets(KEEPER) - f.keeper, f.closeBounty);
        assertEq(router.pendingOrderCounts(ACCOUNT), 2);
        assertEq(clearinghouse.getAccountAssetBuckets(ACCOUNT).freeSettlementAssets, 0);
        assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), 0);
        assertEq(clearinghouse.liquidationReserveAssets(ACCOUNT), 0);
        assertEq(clearinghouse.vpiRebateReserveAssets(ACCOUNT), 0);
        assertEq(engine.unsettledCarryAssets(ACCOUNT), 0);
        assertEq(engine.traderClaimBalanceAssets(ACCOUNT), 0);
        assertEq(terminalNavBook.curveHashOf(ACCOUNT), bytes32(0));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 0);
        uint256 balance = clearinghouse.balanceAssets(ACCOUNT);
        assertEq(balance, assessment.postSettlementBalanceAssets);
        assertEq(balance, second.remainingAmountAssets + f.bounties - f.closeBounty);
        assertEq(
            f.settlement - balance,
            d.realizedCarryAssets + d.pricePnlPledgeConsumedAssets + d.actionChargeCollectedAssets + f.closeBounty
        );
        uint256 treasuryCredit = clearinghouse.balanceAssets(engine.protocolTreasury()) - f.treasury;
        assertEq(treasuryCredit, d.actionProtocolFeeCreditedAssets + d.protocolFeeTopUpAssets);
        assertEq(treasuryCredit, d.executionFeeAssets);
        assertEq(pool.totalAssets() + treasuryCredit + balance + f.closeBounty, f.poolCash + f.settlement);
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().effectiveSolvencyAssets,
            d.solvency.effectiveAssetsAfterAssets
        );
    }

}
