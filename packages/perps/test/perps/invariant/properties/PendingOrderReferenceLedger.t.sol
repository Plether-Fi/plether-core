// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PendingOrderReferenceLedger} from "../ghost/PendingOrderReferenceLedger.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Input-only golden histories check the mixed campaign's pending-order oracle before it judges production.
contract PendingOrderReferenceLedgerTest is Test {

    PendingOrderReferenceLedger private ledger;

    function setUp() public {
        ledger = new PendingOrderReferenceLedger();
    }

    function test_LiquidationConsumesOwnMarginFifoAndOnlyReleasesTheRemainder() public {
        assertEq(ledger.head(), 1);
        assertEq(ledger.tail(), 0);
        _open(0, 1, 100e6);
        _open(1, 2, 300e6);
        _open(0, 3, 200e6);
        assertEq(ledger.consumeMargin(0, 125e6), 125e6);
        assertEq(uint8(ledger.marginStatus(1)), 2, "First reservation fully consumed");
        assertEq(uint8(ledger.marginStatus(3)), 1, "Second remains active after partial consumption");
        assertEq(ledger.order(3).remainingMargin, 175e6);
        assertEq(ledger.count(0), 2, "Consumed reservation is still a pending order");
        assertEq(ledger.margin(1), 300e6, "Another actor's interleaved margin is protected");

        assertEq(ledger.takeBounty(1), 100_000);
        assertEq(ledger.takeBounty(3), 100_000);
        assertEq(ledger.bounty(0), 0, "Forfeiture precedes order cleanup");
        assertEq(ledger.releaseMargin(1), 0);
        assertEq(ledger.releaseMargin(3), 175e6);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.AccountLiquidated);
        ledger.finalize(3, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.AccountLiquidated);
        assertEq(uint8(ledger.marginStatus(1)), 2);
        assertEq(uint8(ledger.marginStatus(3)), 3);
        assertEq(ledger.head(), 2);
        assertEq(ledger.tail(), 2);
        assertEq(ledger.liveCount(), 1);
        assertEq(ledger.accountIds(0).length, 0);
        assertEq(ledger.bounty(1), 100_000);
        assertEq(ledger.order(1).originalMargin, 100e6, "History preserves consumed principal");
        assertEq(ledger.order(3).originalMargin, 200e6, "History preserves original, not refunded principal");
    }

    function test_TerminalReplayRetainsRequestAndGenerationWithoutNewReservation() public {
        OrderV3Types.OrderRequest memory request = _request(1, CfdTypes.Side.LONG, 20, 0, true);
        uint64 id = ledger.commit(0, 2, request, 0, 0, 100, 10);
        assertEq(ledger.order(id).sourceGeneration, 0);
        assertEq(ledger.takeBounty(id), 0);
        ledger.finalize(id, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.Expired);
        assertEq(ledger.head(), 0);
        // Later account generations and changed market bounty inputs cannot create a second reservation.
        assertEq(ledger.commit(0, 9, request, 200_000, 0, 900, 90), id);
        PendingOrderReferenceLedger.Order memory historical = ledger.order(id);
        assertEq(historical.generation, 2);
        assertEq(historical.sourceGeneration, 0);
        assertEq(historical.commitTime, 100);
        assertEq(historical.commitBlock, 10);
        assertEq(historical.deadline, 400);
        assertEq(historical.bountyFree, 0);
        assertEq(historical.bountyPledge, 0);
        assertEq(historical.bountyUsdc, 0);
        assertEq(historical.remainingBounty, 0);
        assertEq(abi.encode(historical.request), abi.encode(request));
        assertEq(uint8(historical.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(ledger.nextId(), 2);
        assertEq(ledger.liveCount(), 0);
        assertEq(ledger.margin(0), 0);
        assertEq(ledger.bounty(0), 0);

        request.bounds.maxActionChargeUsdc--;
        vm.expectRevert(PendingOrderReferenceLedger.ClientIdConflict.selector);
        ledger.commit(0, 9, request, 200_000, 0, 900, 90);
    }

    function test_QueuedExposureExcludesRiskOffOpensButPreservesCloses() public {
        ledger.commit(0, 2, _request(1, CfdTypes.Side.LONG, 20, 100e6, false), 100_000, 0, 100, 10);
        ledger.commit(0, 2, _request(2, CfdTypes.Side.LONG, 20, 0, true), 0, 0, 100, 10);
        ledger.commit(0, 2, _request(3, CfdTypes.Side.LONG, 30, 100e6, false), 100_000, 0, 100, 10);
        ledger.commit(0, 2, _request(4, CfdTypes.Side.LONG, 40, 0, true), 0, 0, 100, 10);
        ledger.commit(0, 2, _request(5, CfdTypes.Side.LONG, 50, 100e6, false), 100_000, 0, 100, 10);
        assertEq(ledger.queuedLots(0, 100, 0), 140, "Open increases and close reductions combine in queue order");
        assertEq(ledger.queuedLots(0, 100, 1), 120, "Cutoff removes the first twenty-lot increase");
        assertEq(ledger.queuedLots(0, 100, 2), 120, "A close below the cutoff remains valid queued exposure");
        assertEq(ledger.pendingCloseLots(0), 60, "Stored close count includes every still-pending close intent");
    }

    function test_CloseRejectsAnyFundedBountyButAllowsCloseOpenCloseHistory() public {
        OrderV3Types.OrderRequest memory request = _request(1, CfdTypes.Side.LONG, 20, 0, true);
        vm.expectRevert(PendingOrderReferenceLedger.InvalidRequest.selector);
        ledger.commit(0, 2, request, 1, 0, 100, 10);
        vm.expectRevert(PendingOrderReferenceLedger.InvalidRequest.selector);
        ledger.commit(0, 2, request, 0, 1, 100, 10);
        assertEq(ledger.commit(0, 2, request, 0, 0, 100, 10), 1);
        _open(0, 2, 100e6);
        assertEq(ledger.commit(0, 2, _request(3, CfdTypes.Side.LONG, 20, 0, true), 0, 0, 100, 10), 3);
        assertEq(ledger.takeBounty(1), 0);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.Expired);
        assertEq(ledger.head(), 2);
        assertEq(ledger.count(0), 2);
    }

    function test_CapacityIsFivePerActorAndExactReplayStillWorksAtCapacity() public {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 5; ++j) {
                _open(i, i * 5 + j + 1, 100e6);
            }
        }
        assertEq(ledger.liveCount(), 20);
        assertEq(ledger.count(0), 5);
        OrderV3Types.OrderRequest memory extra = _request(99, CfdTypes.Side.LONG, 20, 100e6, false);
        vm.expectRevert(PendingOrderReferenceLedger.CapacityExceeded.selector);
        ledger.commit(0, 2, extra, 100_000, 0, 100, 10);
        assertEq(ledger.commit(0, 2, _request(1, CfdTypes.Side.LONG, 20, 100e6, false), 100_000, 0, 100, 10), 1);
        ledger.releaseMargin(1);
        ledger.takeBounty(1);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.RiskOff);
        assertEq(ledger.commit(0, 3, extra, 100_000, 0, 200, 20), 21);
        assertEq(ledger.head(), 2);
        assertEq(ledger.tail(), 21);
        assertEq(ledger.liveCount(), 20);
        assertEq(ledger.count(0), 5);
        assertEq(ledger.order(1).generation, 2);
        assertEq(ledger.order(21).generation, 3);
    }

    function test_TerminalizationCannotSilentlyDropMarginOrBounty() public {
        _open(0, 1, 100e6);
        vm.expectRevert(PendingOrderReferenceLedger.MarginStillReserved.selector);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Executed, OrderV3Types.TerminalReason.Executed);
        ledger.releaseMargin(1);
        vm.expectRevert(PendingOrderReferenceLedger.BountyStillReserved.selector);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Executed, OrderV3Types.TerminalReason.Executed);
        ledger.takeBounty(1);
        ledger.finalize(1, OrderV3Types.LifecycleStatus.Executed, OrderV3Types.TerminalReason.Executed);
        assertEq(ledger.liveIds().length, 0);
    }

    function _open(
        uint256 actor,
        uint256 clientId,
        uint256 margin
    ) private {
        ledger.commit(actor, 2, _request(clientId, CfdTypes.Side(actor % 2), 20, margin, false), 100_000, 0, 100, 10);
    }

    function _request(
        uint256 clientId,
        CfdTypes.Side side,
        uint256 lots,
        uint256 margin,
        bool isClose
    ) private pure returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = bytes32(clientId);
        request.side = side;
        request.sizeDelta = lots * CfdTypes.SIZE_QUANTUM;
        request.marginDelta = margin;
        request.targetPrice = 80_000_000;
        request.isClose = isClose;
        request.bounds.submitBy = 1000;
        request.bounds.executionWindowSeconds = 300;
        request.bounds.allowedExecutionModes = 7;
        request.bounds.expectedConfigHash = bytes32(uint256(0xCAFE));
        request.bounds.maxExecutionBountyUsdc = 200_000;
        request.bounds.maxExecutionNotionalUsdc = 10_000e6;
        request.bounds.maxGrossAccountDebitUsdc = 1000e6;
        request.bounds.maxActionChargeUsdc = 100e6;
        request.bounds.maxExplicitFeesUsdc = 20e6;
        request.bounds.maxPostPositionSize = 10_000e18;
        request.bounds.minPostSettlementBalanceUsdc = 1;
        request.bounds.minPostPositionEquityUsdc = 2;
        request.bounds.maxPostLeverageBps = 500_000;
    }

}
