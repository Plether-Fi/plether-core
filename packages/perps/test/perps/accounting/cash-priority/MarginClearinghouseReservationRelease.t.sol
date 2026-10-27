// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

contract ReservationReleaseEngineMock {

    address public orderRouter;
    uint256 public carryCheckpointCalls;

    function setOrderRouter(
        address router
    ) external {
        orderRouter = router;
    }

    function realizeCarryBeforeMarginChange(
        address
    ) external {
        carryCheckpointCalls += 1;
    }

}

contract MarginClearinghouseReservationReleaseTest is Test {

    MarginClearinghouse internal clearinghouse;
    MockSettlementToken internal settlementToken;
    ReservationReleaseEngineMock internal engine;

    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant ROUTER = address(0xB0A7);
    address internal constant STRANGER = address(0xCA11);

    function setUp() public {
        settlementToken = new MockSettlementToken();
        engine = new ReservationReleaseEngineMock();
        engine.setOrderRouter(ROUTER);

        clearinghouse = new MarginClearinghouse(address(settlementToken));
        clearinghouse.setEngine(address(engine));

        settlementToken.mint(ACCOUNT, 1000e6);
        vm.startPrank(ACCOUNT);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(ACCOUNT, 1000e6);
        vm.stopPrank();
    }

    function test_TerminalCleanup_SkipsCarryAndReconcilesReservationAccounting() public {
        _reserve(3, 210e6);
        uint256 carryCallsBefore = engine.carryCheckpointCalls();
        uint256 settlementBefore = clearinghouse.balanceAssets(ACCOUNT);

        vm.prank(ROUTER);
        uint256 releasedAssets = clearinghouse.releaseOrderReservationForTerminalCleanup(3);

        _assertReleased(3, 210e6);
        assertEq(releasedAssets, 210e6);
        assertEq(engine.carryCheckpointCalls(), carryCallsBefore, "terminal release must not checkpoint carry");
        assertEq(clearinghouse.balanceAssets(ACCOUNT), settlementBefore, "release must not debit settlement");
    }

    function test_TerminalCleanup_IsRouterOnlyAndIdempotentForInactiveReservations() public {
        _reserve(4, 90e6);

        vm.prank(address(engine));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.releaseOrderReservationForTerminalCleanup(4);

        vm.prank(STRANGER);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.releaseOrderReservationForTerminalCleanup(4);

        vm.prank(ROUTER);
        assertEq(clearinghouse.releaseOrderReservationForTerminalCleanup(4), 90e6);

        uint256 carryCallsBefore = engine.carryCheckpointCalls();
        vm.startPrank(ROUTER);
        assertEq(clearinghouse.releaseOrderReservationForTerminalCleanup(4), 0);
        assertEq(clearinghouse.releaseOrderReservationForTerminalCleanup(404), 0);
        vm.stopPrank();

        _assertReleased(4, 90e6);
        assertEq(engine.carryCheckpointCalls(), carryCallsBefore, "inactive cleanup must not checkpoint carry");
    }

    function _reserve(
        uint64 orderId,
        uint256 amountAssets
    ) internal {
        vm.prank(address(engine));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, orderId, amountAssets);
    }

    function _assertReleased(
        uint64 orderId,
        uint256 originalAmountAssets
    ) internal view {
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderId);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(ACCOUNT);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(ACCOUNT);

        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.originalAmountAssets, originalAmountAssets);
        assertEq(reservation.remainingAmountAssets, 0);
        assertEq(buckets.committedOrderMarginAssets, 0);
        assertEq(summary.activeCommittedOrderMarginAssets, 0);
        assertEq(summary.activeReservationCount, 0);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(ACCOUNT), clearinghouse.balanceAssets(ACCOUNT));
    }

}
