// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @notice Gas acceptance gates for the emergency risk-off path.
contract EmergencyRiskOffGasTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant GUARDIAN = address(0xCAFE);
    address internal constant KEEPER = address(0xBEEF);

    // V2 cleanup persists and emits an authenticated lifecycle receipt for every invalidated order. These limits
    // retain regression headroom while keeping the 64-order incident transaction below ArbOS 50's 32m tx cap.
    uint256 internal constant SINGLE_CLEANUP_GAS_LIMIT = 425_000;
    uint256 internal constant MAX_BATCH_CLEANUP_GAS_LIMIT = 28_000_000;
    uint256 internal constant COORDINATOR_ACTIVATION_GAS_LIMIT = 200_000;
    uint256 internal constant MAX_PENDING_ORDERS_PER_ACCOUNT = 32;

    bytes32 internal constant REASON_HASH = keccak256("risk-off-gas-acceptance");
    bytes32 internal constant EVIDENCE_HASH = keccak256("risk-off-gas-acceptance-evidence");

    EmergencyPauseCoordinator internal coordinator;

    function setUp() public override {
        super.setUp();

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPendingOrders = MAX_PENDING_ORDERS_PER_ACCOUNT;
        _setRouterConfig(config);

        coordinator = new EmergencyPauseCoordinator(address(routerAdmin), address(pool), address(this));
        coordinator.setGuardian(GUARDIAN);
        routerAdmin.setPauser(address(coordinator));
        pool.setPauser(address(coordinator));

        _fundTrader(ALICE, 100_000e6);
        _fundTrader(BOB, 100_000e6);
    }

    function test_Gas_ReservationSummaryOneOrder() public {
        _profileReservationSummary(1);
    }

    function test_Gas_ReservationSummaryFullAccountQueue() public {
        _profileReservationSummary(MAX_PENDING_ORDERS_PER_ACCOUNT);
    }

    function _profileReservationSummary(
        uint256 orderCount
    ) internal {
        for (uint256 i; i < orderCount; ++i) {
            _commitOpen(ALICE);
        }
        uint256 gasBefore = gasleft();
        uint256 pending = router.getAccountReservations(ALICE).pendingOrderCount;
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint(orderCount == 1 ? "reservationSummary_oneOrder" : "reservationSummary_32Orders", gasUsed);
        assertEq(pending, orderCount);
    }

    function test_Gas_RiskOffSingleTargetCleanupFitsAcceptanceGate() public {
        _commitOpen(ALICE);
        _activateRiskOff();

        vm.prank(KEEPER);
        uint256 gasBefore = gasleft();
        router.clearRiskOffOrder(1);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("risk_off_single_target_cleanup_gas", gasUsed);
        assertLe(gasUsed, SINGLE_CLEANUP_GAS_LIMIT);
        assertEq(router.nextExecuteId(), 0);
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(uint256(_orderRecord(1).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
    }

    function test_Gas_RiskOffKeeperCallRefundsExactly64OpensWithinBlockBudget() public {
        uint256 aliceFreeBefore = _freeSettlementUsdc(ALICE);
        uint256 bobFreeBefore = _freeSettlementUsdc(BOB);
        uint256 keeperFreeBefore = _freeSettlementUsdc(KEEPER);

        for (uint256 i; i < MAX_PENDING_ORDERS_PER_ACCOUNT; ++i) {
            _commitOpen(ALICE);
        }
        for (uint256 i; i < MAX_PENDING_ORDERS_PER_ACCOUNT; ++i) {
            _commitOpen(BOB);
        }
        assertEq(router.nextCommitId(), 65);
        assertEq(_activateRiskOff(), 64);

        vm.prank(KEEPER);
        uint256 gasBefore = gasleft();
        router.executeOrder(64, new bytes[](0));
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("risk_off_64_head_refunds_gas", gasUsed);
        assertLe(gasUsed, MAX_BATCH_CLEANUP_GAS_LIMIT);
        assertEq(router.nextExecuteId(), 0, "all 64 invalidated heads must be removed");
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(router.pendingOrderCounts(BOB), 0);
        assertEq(_freeSettlementUsdc(ALICE), aliceFreeBefore, "Alice must receive every reserve back");
        assertEq(_freeSettlementUsdc(BOB), bobFreeBefore, "Bob must receive every reserve back");
        assertEq(_freeSettlementUsdc(KEEPER), keeperFreeBefore, "keeper must receive no risk-off bounty");

        for (uint64 orderId = 1; orderId <= 64; ++orderId) {
            assertEq(
                uint256(_orderRecord(orderId).status),
                uint256(IOrderRouterAccounting.OrderStatus.Failed),
                "every covered open must be terminal"
            );
        }
    }

    function test_Gas_CoordinatorActivationFitsAcceptanceGate() public {
        _commitOpen(ALICE);

        vm.prank(GUARDIAN);
        uint256 gasBefore = gasleft();
        uint64 cutoff = coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("emergency_pause_coordinator_activation_gas", gasUsed);
        assertLe(gasUsed, COORDINATOR_ACTIVATION_GAS_LIMIT);
        assertEq(cutoff, 1);
        assertTrue(routerAdmin.paused());
        assertTrue(pool.paused());
    }

    function _commitOpen(
        address account
    ) internal {
        vm.prank(account);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8, false);
    }

    function _activateRiskOff() internal returns (uint64 cutoff) {
        vm.prank(GUARDIAN);
        cutoff = coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);
    }

}
