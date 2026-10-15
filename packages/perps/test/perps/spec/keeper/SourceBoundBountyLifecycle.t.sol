// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @dev Historical suite path retained; source-bound funding is replaced by explicit unpaid close records.
contract SourceBoundBountyLifecycleTest is SourceBoundBountyFixture {

    function test_ZeroBountyReservationRejectsMissingForeignSettledAndDuplicateRecords() public {
        _bountyPosition(CfdTypes.Side.LONG);
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        router.lifecycleBook().validateBountyFunding(id);
        assertEq(_bountyReservation(id).account, BOUNTY_TRADER);
        assertEq(uint8(_bountyReservation(id).state), uint8(IMarginClearinghouse.BountyReservationState.Active));
        assertEq(_bountyReservation(id).amountUsdc, 0);
        vm.expectRevert(bytes4(keccak256("MarginClearinghouse__InvalidBountyReservation()")));
        clearinghouse.validateBountyReservation(BOUNTY_OTHER, IMarginClearinghouse.BountyKind.Order, id, 0);
        vm.expectRevert(bytes4(keccak256("MarginClearinghouse__InvalidBountyReservation()")));
        clearinghouse.validateBountyReservation(BOUNTY_TRADER, IMarginClearinghouse.BountyKind.Order, id + 1, 0);
        vm.expectRevert(bytes4(keccak256("MarginClearinghouse__InvalidBountyReservation()")));
        vm.prank(address(router));
        clearinghouse.recordBountyReservation(BOUNTY_TRADER, IMarginClearinghouse.BountyKind.Order, id, 0);
        _assertUnpaid(_bountyExpire(id, BOUNTY_KEEPER));
        _assertBountyResolved(id);
        vm.expectRevert(bytes4(keccak256("MarginClearinghouse__InvalidBountyReservation()")));
        clearinghouse.validateBountyReservation(BOUNTY_TRADER, IMarginClearinghouse.BountyKind.Order, id, 0);
    }

    function test_RemovedThreeArgumentCloseReservationSelectorRejectsWithoutBlockingPublicClose() public {
        _bountyPosition(CfdTypes.Side.SHORT);
        bytes32 beforeState = _bountyStateDigest(router.nextCommitId());
        // Zero would have been a valid bounty on the retired selector, so rejection proves its removal.
        bytes4 retiredSelector = bytes4(keccak256("reserveCloseOrderExecutionBounty(address,uint256,uint256)"));
        vm.prank(address(router));
        (bool accepted, bytes memory revertData) =
            address(engine).call(abi.encodeWithSelector(retiredSelector, BOUNTY_TRADER, BOUNTY_SIZE, 0));
        assertFalse(accepted, "retired close reservation selector must be unsupported");
        assertEq(revertData.length, 0, "unknown selector should revert without a protocol error");
        assertEq(_bountyStateDigest(router.nextCommitId()), beforeState);

        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        assertEq(_bountyReservation(id).amountUsdc, 0);
    }

    function testFuzz_UnpaidExpiryPreservesPledgeCashAndKeeper(
        bool shortSide,
        bool self,
        uint96 freeCash
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 pledge = _bountyPosition(side);
        uint256 free = bound(uint256(freeCash), 0, 1000e6);
        if (free != 0) {
            _fundTrader(BOUNTY_TRADER, free);
        }
        uint256 custody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        uint256 keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        uint64 id = _bountyCommit(BOUNTY_TRADER, side, true, BOUNTY_SIZE, 0);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        _assertUnpaid(_bountyExpire(id, self ? BOUNTY_TRADER : BOUNTY_KEEPER));
        _assertBountyResolved(id);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), custody);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeper);
    }

    function testFuzz_UnpaidSuccessBothSidesPartialFullAndSelf(
        bool shortSide,
        bool full,
        bool self
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _bountyPosition(side);
        uint256 keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        uint256 wallet = usdc.balanceOf(BOUNTY_TRADER);
        uint256 size = full ? BOUNTY_SIZE : BOUNTY_SIZE / 2;
        uint64 id = _bountyCommit(BOUNTY_TRADER, side, true, size, 0);
        _assertUnpaid(
            _bountyExecute(
                id, BOUNTY_PRICE, self ? BOUNTY_TRADER : BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed
            )
        );
        _assertBountyResolved(id);
        (uint256 remaining,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(remaining, BOUNTY_SIZE - size);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeper);
        assertEq(usdc.balanceOf(BOUNTY_TRADER), wallet, "no additional USDC deposited");
    }

    function test_PartialCloseQueueNeedsNoFreeCashOrBounty() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        uint64 first = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        uint64 second = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 2);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        assertEq(_bountyReservation(first).amountUsdc, 0);
        assertEq(_bountyReservation(second).amountUsdc, 0);
        _assertUnpaid(_bountyExecute(first, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed));
        _assertUnpaid(_bountyExecute(second, BOUNTY_PRICE, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed));
        _assertBountyResolved(first);
        _assertBountyResolved(second);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_NonGlobalHeadExpiryRemovesOnlyItsOwnLinks() public {
        _bountyPosition(CfdTypes.Side.LONG);
        _fundTrader(BOUNTY_OTHER, 1000e6);
        uint64 head = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.SHORT, false, BOUNTY_SIZE, 250e6);
        uint64 later = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        bytes32 reservation = keccak256(abi.encode(_bountyReservation(head)));
        _assertUnpaid(_bountyExpire(later, BOUNTY_KEEPER));
        assertEq(router.nextExecuteId(), head);
        assertEq(keccak256(abi.encode(_bountyReservation(head))), reservation);
        _assertBountyResolved(later);
        _bountyExpire(head, BOUNTY_KEEPER);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_RepeatedUnderwaterFailuresCannotDrainPositionOrCreditKeeper() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        uint256 keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        uint256 custody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 1);
            router.updateMarkPrice(_bountyPriceData(140_000_000));
            uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
            _assertUnpaid(_bountyExpire(id, BOUNTY_KEEPER));
            _assertBountyResolved(id);
        }
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), custody);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeper);
    }

    function test_PendingUnpaidCloseDoesNotChangeLiquidationLossRecovery() public {
        _bountyPosition(CfdTypes.Side.LONG);
        uint256 snapshot = vm.snapshotState();
        bytes[] memory data = _mockPythUpdateData(140_000_000);
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        uint256 controlPool = pool.totalAssets();
        uint256 controlTreasury = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 controlKeeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        assertTrue(vm.revertToState(snapshot));
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        data = _mockPythUpdateData(140_000_000);
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        _assertUnpaid(_bountyReceipt(id));
        _assertBountyResolved(id);
        assertEq(pool.totalAssets(), controlPool);
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), controlTreasury);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), controlKeeper);
    }

    function _assertUnpaid(
        OrderV3Types.OrderReceipt memory receipt
    ) private pure {
        assertEq(receipt.bountyUsdc, 0);
        assertEq(receipt.bounty.bountyPaidUsdc, 0);
        assertEq(receipt.bounty.bountyRefundedUsdc, 0);
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(receipt.bountyRecipient, address(0));
        assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None));
    }

}
