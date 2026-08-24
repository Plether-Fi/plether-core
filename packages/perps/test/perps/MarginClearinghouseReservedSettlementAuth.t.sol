// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract ReservedSettlementAuthEngineMock {

    address public orderRouter;
    address public settlementSidecar;
    uint256 public carryCheckpointCalls;
    address public lastCarryAccount;

    constructor(
        address orderRouter_,
        address settlementSidecar_
    ) {
        orderRouter = orderRouter_;
        settlementSidecar = settlementSidecar_;
    }

    function realizeCarryBeforeMarginChange(
        address account
    ) external {
        carryCheckpointCalls += 1;
        lastCarryAccount = account;
    }

}

contract ReservedSettlementAuthRouterMock {

    address public immutable positionProtectionBook;

    constructor(
        address positionProtectionBook_
    ) {
        positionProtectionBook = positionProtectionBook_;
    }

    function getAccountReservations(
        address
    ) external pure returns (IOrderRouterAccounting.AccountReservationView memory reservation) {}

}

contract MarginClearinghouseReservedSettlementAuthTest is Test {

    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant POSITION_PROTECTION_BOOK = address(0xB00C);
    address internal constant SETTLEMENT_SIDECAR = address(0x51DECA2);
    address internal constant STRANGER = address(0xBAD);

    MockUSDC internal usdc;
    MarginClearinghouse internal clearinghouse;
    ReservedSettlementAuthEngineMock internal engine;
    ReservedSettlementAuthRouterMock internal orderRouter;

    function setUp() public {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        orderRouter = new ReservedSettlementAuthRouterMock(POSITION_PROTECTION_BOOK);
        engine = new ReservedSettlementAuthEngineMock(address(orderRouter), SETTLEMENT_SIDECAR);
        clearinghouse.setEngine(address(engine));

        usdc.mint(ACCOUNT, 1000e6);
        vm.startPrank(ACCOUNT);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(ACCOUNT, 1000e6);
        vm.stopPrank();
    }

    function test_UnlockReservedSettlement_OrderRouterCanUnlockExactAmount() public {
        _lockFromRouter(200e6);
        uint256 checkpointsBefore = engine.carryCheckpointCalls();

        vm.prank(address(orderRouter));
        clearinghouse.unlockReservedSettlement(ACCOUNT, 200e6);

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(ACCOUNT);
        assertEq(buckets.reservedSettlementUsdc, 0, "router should unlock the exact reserved amount");
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(ACCOUNT), 1000e6, "unlocked settlement should become free");
        assertEq(engine.carryCheckpointCalls(), checkpointsBefore + 1, "unlock should checkpoint carry exactly once");
        assertEq(engine.lastCarryAccount(), ACCOUNT, "unlock should checkpoint the affected account");
    }

    function test_ReservedSettlement_PositionProtectionBookCanLockAndUnlockExactAmount() public {
        vm.prank(POSITION_PROTECTION_BOOK);
        clearinghouse.lockReservedSettlement(ACCOUNT, 200e6);
        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            200e6,
            "immutable Book should lock reserved settlement"
        );

        vm.prank(POSITION_PROTECTION_BOOK);
        clearinghouse.unlockReservedSettlement(ACCOUNT, 200e6);
        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            0,
            "immutable Book should unlock its exact reservation"
        );
    }

    function test_LockReservedSettlement_RejectsSettlementSidecar() public {
        vm.prank(SETTLEMENT_SIDECAR);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.lockReservedSettlement(ACCOUNT, 200e6);

        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            0,
            "sidecar must not gain new lock authority"
        );
    }

    function test_UnlockReservedSettlement_PreservesEngineAndSidecarAuthority() public {
        _lockFromRouter(300e6);

        vm.prank(address(engine));
        clearinghouse.unlockReservedSettlement(ACCOUNT, 100e6);
        vm.prank(SETTLEMENT_SIDECAR);
        clearinghouse.unlockReservedSettlement(ACCOUNT, 200e6);

        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            0,
            "engine and sidecar should retain unlock authority"
        );
    }

    function test_UnlockReservedSettlement_RejectsUnrelatedCaller() public {
        _lockFromRouter(200e6);

        vm.prank(STRANGER);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.unlockReservedSettlement(ACCOUNT, 200e6);

        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            200e6,
            "unauthorized unlock must preserve reservation"
        );
    }

    function test_UnlockReservedSettlement_RouterCannotUnlockMoreThanReserved() public {
        _lockFromRouter(200e6);

        vm.prank(address(orderRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBucketMargin.selector);
        clearinghouse.unlockReservedSettlement(ACCOUNT, 201e6);

        assertEq(
            clearinghouse.getLockedMarginBuckets(ACCOUNT).reservedSettlementUsdc,
            200e6,
            "failed exact unlock must roll back"
        );
    }

    function _lockFromRouter(
        uint256 amountUsdc
    ) internal {
        vm.prank(address(orderRouter));
        clearinghouse.lockReservedSettlement(ACCOUNT, amountUsdc);
    }

}
