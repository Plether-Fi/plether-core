// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @notice Regression coverage for single-target execution after bounded pre-oracle head cleanup.
contract OrderRouterV2SingleHeadProgressTest is BasePerpTest {

    address internal constant EXPIRED_TRADER = address(0xE7A1);
    address internal constant TARGET_TRADER = address(0x7A26E7);
    address internal constant KEEPER = address(0xBEEF);
    uint256 internal constant MARK_PRICE = 1e8;

    function test_SingleTargetExecutesAfterEarlierTerminalHeadCleanup() public {
        _fundTrader(EXPIRED_TRADER, 2000e6);
        _fundTrader(TARGET_TRADER, 2000e6);

        uint64 expiredOrderId = router.nextCommitId();
        vm.prank(EXPIRED_TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, MARK_PRICE, false);

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        uint64 targetOrderId = router.nextCommitId();
        vm.prank(TARGET_TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, MARK_PRICE, false);

        uint256 pythUpdatesBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 uniqueParsesBefore = baseMockPyth.parseUniqueCallCount();
        bytes[] memory updateData = _freshTargetUpdateData();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(targetOrderId, updateData);

        assertEq(result.orderId, targetOrderId, "the return value must describe the requested target");
        assertEq(
            uint256(result.status),
            uint256(OrderV2Types.LifecycleStatus.Executed),
            "the target must execute in the cleanup call"
        );
        assertEq(
            uint256(result.terminalReason),
            uint256(OrderV2Types.TerminalReason.Executed),
            "the target result must retain its execution classification"
        );

        OrderV2Types.CompactOutcome memory expiredOutcome = router.lifecycleBook().outcome(expiredOrderId);
        assertEq(
            uint256(expiredOutcome.status),
            uint256(OrderV2Types.LifecycleStatus.Failed),
            "the earlier head must be terminally cleaned"
        );
        assertEq(
            uint256(expiredOutcome.reason),
            uint256(OrderV2Types.TerminalReason.Expired),
            "the earlier head must retain its pre-oracle expiry reason"
        );
        assertEq(expiredOutcome.executor, KEEPER, "the cleanup receipt must retain the external keeper");

        OrderV2Types.CompactOutcome memory targetOutcome = router.lifecycleBook().outcome(targetOrderId);
        assertEq(
            uint256(targetOutcome.status),
            uint256(OrderV2Types.LifecycleStatus.Executed),
            "the target Book outcome must be terminal"
        );
        assertEq(targetOutcome.executor, KEEPER, "the target receipt must retain the same external keeper");
        assertEq(router.nextExecuteId(), 0, "one call must consume both queue heads");
        assertEq(_positionSize(EXPIRED_TRADER), 0, "the expired order must never reach the Engine");
        assertEq(_positionSize(TARGET_TRADER), 10_000e18, "the new head must reach the Engine in the same call");
        assertEq(
            baseMockPyth.parseUniqueCallCount() - uniqueParsesBefore,
            1,
            "only the target may perform historical oracle work"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(),
            pythUpdatesBefore,
            "live historical execution must not perform a normal Pyth update"
        );
    }

    function _freshTargetUpdateData() internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(MARK_PRICE)), 0, int32(-8), block.timestamp, block.timestamp - 1
        );
        updateData = new bytes[](1);
        updateData[0] = abi.encode(MARK_PRICE);
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

}
