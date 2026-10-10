// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/PRE_AUDIT_GUIDE.md#failure-policy-table

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract CarryAndMarginCheckpointGasTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#failure-policy-table.
    function test_LowGasBudgetPreservesEligibleOrderAndCustody() public {
        _fundTrader(alice, 50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory priceData = _mockPythUpdateData();
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 traderBefore = clearinghouse.balanceUsdc(alice);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        uint256 reservedBefore = clearinghouse.lockedMarginUsdc(alice);
        uint256 snapshot = vm.snapshotState();

        // The exact same eligible state must execute when gas is sufficient.
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory success = router.executeOrder(1, priceData);
        assertEq(uint8(success.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertTrue(vm.revertToState(snapshot));

        vm.prank(keeper);
        (bool ok, bytes memory result) = address(router).call{gas: 520_000}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );
        if (!ok && result.length != 0) {
            assertEq(bytes4(result), IOrderRouterErrors.OrderRouter__InsufficientGas.selector);
        }
        if (ok) {
            OrderV3Types.ExecutionResult memory blocked = abi.decode(result, (OrderV3Types.ExecutionResult));
            assertEq(uint8(blocked.status), uint8(OrderV3Types.LifecycleStatus.Pending));
            assertEq(uint8(blocked.pendingReason), uint8(OrderV3Types.PendingReason.InsufficientGas));
        }
        assertEq(router.nextExecuteId(), 1, "Low gas must preserve the eligible FIFO head");
        assertEq(clearinghouse.balanceUsdc(alice), traderBefore, "Low gas must preserve trader settlement");
        assertEq(clearinghouse.balanceUsdc(keeper), keeperBefore, "Low gas must not pay a bounty");
        assertEq(clearinghouse.lockedMarginUsdc(alice), reservedBefore, "Low gas must preserve reservations");
        (IOrderRouterAccounting.PendingOrderView memory afterAttempt,) = router.getPendingOrderView(1);
        assertEq(afterAttempt.executionBountyUsdc, pending.executionBountyUsdc);
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0, "Low gas must not partially apply the open");
    }

}

contract ExecutionGasFloorTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#failure-policy-table.
    function test_ExecutionGasBudgetFloorPreservesEligibleOrderAndCustody() public {
        _fundTrader(alice, 50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory priceData = _mockPythUpdateData();
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 traderBefore = clearinghouse.balanceUsdc(alice);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        uint256 reservedBefore = clearinghouse.lockedMarginUsdc(alice);
        uint256 snapshot = vm.snapshotState();

        // The exact same eligible state must execute when gas is sufficient.
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory success = router.executeOrder(1, priceData);
        assertEq(uint8(success.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertTrue(vm.revertToState(snapshot));

        vm.prank(keeper);
        (bool ok, bytes memory result) = address(router).call{gas: 450_000}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );
        if (!ok && result.length != 0) {
            assertEq(bytes4(result), IOrderRouterErrors.OrderRouter__InsufficientGas.selector);
        }
        if (ok) {
            OrderV3Types.ExecutionResult memory blocked = abi.decode(result, (OrderV3Types.ExecutionResult));
            assertEq(uint8(blocked.status), uint8(OrderV3Types.LifecycleStatus.Pending));
            assertEq(uint8(blocked.pendingReason), uint8(OrderV3Types.PendingReason.InsufficientGas));
        }
        assertEq(router.nextExecuteId(), 1, "Low gas must preserve the eligible FIFO head");
        assertEq(clearinghouse.balanceUsdc(alice), traderBefore, "Low gas must preserve trader settlement");
        assertEq(clearinghouse.balanceUsdc(keeper), keeperBefore, "Low gas must not pay a bounty");
        assertEq(clearinghouse.lockedMarginUsdc(alice), reservedBefore, "Low gas must preserve reservations");
        (IOrderRouterAccounting.PendingOrderView memory afterAttempt,) = router.getPendingOrderView(1);
        assertEq(afterAttempt.executionBountyUsdc, pending.executionBountyUsdc);
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0, "Low gas must not partially apply the open");
    }

}
