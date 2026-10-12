// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CarryReferenceLedger} from "../ghost/CarryReferenceLedger.sol";
import {LiquidationReferenceMath} from "../ghost/LiquidationReferenceMath.sol";
import {PendingOrderReferenceLedger} from "../ghost/PendingOrderReferenceLedger.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

/// @notice Real claim creation, carry exhaustion, and public Router liquidation against the mixed action ledger.
contract PerpMixedLiquidationTest is BasePerpTest {

    PerpMixedAccountingHandler private handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.005e18;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();
        handler = new PerpMixedAccountingHandler(
            usdc,
            baseMockPyth,
            engine,
            clearinghouse,
            pool,
            juniorVault,
            seniorVault,
            OrderRouter(address(router)),
            address(this)
        );
        handler.assertModel();
    }

    function test_BothSidesZeroPnlWaivesUncoveredCarryAndPreservesOldClaims() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 0);
            assertEq(v.pnl, 0);
            assertEq(v.claimConsumed, 0);
            assertGt(v.remainingClaim, 1500e6);
            assertEq(v.carryWithheld, 0);
            assertGt(v.carryWaived, 0);
            assertEq(v.fresh, 0);
            assertEq(v.immediate, 0);
            assertEq(v.deferred, 0);
            assertEq(handler.positivePnlLiquidations(), 0);
            assertEq(handler.liquidationCarryWaived(), v.carryWaived);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesPriceLossConsumesClaimsThenWritesOffTheUnbackedTail() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 1);
            assertEq(v.pnl, -int256(2000e6));
            assertGt(v.claimConsumed, 1500e6);
            assertEq(v.remainingClaim, 0);
            assertEq(v.pledgeConsumed, 0, "direct carry has already exhausted the pledge");
            assertGt(v.writtenOff, 0);
            assertEq(v.claimConsumed + v.writtenOff, 2000e6);
            assertEq(v.fresh, 0);
            assertGt(v.carryWaived, 0);
            assertEq(handler.liquidationClaimsConsumed(), v.claimConsumed);
            assertEq(handler.liquidationPriceWrittenOff(), v.writtenOff);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesPositivePnlWithholdsCarryAndPaysFreshCashImmediately() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 2);
            _assertProfitableCarrySettlement(v);
            assertGt(v.immediate, 0);
            assertEq(v.immediate, v.fresh);
            assertEq(v.deferred, 0);
            assertGt(v.retainedCash, 0);
            assertEq(handler.immediateLiquidationPayouts(), 1);
            assertEq(handler.deferredLiquidationPayouts(), 0);
            assertEq(handler.expectedPoolCash(), v.poolCashAfter, "immediate branch restores cash before settlement");
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesPositivePnlWithholdsCarryAndAddsFreshDeferredClaims() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 3);
            _assertProfitableCarrySettlement(v);
            assertGt(v.deferred, 0);
            assertEq(v.deferred, v.fresh);
            assertEq(v.immediate, 0);
            assertGt(v.remainingClaim - v.deferred, 1500e6, "new claim is added to the surviving old claim");
            assertEq(handler.immediateLiquidationPayouts(), 0);
            assertEq(handler.deferredLiquidationPayouts(), 1);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesFreshPayoutAtOneAtomBelowEqualAndAboveCashPriorityBoundary() public {
        for (uint256 side; side < 2; ++side) {
            for (uint8 scenario = 7; scenario < 10; ++scenario) {
                uint256 snapshot = vm.snapshotState();
                LiquidationReferenceMath.Values memory v = _runTerminal(side, scenario);
                _assertProfitableCarrySettlement(v);
                if (scenario == 7) {
                    assertEq(v.deferred, v.fresh, "one missing atom defers the entire fresh payout");
                    assertEq(v.immediate, 0);
                    assertEq(v.poolCashAfter, v.allClaimsAfter - v.deferred + v.fresh - 1);
                    assertEq(handler.immediateLiquidationPayouts(), 0);
                    assertEq(handler.deferredLiquidationPayouts(), 1);
                } else {
                    assertEq(v.immediate, v.fresh, "equality and one atom above both pay immediately");
                    assertEq(v.deferred, 0);
                    assertEq(v.poolCashAfter, v.allClaimsAfter + (scenario == 8 ? 0 : 1));
                    assertEq(handler.immediateLiquidationPayouts(), 1);
                    assertEq(handler.deferredLiquidationPayouts(), 0);
                }
                for (uint256 boundary; boundary < 3; ++boundary) {
                    assertEq(handler.liquidationPayoutBoundaries(boundary), boundary == scenario - 7 ? 1 : 0);
                }
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_BothSidesPositivePnlCanStillWaiveCarryWithoutAnyFreshPayout() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 4);
            assertEq(v.pnl, int256(2000e6));
            assertGt(v.carryWithheld, 0);
            assertGt(v.carryWaived, 0);
            assertEq(v.claimConsumed, 0);
            assertGt(v.remainingClaim, 1500e6);
            assertEq(v.fresh, 0);
            assertEq(v.immediate, 0);
            assertEq(v.deferred, 0);
            assertEq(v.gain, v.vpiWithheld + v.carryWithheld);
            assertEq(handler.positivePnlLiquidations(), 1);
            assertEq(handler.liquidationCarryWaived(), v.carryWaived);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesNegativeVpiReleasesBackingToRecoverCarryBeforeWaiver() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 10);
            assertGt(v.pnl, 0);
            assertGt(v.vpiWithheld, 0);
            assertGt(v.vpiConsumed, 0);
            assertGt(v.vpiReleased, 0);
            assertLt(uint256(v.pnl), v.vpiConsumed + v.vpiReleased, "tiny gain covers only part of the VPI clawback");
            assertEq(v.carryWithheld, 0, "VPI consumes the entire gain before carry withholding");
            assertEq(v.carryCash, v.vpiReleased, "released VPI backing is the only terminal carry cash source");
            assertGt(v.carryWaived, 0);
            assertEq(v.claimConsumed, 0);
            assertGt(v.remainingClaim, 1500e6, "old claims survive VPI and carry recovery");
            assertEq(v.fresh, 0);
            assertEq(v.immediate, 0);
            assertEq(v.deferred, 0);
            assertEq(handler.negativeVpiLiquidations(), 1);
            assertEq(handler.positivePnlLiquidations(), 1);
            assertEq(handler.liquidationClaimsConsumed(), 0);
            for (uint256 actor; actor < 4; ++actor) {
                assertEq(handler.traderState(actor).lots, 0, "the opposite hedger also closes normally");
            }
            handler.assertModel();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesTerminalCarryConsumesPendingMarginAndReleasesItsRemainder() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 11);
            assertEq(v.pnl, 0);
            assertEq(v.claimConsumed, 0);
            assertGt(v.remainingClaim, 1500e6);
            assertGt(v.committedConsumed, 0);
            assertLt(v.committedConsumed, 1020e6, "some queued margin remains to release after carry collection");
            assertEq(v.carryCash, v.committedConsumed);
            assertEq(v.carryWithheld, 0);
            assertEq(v.carryWaived, 0);
            assertEq(v.fresh, 0);
            assertEq(handler.liquidationPendingMarginConsumed(), v.committedConsumed);
            assertEq(handler.orders().count(side), 0);
            assertEq(handler.orders().liveCount(), 0);

            PendingOrderReferenceLedger.Order memory queued = handler.orders().order(handler.orders().nextId() - 1);
            assertEq(queued.actorIndex, side);
            assertEq(queued.originalMargin, 1020e6);
            assertEq(queued.remainingMargin, 0);
            assertEq(queued.remainingBounty, 0);
            assertEq(uint8(queued.marginStatus), uint8(PendingOrderReferenceLedger.MarginStatus.Released));
            assertEq(uint8(queued.status), uint8(OrderV3Types.LifecycleStatus.Failed));
            assertEq(uint8(queued.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
            OrderV3Types.TerminalOutcome memory outcome = router.lifecycleBook().terminalOutcome(queued.id);
            assertEq(outcome.account, handler.actorAt(side));
            assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
            assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
            assertTrue(queued.receiptHash != bytes32(0), "handler authenticated the permanent terminal receipt");
            assertEq(outcome.receiptHash, queued.receiptHash);
            handler.assertModel();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesLiquidationClearsFiveOwnOrdersAndPreservesInterleavedOtherAccount() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            uint256 entry = side == 0 ? 80_000_002 : 120_000_002;
            handler.openOrIncrease(side, 100, entry);
            uint64 otherId;
            for (uint256 j; j < 5; ++j) {
                handler.commitOpen(side, 17, entry);
                if (j == 1) {
                    handler.commitOpen(1 - side, 17, entry);
                    otherId = handler.orders().nextId() - 1;
                }
            }
            uint64[] memory ownIds = handler.orders().accountIds(side);
            assertEq(ownIds.length, 5);
            assertEq(handler.orders().liveCount(), 6);
            assertLt(ownIds[1], otherId);
            assertGt(ownIds[2], otherId);
            bytes32 otherState = _pendingOrderState(otherId);
            uint256 ownBounties = handler.orders().bounty(side);
            uint256 treasuryBefore = handler.expectedTreasury();

            handler.liquidateAndReuse(side);

            assertEq(handler.liquidations(), 1);
            assertEq(handler.generations(side), 1);
            assertEq(handler.traderState(side).lots, 0);
            assertEq(handler.orders().count(side), 0);
            assertEq(handler.orders().liveCount(), 1);
            assertEq(handler.orders().head(), otherId);
            assertEq(handler.orders().tail(), otherId);
            assertEq(router.nextExecuteId(), otherId);
            assertEq(router.pendingOrderCounts(handler.actorAt(side)), 0);
            assertEq(router.pendingOrderCounts(handler.actorAt(1 - side)), 1);
            assertEq(handler.expectedTreasury(), treasuryBefore + ownBounties);
            assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), treasuryBefore + ownBounties);
            for (uint256 j; j < ownIds.length; ++j) {
                _assertLiquidatedQueuedOrder(ownIds[j], side);
            }
            assertEq(
                _pendingOrderState(otherId), otherState, "other account request, cash, locks and lifecycle survive"
            );

            handler.addCollateral(side, 100e6);
            handler.replayPending(ownIds[0] - 1, false);
            assertEq(handler.replayedOrders(), 1);
            assertEq(
                handler.traderState(side).cash, 100e6, "terminal replay cannot re-reserve the new generation's cash"
            );
            _assertLiquidatedQueuedOrder(ownIds[0], side);
            assertEq(handler.orders().liveCount(), 1);
            assertEq(handler.orders().head(), otherId);
            assertEq(_pendingOrderState(otherId), otherState);
            handler.assertModel();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function _pendingOrderState(
        uint64 id
    ) private view returns (bytes32) {
        PendingOrderReferenceLedger.Order memory order = handler.orders().order(id);
        return keccak256(
            abi.encode(
                order,
                router.lifecycleBook().pendingIntent(id),
                router.lifecycleBook().terminalOutcome(id),
                clearinghouse.getOrderReservation(id),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id),
                clearinghouse.balanceUsdc(handler.actorAt(order.actorIndex))
            )
        );
    }

    function _assertLiquidatedQueuedOrder(
        uint64 id,
        uint256 actor
    ) private view {
        PendingOrderReferenceLedger.Order memory queued = handler.orders().order(id);
        assertEq(queued.actorIndex, actor);
        assertEq(queued.originalMargin, 1020e6);
        assertEq(queued.remainingMargin, 0);
        assertEq(queued.remainingBounty, 0);
        assertEq(uint8(queued.marginStatus), uint8(PendingOrderReferenceLedger.MarginStatus.Released));
        assertEq(uint8(queued.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(queued.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
        OrderV3Types.TerminalOutcome memory outcome = router.lifecycleBook().terminalOutcome(id);
        assertEq(outcome.account, handler.actorAt(actor));
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
        assertTrue(queued.receiptHash != bytes32(0));
        assertEq(outcome.receiptHash, queued.receiptHash, "permanent receipt matches the authenticated liquidation log");
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(0));
        IMarginClearinghouse.OrderReservation memory margin = clearinghouse.getOrderReservation(id);
        assertEq(margin.remainingAmountUsdc, 0);
        assertEq(uint8(margin.status), uint8(PendingOrderReferenceLedger.MarginStatus.Released));
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(bounty.amountUsdc, 0);
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
    }

    function test_BothSidesPaidClaimLeavesStoredArrearsButRestoresProjectedHealth() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            handler.assertModel();
            handler.exerciseLiquidationHistory(side, 5);
            PerpMixedAccountingHandler.Trader memory trader = handler.traderState(side);
            CarryReferenceLedger.Account memory account = handler.carry().accountState(handler.actorAt(side));
            assertEq(trader.lots, 100);
            assertEq(trader.claim, 0, "old claim has been paid into live pledge");
            assertGt(trader.margin, 1500e6);
            assertGt(account.arrears, 0, "claim credit does not immediately recollect its new backing");
            assertEq(engine.unsettledCarryUsdc(handler.actorAt(side)), account.arrears);
            assertGt(
                trader.margin - account.arrears,
                side == 0 ? 120_000_002 : 80_000_002,
                "projected pledge remains above the fixed normal maintenance requirement"
            );
            assertEq(handler.settledClaims(), 1);
            assertEq(handler.healthyLiquidationRejections(), 1);
            assertEq(handler.liquidations(), 0);
            assertEq(handler.liquidationsBySide(0), 0);
            assertEq(handler.liquidationsBySide(1), 0);
            assertEq(handler.generations(side), 0);
            assertEq(handler.liquidationCarryWaived(), 0);
            assertFalse(handler.lastLiquidationValues().eligible);
            _assertCarryConservation();
            handler.assertModel();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesMaintenanceLossConsumesOnlyPartOfTheOldClaim() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory v = _runTerminal(side, 6);
            assertLt(v.pnl, 0);
            assertGt(v.claimConsumed, 0);
            assertGt(v.remainingClaim, 0);
            assertEq(v.claimConsumed, uint256(-v.pnl), "same-account claim covers the full price loss");
            assertEq(v.pledgeConsumed, 0);
            assertEq(v.writtenOff, 0);
            assertLe(v.equity, int256(v.maintenance), "price maintenance alone establishes eligibility");
            assertEq(v.carryWithheld, 0);
            assertEq(v.carryCash, 0);
            assertEq(v.carryWaived, 0);
            assertEq(v.fresh, 0);
            assertEq(handler.liquidationClaimsConsumed(), v.claimConsumed);
            assertEq(handler.liquidationPriceWrittenOff(), 0);
            assertEq(handler.liquidationCarryWaived(), 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_BothSidesSameAddressReusesTwoClaimBearingLiquidationGenerations() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snapshot = vm.snapshotState();
            LiquidationReferenceMath.Values memory first = _runTerminal(side, 2);
            uint256 firstClaim = first.remainingClaim;
            uint256 firstWithheld = handler.carry().accountState(handler.actorAt(side)).totalWithheld;
            _withdrawTerminalCash(side);
            handler.exerciseLiquidationHistory(side, 2);
            LiquidationReferenceMath.Values memory second = handler.lastLiquidationValues();
            assertEq(handler.liquidations(), 2);
            assertEq(handler.liquidationsBySide(side), 2);
            assertEq(handler.liquidationsBySide(1 - side), 0);
            assertEq(handler.generations(side), 2);
            assertEq(handler.claimBearingLiquidations(), 2);
            assertEq(handler.unpaidCarryLiquidations(), 2);
            assertEq(handler.positivePnlLiquidations(), 2);
            assertEq(handler.immediateLiquidationPayouts(), 2);
            assertEq(handler.deferredLiquidationPayouts(), 0);
            assertGt(second.remainingClaim, firstClaim + 1500e6, "second public close creates another old claim");
            assertGt(handler.carry().accountState(handler.actorAt(side)).totalWithheld, firstWithheld);
            assertEq(handler.traderState(side).lots, 0);
            assertEq(engine.unsettledCarryUsdc(handler.actorAt(side)), 0);
            assertEq(handler.liquidationCarryWaived(), 0);
            _withdrawTerminalCash(side);
            _assertCarryConservation();
            handler.assertModel();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_ModelRejectsOneAtomAddedToSurvivingOldClaim() public {
        LiquidationReferenceMath.Values memory v = _runTerminal(0, 2);
        assertGt(v.remainingClaim, 1500e6);
        _assertGetterFaultDetected(
            address(engine), abi.encodeCall(engine.traderClaimBalanceUsdc, (handler.actorAt(0))), v.remainingClaim + 1
        );
    }

    function test_ModelRejectsOneAtomOfCarryRestoredAfterTerminalLiquidation() public {
        _runTerminal(1, 0);
        assertEq(handler.carry().accountState(handler.actorAt(1)).arrears, 0);
        _assertGetterFaultDetected(address(engine), abi.encodeCall(engine.unsettledCarryUsdc, (handler.actorAt(1))), 1);
    }

    function test_ModelRejectsOneAtomAddedToRetainedTraderCash() public {
        LiquidationReferenceMath.Values memory v = _runTerminal(1, 2);
        assertGt(v.retainedCash, 0);
        _assertGetterFaultDetected(
            address(clearinghouse), abi.encodeCall(clearinghouse.balanceUsdc, (handler.actorAt(1))), v.retainedCash + 1
        );
    }

    function test_ModelRejectsOneAtomOfExtraKeeperCredit() public {
        LiquidationReferenceMath.Values memory v = _runTerminal(0, 2);
        assertGt(v.keeper, 0);
        _assertGetterFaultDetected(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.balanceUsdc, (handler.KEEPER())),
            handler.expectedKeeper() + 1
        );
    }

    function _runTerminal(
        uint256 actor,
        uint8 scenario
    ) private returns (LiquidationReferenceMath.Values memory v) {
        handler.assertModel();
        handler.exerciseLiquidationHistory(actor, scenario);
        v = handler.lastLiquidationValues();
        PerpMixedAccountingHandler.Trader memory trader = handler.traderState(actor);
        CarryReferenceLedger.Account memory account = handler.carry().accountState(handler.actorAt(actor));
        assertTrue(v.eligible);
        assertEq(handler.liquidations(), 1);
        assertEq(handler.liquidationsBySide(actor % 2), 1);
        assertEq(handler.liquidationsBySide(1 - actor % 2), 0);
        assertEq(handler.generations(actor), 1);
        assertEq(handler.claimBearingLiquidations(), 1);
        assertEq(handler.unpaidCarryLiquidations(), scenario == 6 ? 0 : 1);
        assertEq(handler.healthyLiquidationRejections(), 0);
        assertEq(handler.arrearsEpisodes(), scenario == 6 ? 0 : 1);
        assertGt(handler.deferredClaims(), 0, "old claims originate from an executed public close");
        assertEq(trader.lots, 0);
        assertEq(trader.margin, 0);
        assertEq(trader.basis, 0);
        assertEq(trader.vpi, 0);
        assertEq(trader.liquidationReserve, 0);
        assertEq(trader.cash, v.retainedCash);
        assertEq(trader.claim, v.remainingClaim);
        assertEq(handler.expectedClaims(), v.allClaimsAfter);
        assertEq(account.arrears, 0);
        assertFalse(account.active);
        assertEq(account.totalWithheld, v.carryWithheld);
        assertEq(account.totalWaived, v.carryWaived);
        assertEq(engine.unsettledCarryUsdc(handler.actorAt(actor)), 0);
        assertEq(v.charge, v.keeper + v.lpFee);
        assertEq(v.fresh, v.immediate + v.deferred);
        _assertCarryConservation();
        handler.assertModel();
    }

    function _assertProfitableCarrySettlement(
        LiquidationReferenceMath.Values memory v
    ) private view {
        assertEq(v.pnl, int256(2000e6));
        assertGt(v.equity, int256(v.maintenance), "positive price health does not excuse uncovered carry");
        assertEq(v.claimConsumed, 0);
        assertGt(v.remainingClaim, 1500e6);
        assertGt(v.carryWithheld, 0);
        assertEq(v.carryWaived, 0);
        assertGt(v.fresh, 0);
        assertEq(v.gain, v.vpiWithheld + v.carryWithheld + v.fresh);
        assertEq(handler.positivePnlLiquidations(), 1);
        assertEq(handler.liquidationClaimsConsumed(), 0);
        assertEq(handler.liquidationCarryWaived(), 0);
    }

    function _assertCarryConservation() private view {
        CarryReferenceLedger ledger = handler.carry();
        uint256 arrears;
        for (uint256 i; i < 4; ++i) {
            CarryReferenceLedger.Account memory account = ledger.accountState(handler.actorAt(i));
            assertEq(
                account.totalNewCarry,
                account.totalCollected + account.totalWaived + account.arrears,
                "account carry is recovered, retained, or waived exactly once"
            );
            arrears += account.arrears;
        }
        assertGt(ledger.totalNewCarry(), 0);
        assertEq(ledger.totalNewCarry(), ledger.totalCollected() + ledger.totalWaived() + arrears);
        assertEq(handler.carryCollected(), ledger.totalCollected());
        assertEq(handler.liquidationCarryWaived(), ledger.totalWaived());
    }

    function _withdrawTerminalCash(
        uint256 actor
    ) private {
        PerpMixedAccountingHandler.Trader memory before = handler.traderState(actor);
        assertEq(before.lots, 0);
        assertGt(before.cash, 0);
        handler.withdrawFreeCollateral(actor, before.cash);
        PerpMixedAccountingHandler.Trader memory afterWithdrawal = handler.traderState(actor);
        assertEq(afterWithdrawal.cash, 0);
        assertEq(afterWithdrawal.wallet, before.wallet + before.cash);
        assertEq(afterWithdrawal.claim, before.claim, "withdrawing physical residual does not spend claims");
        handler.assertModel();
    }

    function _assertGetterFaultDetected(
        address target,
        bytes memory callData,
        uint256 incorrectValue
    ) private {
        handler.assertModel();
        vm.mockCall(target, callData, abi.encode(incorrectValue));
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

}
