// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/PRE_AUDIT_GUIDE.md#order-lifecycle-state-machine

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract SuccessfulBatchExecutionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#order-lifecycle-state-machine.
    function test_ValidBatchExecutesWithSufficientGas() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        // Alice commits a valid order
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        uint64 orderId = router.nextCommitId() - 1;
        bytes[] memory priceData = _mockPythUpdateData();

        // This call does not constrain gas or inject a failure. It checks only the successful
        // batch path. The current router has execution-gas checks and leaves retryable

        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        router.executeOrderBatch{value: 0.01 ether}(orderId, priceData);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);

        // Confirm the sufficient-gas batch opened the position.
        assertGt(size, 0, "order executed with sufficient gas");
    }

}

contract FundedCommitLifetimeTest is BasePerpTest {

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#order-lifecycle-state-machine.
    function test_CommitOrderDoesNotRequireEth() public {
        _fundTrader(address(0xA11CE), 10_000e6);

        vm.prank(address(0xA11CE));
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 1000e6, 1e8, false);

        assertEq(router.nextCommitId(), 2, "Commit should succeed without sending ETH");
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#order-lifecycle-state-machine.
    function test_MaxExecutionWindowSecondsShouldBeNonZeroByDefault() public {
        // A nonzero default lifetime lets terminal cleanup expire abandoned queue entries.
        assertGt(router.maxExecutionWindowSeconds(), 0, "maxExecutionWindowSeconds should have a non-zero default");
    }

}
