// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditBindingAndReleaseFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_H1_ExecutionReleaseMustNotUnlockConsumedCommittedMargin() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _fundTrader(alice, 5000e6);
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 5000e18, 500e6, 1e8, false);

        vm.prank(address(engine));
        clearinghouse.consumeAccountOrderReservations(aliceId, 500e6);

        vm.prank(address(engine));
        router.syncMarginQueue(aliceId);

        assertEq(
            router.committedMargins(1), 0, "Consumed committed margin should be charged to the queued order itself"
        );

        uint256 lockedBeforeExecution = clearinghouse.lockedMarginUsdc(aliceId);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        vm.prank(address(this));
        router.executeOrder(1, empty);

        assertEq(
            clearinghouse.lockedMarginUsdc(aliceId),
            lockedBeforeExecution,
            "Execution release must not unlock consumed committed margin when the open order later reverts"
        );
    }

    function test_H2_BindingInvalidOpenOrderCanJamQueueWithoutExecutorReward() public {
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperBefore = usdc.balanceOf(address(this));

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertGt(router.nextExecuteId(), 1, "Someone must clear the invalid binding head for queue liveness");
        assertGt(
            usdc.balanceOf(address(this)) - keeperBefore,
            0,
            "Clearing a failed binding head should still compensate the clearer"
        );
    }

}
