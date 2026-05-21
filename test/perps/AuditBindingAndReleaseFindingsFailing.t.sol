// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditBindingAndReleaseFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_H1_ExecutionReleaseMustNotUnlockConsumedCommittedMargin() public {
        address aliceAccount = alice;

        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 350_000e18, 35_000e6, 1e8, false);

        vm.prank(address(engine));
        clearinghouse.consumeAccountOrderReservations(aliceAccount, 35_000e6);

        vm.prank(address(engine));
        router.syncMarginQueue(aliceAccount);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        assertEq(
            _remainingCommittedMargin(1), 0, "Consumed committed margin should be charged to the queued order itself"
        );

        uint256 keeperBalanceBefore = clearinghouse.balanceUsdc(address(this));

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        vm.prank(address(this));
        router.executeOrder(1, empty);

        assertEq(_remainingCommittedMargin(1), 0, "Consumed committed margin must remain consumed");
        assertEq(
            clearinghouse.lockedMarginUsdc(aliceAccount),
            0,
            "Only the reserved execution bounty should be released on the failed execution"
        );
        assertEq(
            clearinghouse.balanceUsdc(address(this)) - keeperBalanceBefore,
            200_000,
            "Failed execution should pay the reserved bounty to the clearer"
        );
    }

    function test_H2_BindingInvalidOpenOrderClearsQueueWithoutExecutorReward() public {
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        uint256 keeperBefore = usdc.balanceOf(address(this));

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            router.nextExecuteId(), 0, "Clearing the invalid binding head should drain the queue to the zero sentinel"
        );
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            0,
            "Clearing a failed binding head should not compensate the clearer under the current open-order failure policy"
        );
    }

}
