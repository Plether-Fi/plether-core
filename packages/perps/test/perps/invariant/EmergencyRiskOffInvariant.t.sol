// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

/// @notice Cross-component, bounded state-machine coverage for persistent risk-off containment.
/// @dev These tests intentionally exercise the production Router, Admin, Clearinghouse, HousePool, and coordinator
///      together. Randomized order counts, cleanup order, sides, and pause histories cover properties that isolated
///      unit tests cannot establish: cutoff monotonicity, permanent invalidation, exact lock conservation, and
///      continued risk-reducing operation.
contract EmergencyRiskOffInvariantTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant GUARDIAN = address(0xCAFE);
    address internal constant EXECUTOR = address(0xE0EC);
    address internal constant OUTSIDER = address(0xBAD);

    bytes32 internal constant REASON_HASH = keccak256("risk-off-invariant");
    bytes32 internal constant EVIDENCE_HASH = keccak256("risk-off-invariant-evidence");

    EmergencyPauseCoordinator internal coordinator;

    function setUp() public override {
        super.setUp();

        coordinator = new EmergencyPauseCoordinator(address(routerAdmin), address(pool), address(this));
        coordinator.setGuardian(GUARDIAN);
        routerAdmin.setPauser(address(coordinator));
        pool.setPauser(address(coordinator));

        _fundTrader(ALICE, 250_000e6);
        _fundTrader(BOB, 250_000e6);
    }

    /// @notice Any sequence of successful pause cycles may only extend the inclusive invalidation boundary.
    function testFuzz_RiskOffCutoffIsMonotonicAcrossPauseCycles(
        uint8 firstCountSeed,
        uint8 secondCountSeed
    ) public {
        uint256 firstCount = bound(uint256(firstCountSeed), 1, 5);
        uint256 secondCount = bound(uint256(secondCountSeed), 1, 5);

        _commitOpens(ALICE, firstCount);
        uint64 firstCutoff = _triggerRiskOff();

        assertEq(firstCutoff, firstCount);
        assertEq(routerAdmin.riskOffOrderCutoff(), firstCutoff);
        assertEq(_triggerRiskOff(), firstCutoff, "idempotent containment must not move the cutoff backward");

        _recoverFromRiskOff();
        _commitOpens(BOB, secondCount);
        assertEq(
            routerAdmin.riskOffOrderCutoff(), firstCutoff, "unpause and later commits must not mutate historical cutoff"
        );

        uint64 secondCutoff = _triggerRiskOff();
        assertEq(secondCutoff, firstCount + secondCount);
        assertGe(secondCutoff, firstCutoff);

        _recoverFromRiskOff();
        assertEq(routerAdmin.riskOffOrderCutoff(), secondCutoff, "recovery must never revive invalidated ids");
        assertEq(_triggerRiskOff(), secondCutoff, "an empty-tail reaffirmation must preserve the maximum cutoff");
    }

    /// @notice Random non-head cleanup must exactly reverse all trader locks without rewarding the cleanup caller.
    function testFuzz_RiskOffRefundConservesQueueReservationsAndBounties(
        uint8 orderCountSeed,
        uint256 permutationSeed
    ) public {
        uint256 orderCount = bound(uint256(orderCountSeed), 1, 5);
        uint64[] memory orderIds = _commitOpens(ALICE, orderCount);

        IOrderRouterAccounting.AccountReservationView memory reservationsBefore = router.getAccountReservations(ALICE);
        IMarginClearinghouse.AccountUsdcBuckets memory traderBucketsBefore = clearinghouse.getAccountUsdcBuckets(ALICE);
        uint256 executorSettlementBefore = clearinghouse.balanceUsdc(EXECUTOR);
        uint256 executorWalletBefore = usdc.balanceOf(EXECUTOR);
        uint256 traderWalletBefore = usdc.balanceOf(ALICE);

        assertEq(reservationsBefore.pendingOrderCount, orderCount);
        assertGt(reservationsBefore.committedMarginUsdc, 0);
        assertGt(reservationsBefore.executionBountyUsdc, 0);

        uint64 cutoff = _triggerRiskOff();
        assertEq(cutoff, orderIds[orderCount - 1]);

        _shuffle(orderIds, permutationSeed);
        for (uint256 i; i < orderIds.length; ++i) {
            vm.prank(EXECUTOR);
            router.clearRiskOffOrder(orderIds[i]);

            IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(orderIds[i]);
            assertEq(
                uint256(reservation.status),
                uint256(IMarginClearinghouse.ReservationStatus.Released),
                "risk-off must release every remaining committed-margin reservation"
            );
            assertEq(reservation.remainingAmountUsdc, 0);
            assertEq(
                uint256(_orderRecord(orderIds[i]).status),
                uint256(IOrderRouterAccounting.OrderStatus.Failed),
                "risk-off cleanup must be terminal"
            );
        }

        IOrderRouterAccounting.AccountReservationView memory reservationsAfter = router.getAccountReservations(ALICE);
        IMarginClearinghouse.AccountUsdcBuckets memory traderBucketsAfter = clearinghouse.getAccountUsdcBuckets(ALICE);

        assertEq(reservationsAfter.pendingOrderCount, 0);
        assertEq(reservationsAfter.committedMarginUsdc, 0);
        assertEq(reservationsAfter.executionBountyUsdc, 0);
        assertEq(router.nextExecuteId(), 0, "random non-head cleanup must leave the global FIFO structurally empty");
        assertEq(
            traderBucketsAfter.freeSettlementUsdc - traderBucketsBefore.freeSettlementUsdc,
            reservationsBefore.committedMarginUsdc + reservationsBefore.executionBountyUsdc,
            "all margin and bounty classifications must return to trader free settlement"
        );
        assertEq(
            traderBucketsAfter.settlementBalanceUsdc,
            traderBucketsBefore.settlementBalanceUsdc,
            "risk-off refunds must not mint, burn, or transfer gross settlement"
        );
        assertEq(clearinghouse.balanceUsdc(EXECUTOR), executorSettlementBefore, "cleanup caller must receive no credit");
        assertEq(usdc.balanceOf(EXECUTOR), executorWalletBefore, "cleanup caller must receive no tokens");
        assertEq(usdc.balanceOf(ALICE), traderWalletBefore, "refund must remain internal settlement");
    }

    /// @notice An old open remains non-executable after recovery, while a higher post-cutoff id executes normally.
    function testFuzz_InvalidatedOpenNeverRevivesAndPostCutoffOpenExecutes(
        uint16 oldLotsSeed,
        uint16 newLotsSeed,
        bool useBullSide
    ) public {
        CfdTypes.Side side = useBullSide ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
        uint256 oldSize = bound(uint256(oldLotsSeed), 10, 300) * CfdTypes.SIZE_QUANTUM;
        uint256 newSize = bound(uint256(newLotsSeed), 10, 300) * CfdTypes.SIZE_QUANTUM;

        uint64 oldOrderId = _commitOpen(ALICE, side, oldSize, _marginForSize(oldSize));
        assertEq(_triggerRiskOff(), oldOrderId);
        _recoverFromRiskOff();

        uint64 newOrderId = _commitOpen(ALICE, side, newSize, _marginForSize(newSize));
        assertGt(newOrderId, routerAdmin.riskOffOrderCutoff());

        uint256 executorBeforeOldCleanup = clearinghouse.balanceUsdc(EXECUTOR);
        vm.prank(EXECUTOR);
        router.executeOrder(oldOrderId, new bytes[](0));

        (uint256 sizeAfterOld,,,,,,) = engine.positions(ALICE);
        assertEq(sizeAfterOld, 0, "historically invalidated open must not reach the Engine after unpause");
        assertEq(clearinghouse.balanceUsdc(EXECUTOR), executorBeforeOldCleanup, "old bounty must return to trader");
        assertEq(uint256(_orderRecord(oldOrderId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));

        bytes[] memory newOrderUpdate = _mockPythUpdateData();
        vm.prank(EXECUTOR);
        router.executeOrder(newOrderId, newOrderUpdate);

        (uint256 finalSize,,,,,,) = engine.positions(ALICE);
        assertEq(finalSize, newSize, "post-unpause order above the cutoff must remain executable");
        assertEq(uint256(_orderRecord(newOrderId).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(routerAdmin.riskOffOrderCutoff(), oldOrderId, "healthy execution must not rewrite incident history");
    }

    /// @notice A cutoff-invalid increase at the FIFO head cannot strand the live close behind it.
    function testFuzz_RiskOffLeavesQueuedCloseLive(
        bool useBullSide
    ) public {
        CfdTypes.Side side = useBullSide ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
        uint256 positionSize = 20_000e18;
        _open(ALICE, side, positionSize, 5000e6, 1e8);

        uint64 invalidatedIncreaseId = _commitOpen(ALICE, side, 10_000e18, 2000e6);
        uint256 invalidatedBounty = _executionBountyReserve(invalidatedIncreaseId);
        uint64 closeOrderId = router.nextCommitId();
        vm.prank(ALICE);
        router.commitOrder(side, positionSize, 0, 0, true);
        uint256 closeBounty = _executionBountyReserve(closeOrderId);

        assertEq(_triggerRiskOff(), closeOrderId);
        uint256 executorBefore = clearinghouse.balanceUsdc(EXECUTOR);
        bytes[] memory closeUpdate = _mockPythUpdateData();
        vm.prank(EXECUTOR);
        router.executeOrder(closeOrderId, closeUpdate);

        (uint256 sizeAfter,,,,,,) = engine.positions(ALICE);
        assertEq(sizeAfter, 0, "risk-off must preserve queued close execution");
        assertEq(
            uint256(_orderRecord(invalidatedIncreaseId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed)
        );
        assertEq(uint256(_orderRecord(closeOrderId).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(
            clearinghouse.balanceUsdc(EXECUTOR) - executorBefore,
            closeBounty,
            "executor may receive the close bounty but never the invalidated-open bounty"
        );
        assertGt(invalidatedBounty, 0);
    }

    /// @notice Risk-off invalidation and trader refunds must not disable permissionless liquidation.
    function test_RiskOffLeavesLiquidationLive() public {
        _open(BOB, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);
        uint64 invalidatedIncreaseId = _commitOpen(BOB, CfdTypes.Side.BULL, 10_000e18, 2000e6);

        _triggerRiskOff();
        bytes[] memory liquidationUpdate = _mockPythUpdateData(1.98e8);
        vm.prank(EXECUTOR);
        router.executeLiquidation(BOB, liquidationUpdate);

        (uint256 sizeAfter,,,,,,) = engine.positions(BOB);
        assertEq(sizeAfter, 0, "risk-off must leave liquidation reachable");
        assertEq(router.pendingOrderCounts(BOB), 0);
        assertEq(
            uint256(_orderRecord(invalidatedIncreaseId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed)
        );
        assertEq(
            uint256(clearinghouse.getOrderReservation(invalidatedIncreaseId).status),
            uint256(IMarginClearinghouse.ReservationStatus.Released),
            "liquidation must apply risk-off refund precedence to the invalidated increase"
        );
    }

    /// @notice The unified guardian has one escalation capability and no direct component or recovery authority.
    function test_CoordinatorAuthorityRemainsLeastPrivilege() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        coordinator.setGuardian(OUTSIDER);

        vm.prank(GUARDIAN);
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__UnauthorizedPauser.selector);
        routerAdmin.pause();

        vm.prank(GUARDIAN);
        vm.expectRevert(IHousePool.HousePool__UnauthorizedPauser.selector);
        pool.pause();

        _triggerRiskOff();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        routerAdmin.unpause();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        pool.unpause();
    }

    function _commitOpens(
        address account,
        uint256 count
    ) internal returns (uint64[] memory orderIds) {
        orderIds = new uint64[](count);
        for (uint256 i; i < count; ++i) {
            orderIds[i] = _commitOpen(account, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        }
    }

    function _commitOpen(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin
    ) internal returns (uint64 orderId) {
        orderId = router.nextCommitId();
        vm.prank(account);
        router.commitOrder(side, size, margin, 1e8, false);
    }

    function _triggerRiskOff() internal returns (uint64 cutoff) {
        vm.prank(GUARDIAN);
        cutoff = coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);
    }

    function _recoverFromRiskOff() internal {
        routerAdmin.unpause();
        pool.unpause();
    }

    function _marginForSize(
        uint256 size
    ) internal pure returns (uint256) {
        // At the test's $1 mark, this is 20% of notional and safely above initial margin.
        return (size / 1e12) / 5;
    }

    function _shuffle(
        uint64[] memory values,
        uint256 seed
    ) internal pure {
        for (uint256 i = values.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (values[i - 1], values[j]) = (values[j], values[i - 1]);
        }
    }

}
