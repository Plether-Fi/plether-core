// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Public V3 setup, exact receipt authentication and independent fixed-price controls.
///      Carry/VPI are zero here. Close requests have unpaid zero-value bounty records;
///      opening orders retain their ordinary funded bounties.
abstract contract SourceBoundBountyFixture is BasePerpTest {

    address internal constant BOUNTY_TRADER = address(0xB0171);
    address internal constant BOUNTY_KEEPER = address(0xB0172);
    address internal constant BOUNTY_OTHER = address(0xB0173);
    uint256 internal constant BOUNTY_SIZE = 10_000e18;
    uint256 internal constant BOUNTY_PRICE = 100_000_000;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory p) {
        p = super._riskParams();
        p.baseCarryBps = 0;
        p.vpiFactor = 0;
        p.maxSkewRatio = 1e18;
    }

    function _bountyRequest(
        CfdTypes.Side side,
        bool close,
        uint256 size,
        uint256 margin
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("source-bound-bounty", router.nextCommitId()));
        request.side = side;
        request.sizeDelta = size;
        request.marginDelta = margin;
        request.isClose = close;
        request.targetPrice = (side == CfdTypes.Side.LONG) == close ? 2e8 : 1;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + 60),
            executionWindowSeconds: 60,
            allowedExecutionModes: 7,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _bountyCommit(
        address account,
        CfdTypes.Side side,
        bool close,
        uint256 size,
        uint256 margin
    ) internal returns (uint64 id) {
        OrderV3Types.OrderRequest memory request = _bountyRequest(side, close, size, margin);
        vm.prank(account);
        id = router.commitOrder(request);
    }

    function _bountyReceipt(
        uint64 id
    ) internal returns (OrderV3Types.OrderReceipt memory receipt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && uint256(logs[i].topics[1]) == id
            ) {
                (bytes32 hash,, uint64 time, OrderV3Types.OrderReceipt memory found) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertEq(found.orderId, id);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), found.account);
                assertEq(logs[i].topics[3], found.clientOrderId);
                assertEq(router.lifecycleBook().terminalOutcome(id).receiptHash, hash);
                assertTrue(router.lifecycleBook().verifyReceipt(found, time), "receipt must authenticate");
                receipt = found;
                ++matches;
            }
        }
        assertEq(matches, 1, "exactly one authenticated terminal receipt");
    }

    function _bountyExecute(
        uint64 id,
        uint256 price,
        address executor,
        OrderV3Types.LifecycleStatus status
    ) internal returns (OrderV3Types.OrderReceipt memory receipt) {
        bytes[] memory data = _mockPythUpdateData(price);
        vm.recordLogs();
        vm.prank(executor);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, data);
        assertEq(uint8(result.status), uint8(status), "required public execution outcome");
        receipt = _bountyReceipt(id);
        assertEq(uint8(receipt.status), uint8(status));
        assertEq(receipt.executor, executor);
    }

    function _bountyExpire(
        uint64 id,
        address executor
    ) internal returns (OrderV3Types.OrderReceipt memory receipt) {
        uint256 deadline = router.lifecycleBook().orderTiming(id).executionDeadline;
        if (block.timestamp <= deadline) {
            vm.warp(deadline + 1);
        }
        vm.recordLogs();
        vm.prank(executor);
        router.expireOrder(id);
        receipt = _bountyReceipt(id);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Expired));
    }

    function _bountyPosition(
        CfdTypes.Side side
    ) internal returns (uint256 pledge) {
        _fundTrader(BOUNTY_TRADER, 1000e6);
        uint64 opening = _bountyCommit(BOUNTY_TRADER, side, false, BOUNTY_SIZE, 250e6);
        _bountyExecute(opening, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        uint256 free = clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER);
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdraw(BOUNTY_TRADER, free);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, BOUNTY_SIZE);
        assertEq(engine.positionEpoch(BOUNTY_TRADER), 1);
        pledge = clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER);
    }

    function _bountyReservation(
        uint64 id
    ) internal view returns (IMarginClearinghouse.BountyReservation memory) {
        return clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
    }

    function _assertBountyResolved(
        uint64 id
    ) internal view {
        IMarginClearinghouse.BountyReservation memory reservation = _bountyReservation(id);
        assertEq(reservation.amountUsdc, 0, "terminal bounty custody attribution cleared");
        assertEq(uint8(reservation.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
        (IOrderRouterAccounting.PendingOrderView memory order, uint64 next) = router.getPendingOrderView(id);
        assertEq(order.sizeDelta, 0, "terminal queue record removed");
        assertEq(next, 0);
    }

    function _bountyPriceData(
        uint256 price
    ) internal returns (bytes[] memory data) {
        uint256 publishTime = vm.getBlockTimestamp();
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), 0, -8, publishTime);
        baseMockPyth.setAllUniquePrices(_basePythFeedIds(), int64(uint64(price)), 0, -8, publishTime, publishTime - 1);
        data = new bytes[](1);
        data[0] = "";
    }

    function _bountyStateDigest(
        uint64 id
    ) internal view returns (bytes32) {
        (IOrderRouterAccounting.PendingOrderView memory pending, uint64 next) = router.getPendingOrderView(id);
        bytes32 custody = keccak256(
            abi.encode(
                clearinghouse.balanceUsdc(BOUNTY_TRADER),
                clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER),
                clearinghouse.actionReserveUsdc(BOUNTY_TRADER),
                _bountyReservation(id),
                engine.positionEpoch(BOUNTY_TRADER)
            )
        );
        return keccak256(
            abi.encode(
                custody,
                pending,
                next,
                router.pendingOrderCounts(BOUNTY_TRADER),
                router.accountHeadOrderId(BOUNTY_TRADER),
                router.nextExecuteId(),
                router.nextCommitId(),
                router.lifecycleBook().pendingIntent(id)
            )
        );
    }

}
