// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

contract ClearinghouseReservationOwnershipTest is BasePerpTest {

    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);

    function _lockActionReserve(
        uint256 amount
    ) internal {
        _fundTrader(ACCOUNT, amount);
        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(ACCOUNT, amount);
    }

    function _record(
        IMarginClearinghouse.BountyKind kind,
        uint64 id,
        uint256 amount
    ) internal {
        vm.prank(
            kind == IMarginClearinghouse.BountyKind.Order ? address(router) : address(router.positionProtectionBook())
        );
        clearinghouse.recordBountyReservation(ACCOUNT, kind, id, amount);
    }

    function test_BountyReservationRequiresBackingAndItsNamespaceOwner() public {
        address book = address(router.positionProtectionBook());
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ActionReserveMismatch.selector);
        vm.prank(address(router));
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1, 1e6);

        _lockActionReserve(3e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        vm.prank(ACCOUNT);
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1, 1e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        vm.prank(address(router));
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, 1e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        vm.prank(book);
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1, 1e6);

        _record(IMarginClearinghouse.BountyKind.Order, 1, 3e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidBountyReservation.selector);
        vm.prank(address(router));
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1, 1e6);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 3e6);
    }

    function test_BountyReservationCannotBeTakenForAnotherAccountOrTwice() public {
        _lockActionReserve(3e6);
        _record(IMarginClearinghouse.BountyKind.Order, 1, 3e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginClearinghouse.MarginClearinghouse__ReservationAccountMismatch.selector, uint64(1), OTHER, ACCOUNT
            )
        );
        vm.prank(address(router));
        clearinghouse.takeBountyReservation(OTHER, IMarginClearinghouse.BountyKind.Order, 1);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        vm.prank(ACCOUNT);
        clearinghouse.takeBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1);

        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        vm.startPrank(address(router));
        assertEq(clearinghouse.takeBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1), 3e6);
        assertEq(clearinghouse.takeBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1), 0);
        clearinghouse.releaseReservedExecutionBountyToSource(ACCOUNT, 3e6);
        vm.stopPrank();
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balance, "self-refund changes no custody");
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc, 0);
    }

    function test_ProtectionRetryReattributesOneReserveWithoutUnlockingOrRelocking() public {
        _lockActionReserve(6e6);
        _record(IMarginClearinghouse.BountyKind.Order, 1, 1e6);
        _record(IMarginClearinghouse.BountyKind.ProtectionTrigger, 1, 2e6);
        _record(IMarginClearinghouse.BountyKind.ProtectionExecution, 1, 3e6);
        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        vm.startPrank(address(router.positionProtectionBook()));
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 2
        );
        assertEq(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, 2).amountUsdc, 3e6);
        assertEq(
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionExecution, 1).amountUsdc, 0
        );
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.Order, 2, IMarginClearinghouse.BountyKind.ProtectionExecution, 1
        );
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidBountyReservation.selector);
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 2
        );
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 3
        );
        vm.stopPrank();
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 6e6);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc, 6e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balance);
        assertEq(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, 1).amountUsdc, 1e6);
        assertEq(
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionTrigger, 1).amountUsdc, 2e6
        );
    }

    function test_BountyTransferRejectsWrongOwnerNamespaceAccountAndLiveDestination() public {
        _lockActionReserve(6e6);
        _record(IMarginClearinghouse.BountyKind.Order, 1, 1e6);
        _record(IMarginClearinghouse.BountyKind.ProtectionTrigger, 1, 2e6);
        _record(IMarginClearinghouse.BountyKind.ProtectionExecution, 1, 3e6);
        address book = address(router.positionProtectionBook());
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        vm.prank(address(router));
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 2
        );
        vm.startPrank(book);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidBountyReservation.selector);
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionTrigger, 1, IMarginClearinghouse.BountyKind.Order, 2
        );
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidBountyReservation.selector);
        clearinghouse.moveBountyReservation(
            OTHER, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 2
        );
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidBountyReservation.selector);
        clearinghouse.moveBountyReservation(
            ACCOUNT, IMarginClearinghouse.BountyKind.ProtectionExecution, 1, IMarginClearinghouse.BountyKind.Order, 1
        );
        vm.stopPrank();
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 6e6);
        assertEq(clearinghouse.totalBountyReservationsUsdc(OTHER), 0);
        assertEq(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, 1).amountUsdc, 1e6);
        assertEq(
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionExecution, 1).amountUsdc, 3e6
        );
    }

    function test_ReservationFloorsAndFifoConsumptionDoNotReadRouterAccounting() public {
        _lockActionReserve(3e6);
        _record(IMarginClearinghouse.BountyKind.Order, 1, 3e6);
        _fundTrader(ACCOUNT, 10e6);
        vm.prank(address(router));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 1, 10e6);
        vm.mockCallRevert(
            address(router), abi.encodeWithSignature("getAccountReservations(address)", ACCOUNT), "no router accounting"
        );
        vm.mockCallRevert(
            address(router), abi.encodeWithSignature("getMarginReservationIds(address)", ACCOUNT), "no router index"
        );

        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 3e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ActionReserveMismatch.selector);
        vm.prank(address(engine));
        clearinghouse.unlockReservedSettlement(ACCOUNT, 1);
        vm.prank(address(engine));
        assertEq(clearinghouse.consumeAccountOrderReservations(ACCOUNT, 10e6), 10e6);
        assertEq(clearinghouse.getMarginReservationIds(ACCOUNT).length, 0);
        assertEq(clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc, 3e6);
    }

    function test_MarginReservationsUnlinkMiddleHeadAndTailAtomically() public {
        _fundTrader(ACCOUNT, 60e6);
        vm.startPrank(address(router));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 1, 10e6);
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 2, 20e6);
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 3, 30e6);
        clearinghouse.releaseOrderReservationForTerminalCleanup(2);
        vm.stopPrank();
        uint64[] memory ids = clearinghouse.getMarginReservationIds(ACCOUNT);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
        assertEq(clearinghouse.getOrderReservation(1).nextOrderId, 3);
        assertEq(clearinghouse.getOrderReservation(3).previousOrderId, 1);
        vm.prank(address(engine));
        assertEq(clearinghouse.consumeAccountOrderReservations(ACCOUNT, 15e6), 15e6);
        assertEq(clearinghouse.marginReservationHead(ACCOUNT), 3);
        assertEq(clearinghouse.marginReservationTail(ACCOUNT), 3);
        assertEq(clearinghouse.getOrderReservation(3).remainingAmountUsdc, 25e6);
        assertEq(clearinghouse.getOrderReservation(3).previousOrderId, 0);
        vm.prank(address(router));
        clearinghouse.releaseOrderReservationForTerminalCleanup(3);
        assertEq(clearinghouse.marginReservationHead(ACCOUNT), 0);
        assertEq(clearinghouse.marginReservationTail(ACCOUNT), 0);
        assertEq(clearinghouse.getAccountReservationSummary(ACCOUNT).activeReservationCount, 0);
        assertEq(clearinghouse.getAccountReservationSummary(ACCOUNT).activeCommittedOrderMarginUsdc, 0);
    }

}
