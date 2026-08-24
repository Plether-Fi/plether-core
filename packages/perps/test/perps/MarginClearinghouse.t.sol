// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test, console} from "forge-std/Test.sol";

contract MockToken is ERC20 {

    uint8 _decimals;

    constructor(
        string memory name,
        string memory sym,
        uint8 dec
    ) ERC20(name, sym) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockClearinghouseEngine {

    address public orderRouter;
    address public settlementSidecar;
    uint256 public carryCheckpointCalls;
    address public lastCarryAccountId;

    function setOrderRouter(
        address router
    ) external {
        orderRouter = router;
    }

    function setSettlementSidecar(
        address sidecar
    ) external {
        settlementSidecar = sidecar;
    }

    function checkWithdraw(
        address
    ) external pure {}

    function realizeCarryBeforeMarginChange(
        address account
    ) external {
        carryCheckpointCalls += 1;
        lastCarryAccountId = account;
    }

    function syncLegacyPlaceholder() external {}

}

contract MockMarginReservationRouter {

    mapping(address => uint64[]) internal reservationIdsByAccount;
    mapping(address => uint256) internal executionBountyByAccount;

    function setMarginReservationIds(
        address account,
        uint64[] calldata orderIds
    ) external {
        delete reservationIdsByAccount[account];
        for (uint256 i = 0; i < orderIds.length; ++i) {
            reservationIdsByAccount[account].push(orderIds[i]);
        }
    }

    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory orderIds) {
        uint64[] storage stored = reservationIdsByAccount[account];
        orderIds = new uint64[](stored.length);
        for (uint256 i = 0; i < stored.length; ++i) {
            orderIds[i] = stored[i];
        }
    }

    function setExecutionBountyUsdc(
        address account,
        uint256 executionBountyUsdc
    ) external {
        executionBountyByAccount[account] = executionBountyUsdc;
    }

    function getAccountReservations(
        address account
    ) external view returns (uint256 committedMarginUsdc, uint256 executionBountyUsdc, uint256 pendingOrderCount) {
        committedMarginUsdc = 0;
        executionBountyUsdc = executionBountyByAccount[account];
        pendingOrderCount = executionBountyUsdc == 0 ? 0 : 1;
    }

}

contract MarginClearinghouseAccountingHarness {

    function planOpenCostApplication(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc
    ) external pure returns (MarginClearinghouseAccountingLib.OpenCostPlan memory) {
        return MarginClearinghouseAccountingLib.planOpenCostApplication(buckets, marginDeltaUsdc, tradeCostUsdc);
    }

    function buildAccountUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc
    ) external pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalanceUsdc, positionMarginUsdc, committedOrderMarginUsdc, reservedSettlementUsdc
        );
    }

    function buildPartialCloseUsdcBuckets(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc
    ) external pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        return MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
            settlementBalanceUsdc, positionMarginUsdc, committedOrderMarginUsdc, reservedSettlementUsdc
        );
    }

    function planTerminalLossConsumption(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc,
        uint256 lossUsdc
    ) external pure returns (MarginClearinghouseAccountingLib.SettlementConsumption memory) {
        return
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, protectedLockedMarginUsdc, lossUsdc);
    }

    function planLiquidationResidual(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        int256 residualUsdc
    ) external pure returns (MarginClearinghouseAccountingLib.LiquidationResidualPlan memory) {
        return MarginClearinghouseAccountingLib.planLiquidationResidual(buckets, residualUsdc);
    }

}

contract MarginClearinghouseTest is Test {

    MarginClearinghouse clearinghouse;
    MarginClearinghouseAccountingHarness accountingHarness;
    MockToken usdc;
    MockClearinghouseEngine mockEngine;
    MockMarginReservationRouter mockRouter;

    address alice = address(0x111);
    address engine;
    address aliceAccount;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        mockEngine = new MockClearinghouseEngine();
        mockRouter = new MockMarginReservationRouter();
        engine = address(mockEngine);
        accountingHarness = new MarginClearinghouseAccountingHarness();

        clearinghouse = new MarginClearinghouse(address(usdc));
        aliceAccount = alice;

        // Authorize our mock engine to lock and settle funds.
        clearinghouse.setEngine(engine);
        mockEngine.setOrderRouter(address(mockRouter));

        // Fund Alice
        usdc.mint(alice, 5000 * 1e6); // $5k USDC

        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6); // $5k USDC

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceAccount);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceAccount, 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceAccount, 1000 * 1e6);

        assertEq(usdc.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityUsdc(aliceAccount),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceAccount);
        assertEq(freeBp, 500 * 1e6, "Free BP should be $500");

        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceAccount, 1000 * 1e6);
    }

    function test_IMarginAccount_ExposesFreeBuyingPowerInsteadOfWithdrawableAlias() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 4200 * 1e6);

        assertEq(
            clearinghouse.getFreeBuyingPowerUsdc(aliceAccount), 800 * 1e6, "free buying power should remain exposed"
        );
    }

    function test_GetAccountUsdcBuckets_SplitsTypedLockedMarginBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 300 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);

        assertEq(buckets.settlementBalanceUsdc, 2000 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1100 * 1e6);
    }

    function test_GetPnlIsolationBuckets_ReportsFourIndependentLocks() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.lockLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 150 * 1e6);
        clearinghouse.lockActionReserve(aliceAccount, 50 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceUsdc, 1000 * 1e6);
        assertEq(buckets.pnlPledgeUsdc, 200 * 1e6);
        assertEq(buckets.liquidationReserveUsdc, 100 * 1e6);
        assertEq(buckets.orderMarginUsdc, 150 * 1e6);
        assertEq(buckets.actionReserveUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedUsdc, 500 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 500 * 1e6);
    }

    function test_GetLockedMarginBuckets_ReturnsTypedBucketBreakdown() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 100 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);

        assertEq(buckets.positionMarginUsdc, 200 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 100 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 0);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
    }

    function test_UnlockCommittedOrderMargin_DoesNotTouchPositionBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 400 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 200 * 1e6);
        clearinghouse.unlockCommittedOrderMargin(aliceAccount, 200 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        assertEq(
            buckets.positionMarginUsdc, 400 * 1e6, "Unlocking committed order margin must not touch position margin"
        );
        assertEq(buckets.committedOrderMarginUsdc, 0, "Committed order margin should unlock independently");
        assertEq(buckets.totalLockedMarginUsdc, 400 * 1e6);
    }

    function test_UnlockCommittedOrderMargin_CheckpointsCarryBeforeUnlock() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 200 * 1e6);

        uint256 checkpointCallsBeforeUnlock = mockEngine.carryCheckpointCalls();

        vm.prank(engine);
        clearinghouse.unlockCommittedOrderMargin(aliceAccount, 200 * 1e6);

        assertEq(
            mockEngine.carryCheckpointCalls(),
            checkpointCallsBeforeUnlock + 1,
            "Committed-margin unlock should checkpoint carry before funds become reachable again"
        );
        assertEq(
            mockEngine.lastCarryAccountId(), aliceAccount, "Unlock should checkpoint carry for the unlocked account"
        );
    }

    function test_LockCommittedOrderMargin_RevertsWhenReservationLedgerIsActive() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 17, 200 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ReservationLedgerActive.selector);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 100 * 1e6);
    }

    function test_UnlockCommittedOrderMargin_RevertsWhenReservationLedgerIsActive() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 200 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 18, 100 * 1e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ReservationLedgerActive.selector);
        clearinghouse.unlockCommittedOrderMargin(aliceAccount, 50 * 1e6);
        vm.stopPrank();
    }

    function test_LockCommittedOrderMargin_CheckpointsIndexedCarryDirectly() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 200 * 1e6);

        assertEq(mockEngine.carryCheckpointCalls(), 2, "Committed-margin lock should checkpoint indexed carry directly");
        assertEq(mockEngine.lastCarryAccountId(), aliceAccount, "Checkpoint should use the mutated account id");
    }

    function test_ReserveCommittedOrderMargin_CreatesReservationAndMatchesBucketTotals() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 11, 200 * 1e6);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(11);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.account, aliceAccount);
        assertEq(uint256(reservation.bucket), uint256(IMarginClearinghouse.ReservationBucket.CommittedOrder));
        assertEq(reservation.originalAmountUsdc, 200 * 1e6);
        assertEq(reservation.remainingAmountUsdc, 200 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 200 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 200 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_ReleaseOrderReservation_ReleasesResidualAndMarksReleased() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 12, 180 * 1e6);

        vm.prank(engine);
        uint256 releasedUsdc = clearinghouse.releaseOrderReservation(12);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(12);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(releasedUsdc, 180 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountUsdc, 0);
        assertEq(buckets.committedOrderMarginUsdc, 0);
        assertEq(summary.activeCommittedOrderMarginUsdc, 0);
        assertEq(summary.activeReservationCount, 0);
    }

    function test_ReleaseOrderReservationIfActive_ClearsSummaryMetadata() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 14, 180 * 1e6);

        vm.prank(engine);
        uint256 releasedUsdc = clearinghouse.releaseOrderReservationIfActive(14);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(14);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(releasedUsdc, 180 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountUsdc, 0);
        assertEq(buckets.committedOrderMarginUsdc, 0);
        assertEq(summary.activeCommittedOrderMarginUsdc, 0);
        assertEq(summary.activeReservationCount, 0);
    }

    function test_ReleaseOrderReservationIfActive_CheckpointsCarryBeforeRelease() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 15, 180 * 1e6);

        uint256 checkpointCallsBeforeRelease = mockEngine.carryCheckpointCalls();

        vm.prank(engine);
        clearinghouse.releaseOrderReservationIfActive(15);

        assertEq(
            mockEngine.carryCheckpointCalls(),
            checkpointCallsBeforeRelease + 1,
            "Reservation release should checkpoint carry before committed margin becomes reachable again"
        );
        assertEq(
            mockEngine.lastCarryAccountId(), aliceAccount, "Release should checkpoint carry for the released account"
        );
    }

    function test_ReleaseOrderReservationIfActive_CheckpointsIndexedCarryDirectly() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 16, 180 * 1e6);

        uint256 checkpointCallsBeforeRelease = mockEngine.carryCheckpointCalls();

        vm.prank(engine);
        clearinghouse.releaseOrderReservationIfActive(16);

        assertEq(
            mockEngine.carryCheckpointCalls(),
            checkpointCallsBeforeRelease + 1,
            "Reservation release should checkpoint indexed carry directly"
        );
        assertEq(mockEngine.lastCarryAccountId(), aliceAccount, "Release checkpoint should use the reservation account");
    }

    function test_GenericReservedUnlockCheckpointsButFreshEngineBountyLockDoesNotReenter() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockReservedSettlement(aliceAccount, 200 * 1e6);

        uint256 checkpointCallsBeforeUnlock = mockEngine.carryCheckpointCalls();

        vm.prank(engine);
        clearinghouse.unlockReservedSettlement(aliceAccount, 200 * 1e6);

        assertEq(
            mockEngine.carryCheckpointCalls(),
            checkpointCallsBeforeUnlock + 1,
            "Reserved-settlement unlock should checkpoint indexed carry directly"
        );
        assertEq(
            mockEngine.lastCarryAccountId(),
            aliceAccount,
            "Reserved-settlement checkpoint should use the mutated account"
        );

        uint256 checkpointCallsBeforeFreshBountyLock = mockEngine.carryCheckpointCalls();
        vm.prank(engine);
        clearinghouse.reserveCloseExecutionBountyFromSettlement(aliceAccount, 50 * 1e6);

        assertEq(
            mockEngine.carryCheckpointCalls(),
            checkpointCallsBeforeFreshBountyLock,
            "Engine-controlled fresh bounty lock must not reenter the engine checkpoint hook"
        );
        assertEq(clearinghouse.actionReserveUsdc(aliceAccount), 50 * 1e6);
    }

    function test_CloseBountySettlementHooks_AuthorizeOnlyEngineAndBoundSidecar() public {
        address sidecar = address(0x5E771E);
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);
        mockEngine.setSettlementSidecar(sidecar);

        vm.prank(engine);
        clearinghouse.reserveCloseExecutionBountyFromSettlement(aliceAccount, 10 * 1e6);
        vm.prank(sidecar);
        clearinghouse.reserveCloseExecutionBountyFromSettlement(aliceAccount, 20 * 1e6);
        vm.prank(sidecar);
        clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(aliceAccount, 30 * 1e6);

        assertEq(clearinghouse.actionReserveUsdc(aliceAccount), 60 * 1e6, "authorized paths must reserve exactly");

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.reserveCloseExecutionBountyFromSettlement(aliceAccount, 1);

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(aliceAccount, 1);

        assertEq(clearinghouse.actionReserveUsdc(aliceAccount), 60 * 1e6, "rejected callers must not mutate reserve");
    }

    function test_ConsumeOrderReservation_ReducesResidualAndKeepsAggregateParity() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 13, 220 * 1e6);

        vm.prank(engine);
        uint256 consumedUsdc = clearinghouse.consumeOrderReservation(13, 70 * 1e6);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(13);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(consumedUsdc, 70 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 150 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 150 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 150 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_ConsumeAccountOrderReservations_ConsumesActiveReservationsInFifoOrder() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 21, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 22, 120 * 1e6);
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 21;
        reservationIds[1] = 22;
        mockRouter.setMarginReservationIds(aliceAccount, reservationIds);
        uint256 consumedUsdc = clearinghouse.consumeAccountOrderReservations(aliceAccount, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(21);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(22);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(consumedUsdc, 150 * 1e6);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(first.remainingAmountUsdc, 0);
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(second.remainingAmountUsdc, 70 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 70 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 70 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_ConsumeOrderReservationsById_UsesSuppliedReservationOrder() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 51, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 52, 120 * 1e6);
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 52;
        reservationIds[1] = 51;
        uint256 consumedUsdc = clearinghouse.consumeOrderReservationsById(reservationIds, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(51);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(52);

        assertEq(consumedUsdc, 150 * 1e6);
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(second.remainingAmountUsdc, 0);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(first.remainingAmountUsdc, 70 * 1e6);
    }

    function test_ReleaseOrderReservation_ClearsTerminalReservationsWithoutHistoricalHeadTracking() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 71, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 72, 120 * 1e6);
        clearinghouse.releaseOrderReservation(71);
        vm.stopPrank();

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(71);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Released));

        vm.prank(engine);
        clearinghouse.releaseOrderReservation(72);

        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(72);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(summary.activeReservationCount, 0, "All terminal reservations should clear the active summary");
    }

    function test_Withdraw_WrongOwner_Reverts() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        address bob = address(0x222);
        vm.prank(bob);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        clearinghouse.withdraw(aliceAccount, 500 * 1e6);
    }

    function test_UnlockPositionMargin_RevertsOnBucketUnderflow() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBucketMargin.selector);
        clearinghouse.unlockPositionMargin(aliceAccount, 2000 * 1e6);

        assertEq(
            clearinghouse.lockedMarginUsdc(aliceAccount),
            1000 * 1e6,
            "Bucketed lock should remain unchanged after failed over-unlock"
        );
    }

    function test_RouterPermissionSurface_IsLimitedToReservationAccounting() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(address(mockRouter));
        clearinghouse.lockReservedSettlement(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 99, 200 * 1e6);
        uint256 releasedUsdc = clearinghouse.releaseOrderReservationIfActive(99);
        vm.stopPrank();

        assertEq(releasedUsdc, 200 * 1e6, "router should release its own active reservation");
        assertEq(
            clearinghouse.getLockedMarginBuckets(aliceAccount).reservedSettlementUsdc,
            100 * 1e6,
            "router should still be able to reserve execution-bounty settlement"
        );

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.settleUsdc(aliceAccount, int256(1e6));

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.transferReservedSettlement(aliceAccount, address(0xB0B), 1);
    }

    function test_C01_WithdrawUsdcBelowLockedMargin_ShouldRevert() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 1000 * 1e6);

        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceAccount, 1000 * 1e6);
    }

    function test_ConsumeSettlementLoss_PreservesOtherLockedBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockReservedSettlement(aliceAccount, 300 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeSettlementLoss(aliceAccount, 600 * 1e6, 1200 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 0, "Carry/action loss must not consume PnL pledge");
        assertEq(uncovered, 100 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 900 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeSettlementLoss_ReturnsUncoveredWhenFreeAndActiveMarginInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 61, 300 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeSettlementLoss(aliceAccount, 600 * 1e6, 2000 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(61);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 0);
        assertEq(uncovered, 900 * 1e6, "Only free settlement is eligible for carry/action loss");
        assertEq(buckets.settlementBalanceUsdc, 900 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 300 * 1e6);
    }

    function test_ConsumeLiquidationResidual_RejectsOrderMarginConsumption() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 41, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 41;
        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementRetainedUsdc: 200 * 1e6,
            settlementSeizedUsdc: 1800 * 1e6,
            freshTraderPayoutUsdc: 0,
            badDebtUsdc: 0,
            positionMarginUnlockedUsdc: 600 * 1e6,
            otherLockedMarginUnlockedUsdc: 100 * 1e6
        });
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidMarginBucket.selector);
        clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, reservationIds, plan, engine, address(0), 0, address(0), 0, 0
        );
        vm.stopPrank();
    }

    function test_ConsumeCloseLoss_ConsumesOnlyPnlPledge() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 31, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 31;
        (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc) =
            clearinghouse.consumeCloseLoss(aliceAccount, reservationIds, 1800 * 1e6, 0, true, engine, address(0), 0);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);
        assertEq(seizedUsdc, 600 * 1e6);
        assertEq(shortfallUsdc, 1200 * 1e6);
        assertEq(protocolFeeCreditedUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 1400 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1100 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 300 * 1e6);
    }

    function test_ConsumeCloseLoss_DoesNotRequireReservationIds() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        (uint256 seizedUsdc, uint256 shortfallUsdc,) =
            clearinghouse.consumeCloseLoss(aliceAccount, reservationIds, 1800 * 1e6, 0, true, engine, address(0), 0);
        vm.stopPrank();

        assertEq(seizedUsdc, 600 * 1e6);
        assertEq(shortfallUsdc, 1200 * 1e6);
        assertEq(clearinghouse.orderMarginUsdc(aliceAccount), 300 * 1e6);
    }

    function test_ConsumeCloseLoss_LeavesAggregateOrderMarginUntouched() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        (uint256 seizedUsdc, uint256 shortfallUsdc,) =
            clearinghouse.consumeCloseLoss(aliceAccount, reservationIds, 1500 * 1e6, 0, true, engine, address(0), 0);
        vm.stopPrank();

        assertEq(seizedUsdc, 600 * 1e6);
        assertEq(shortfallUsdc, 900 * 1e6);
        assertEq(clearinghouse.orderMarginUsdc(aliceAccount), 300 * 1e6);
    }

    function test_ConsumeCloseLoss_PartialCloseCollectsBeforeUnlockAndProtectsResidualPledge() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 400 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 31, 300 * 1e6);

        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 31;
        (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc) = clearinghouse.consumeCloseLoss(
            aliceAccount, reservationIds, 250 * 1e6, 100 * 1e6, false, engine, address(0), 0
        );
        clearinghouse.unlockPositionMargin(aliceAccount, 50 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);

        assertEq(seizedUsdc, 250 * 1e6, "Price loss should consume only the closed lots' pledge allocation");
        assertEq(shortfallUsdc, 0);
        assertEq(protocolFeeCreditedUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 750 * 1e6);
        assertEq(
            buckets.totalLockedMarginUsdc,
            400 * 1e6,
            "Remaining locked margin should still include live position and queued order"
        );
        assertEq(buckets.activePositionMarginUsdc, 100 * 1e6, "Residual-position pledge must remain protected");
        assertEq(buckets.freeSettlementUsdc, 350 * 1e6, "Only unused closed allocation becomes free after collection");
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(
            reservation.remainingAmountUsdc, 300 * 1e6, "Queued reservation should remain untouched by partial close"
        );
    }

    function test_ConsumeLiquidationResidual_RevertsWhenReservationIdsDoNotCoverCommittedBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementRetainedUsdc: 200 * 1e6,
            settlementSeizedUsdc: 1800 * 1e6,
            freshTraderPayoutUsdc: 0,
            badDebtUsdc: 0,
            positionMarginUnlockedUsdc: 600 * 1e6,
            otherLockedMarginUnlockedUsdc: 100 * 1e6
        });
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidMarginBucket.selector);
        clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, reservationIds, plan, engine, address(0), 0, address(0), 0, 0
        );
        vm.stopPrank();
    }

    function test_CreditSettlementAndLockMargin_CreditsAndLocksSameBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditSettlementAndLockMargin(aliceAccount, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceUsdc, 1200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1000 * 1e6);
    }

    function test_CreditPnlPledge_CreditsCustodyClassificationWithoutIncreasingFreeSettlement() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditPnlPledge(aliceAccount, 200 * 1e6);

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceUsdc, 1200 * 1e6);
        assertEq(buckets.pnlPledgeUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1000 * 1e6);
    }

    function test_PromoteOrderReservationToPnlPledge_ReclassifiesWithoutChangingTotalLocked() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 81, 200 * 1e6);
        clearinghouse.promoteOrderReservationToPnlPledge(81, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(81);
        assertEq(buckets.pnlPledgeUsdc, 150 * 1e6);
        assertEq(buckets.orderMarginUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 800 * 1e6);
        assertEq(reservation.remainingAmountUsdc, 50 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
    }

    function test_ConsumePnlPledgeLoss_ProtectsFreeAndEveryReserveBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.lockLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 100 * 1e6);
        clearinghouse.lockActionReserve(aliceAccount, 100 * 1e6);
        (uint256 consumedUsdc, uint256 shortfallUsdc) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 350 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(consumedUsdc, 200 * 1e6);
        assertEq(shortfallUsdc, 150 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 800 * 1e6);
        assertEq(buckets.pnlPledgeUsdc, 0);
        assertEq(buckets.liquidationReserveUsdc, 100 * 1e6);
        assertEq(buckets.orderMarginUsdc, 100 * 1e6);
        assertEq(buckets.actionReserveUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 500 * 1e6);
    }

    function test_ConsumeActionCharge_UsesSpendableReserveThenFreeAndPreservesRouterBounty() public {
        address recipient = address(0x5001);
        address protocolTreasury = address(0xFEE5);
        address keeper = address(0xB0A7);

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1200 * 1e6);
        mockRouter.setExecutionBountyUsdc(aliceAccount, 150 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 300 * 1e6);
        clearinghouse.lockLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceAccount, 100 * 1e6);
        clearinghouse.lockActionReserve(aliceAccount, 350 * 1e6);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ActionReserveMismatch.selector);
        clearinghouse.consumeActionCharge(aliceAccount, 450 * 1e6, 350 * 1e6, 0, recipient, protocolTreasury, 50 * 1e6);

        (uint256 collectedUsdc, uint256 protocolFeeCreditedUsdc) = clearinghouse.consumeActionCharge(
            aliceAccount, 450 * 1e6, 200 * 1e6, 0, recipient, protocolTreasury, 50 * 1e6
        );

        IMarginClearinghouse.PnlIsolationBuckets memory beforeBountyPayment =
            clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(beforeBountyPayment.actionReserveUsdc, 150 * 1e6);

        mockRouter.setExecutionBountyUsdc(aliceAccount, 0);
        clearinghouse.transferReservedSettlement(aliceAccount, keeper, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(collectedUsdc, 450 * 1e6);
        assertEq(protocolFeeCreditedUsdc, 50 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 600 * 1e6);
        assertEq(buckets.pnlPledgeUsdc, 300 * 1e6);
        assertEq(buckets.liquidationReserveUsdc, 100 * 1e6);
        assertEq(buckets.orderMarginUsdc, 100 * 1e6);
        assertEq(buckets.actionReserveUsdc, 0);
        assertEq(buckets.freeSettlementUsdc, 100 * 1e6);
        assertEq(clearinghouse.balanceUsdc(protocolTreasury), 50 * 1e6);
        assertEq(clearinghouse.balanceUsdc(keeper), 150 * 1e6);
        assertEq(usdc.balanceOf(recipient), 400 * 1e6);
    }

    function test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.prank(engine);
        (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc) =
            clearinghouse.applyOpenCost(aliceAccount, 300 * 1e6, int256(200 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        assertEq(netMarginChangeUsdc, 100 * 1e6);
        assertEq(protocolFeeCreditedUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 1800 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1700 * 1e6);
    }

    function test_ApplyOpenCost_DoesNotUnlockExistingPnlPledgeForTradeCost() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 100 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);

        assertEq(
            clearinghouse.getAccountUsdcBuckets(aliceAccount).freeSettlementUsdc,
            0,
            "setup must start with zero free settlement"
        );

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.applyOpenCost(aliceAccount, 0, int256(20 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceUsdc, 100 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ApplyOpenCost_RevertsWhenTradeCostAndMarginLockExceedFreeSettlement() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 99 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.applyOpenCost(aliceAccount, 100 * 1e6, int256(20 * 1e6), engine, address(0), 0);
    }

    function test_ApplyOpenCost_RevertsWhenPositiveCostExceedsFreeSettlement() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 10 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 10 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.applyOpenCost(aliceAccount, 0, int256(20 * 1e6), engine, address(0), 0);
    }

    function test_ApplyOpenCost_NegativeRebateRemainsFreeSettlement() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 300 * 1e6);

        vm.prank(engine);
        (int256 netMarginChangeUsdc,) =
            clearinghouse.applyOpenCost(aliceAccount, 200 * 1e6, -int256(50 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(netMarginChangeUsdc, int256(200 * 1e6));
        assertEq(buckets.settlementBalanceUsdc, 350 * 1e6);
        assertEq(buckets.pnlPledgeUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 150 * 1e6, "Rebate must not auto-increase PnL pledge");
    }

    function testFuzz_ApplyOpenCost_MatchesSharedOpenPlan(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc
    ) public {
        settlementBalanceUsdc = bound(settlementBalanceUsdc, 1, 5000e6);
        positionMarginUsdc = bound(positionMarginUsdc, 0, settlementBalanceUsdc);
        uint256 remainingAfterPosition = settlementBalanceUsdc - positionMarginUsdc;
        committedOrderMarginUsdc = bound(committedOrderMarginUsdc, 0, remainingAfterPosition);
        uint256 remainingAfterCommitted = remainingAfterPosition - committedOrderMarginUsdc;
        reservedSettlementUsdc = bound(reservedSettlementUsdc, 0, remainingAfterCommitted);
        marginDeltaUsdc = bound(marginDeltaUsdc, 0, 5000e6);
        tradeCostUsdc = int256(bound(tradeCostUsdc, -5000e6, 5000e6));

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, settlementBalanceUsdc);

        vm.startPrank(engine);
        if (positionMarginUsdc > 0) {
            clearinghouse.lockPositionMargin(aliceAccount, positionMarginUsdc);
        }
        if (committedOrderMarginUsdc > 0) {
            clearinghouse.lockCommittedOrderMargin(aliceAccount, committedOrderMarginUsdc);
        }
        if (reservedSettlementUsdc > 0) {
            clearinghouse.lockReservedSettlement(aliceAccount, reservedSettlementUsdc);
        }
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        MarginClearinghouseAccountingLib.OpenCostPlan memory plan =
            accountingHarness.planOpenCostApplication(bucketsBefore, marginDeltaUsdc, tradeCostUsdc);

        vm.startPrank(engine);
        if (plan.insufficientPositionMargin) {
            vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBucketMargin.selector);
            clearinghouse.applyOpenCost(aliceAccount, marginDeltaUsdc, tradeCostUsdc, engine, address(0), 0);
        } else if (plan.insufficientFreeEquity) {
            vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
            clearinghouse.applyOpenCost(aliceAccount, marginDeltaUsdc, tradeCostUsdc, engine, address(0), 0);
        } else {
            (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc) =
                clearinghouse.applyOpenCost(aliceAccount, marginDeltaUsdc, tradeCostUsdc, engine, address(0), 0);
            IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter =
                clearinghouse.getAccountUsdcBuckets(aliceAccount);
            assertEq(
                netMarginChangeUsdc, plan.netMarginChangeUsdc, "Live open-cost net margin change should match plan"
            );
            assertEq(protocolFeeCreditedUsdc, 0);
            assertEq(
                bucketsAfter.settlementBalanceUsdc,
                plan.resultingSettlementBalanceUsdc,
                "Live settlement balance should match planned open-cost mutation"
            );
            assertEq(
                bucketsAfter.activePositionMarginUsdc,
                plan.resultingPositionMarginUsdc,
                "Live position margin should match planned open-cost mutation"
            );
            assertEq(
                bucketsAfter.freeSettlementUsdc,
                plan.resultingFreeSettlementUsdc,
                "Live free settlement should match planned open-cost mutation"
            );
        }
        vm.stopPrank();
    }

    function test_ConsumeCloseLoss_LeavesFreeAndOrderMarginOutsideTerminalPriceLossCap() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 31, 300 * 1e6);
        vm.stopPrank();

        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 31;

        vm.prank(engine);
        (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc) =
            clearinghouse.consumeCloseLoss(aliceAccount, reservationIds, 1800 * 1e6, 0, true, engine, address(0), 0);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);
        assertEq(seizedUsdc, 600 * 1e6);
        assertEq(shortfallUsdc, 1200 * 1e6);
        assertEq(protocolFeeCreditedUsdc, 0);
        assertEq(bucketsAfter.settlementBalanceUsdc, 1400 * 1e6);
        assertEq(bucketsAfter.activePositionMarginUsdc, 0);
        assertEq(bucketsAfter.freeSettlementUsdc, 1100 * 1e6);
        assertEq(reservation.remainingAmountUsdc, 300 * 1e6);
    }

    function test_ApplyLiquidationSettlementPlan_ConsumesPnlPledgeWithoutTouchingOrderMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 41, 300 * 1e6);
        vm.stopPrank();

        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 41;
        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan =
            IMarginClearinghouse.LiquidationSettlementPlan({
                settlementRetainedUsdc: 0,
                settlementSeizedUsdc: 600 * 1e6,
                freshTraderPayoutUsdc: 0,
                badDebtUsdc: 0,
                positionMarginUnlockedUsdc: 600 * 1e6,
                otherLockedMarginUnlockedUsdc: 0
            });

        vm.prank(engine);
        uint256 seizedUsdc = clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, reservationIds, settlementPlan, engine, address(0), 0, address(0), 0, 0
        );

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(41);
        assertEq(seizedUsdc, 600 * 1e6);
        assertEq(bucketsAfter.settlementBalanceUsdc, 1400 * 1e6);
        assertEq(bucketsAfter.activePositionMarginUsdc, 0, "Liquidation should unlock the full live position margin");
        assertEq(bucketsAfter.freeSettlementUsdc, 1100 * 1e6);
        assertEq(reservation.remainingAmountUsdc, 300 * 1e6);
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        clearinghouse.deposit(aliceAccount, 0);
    }

    function test_ApplyLiquidationSettlementPlan_RoutesKeeperProtocolAndPoolAllocations() public {
        address keeper = address(0xB0A7);
        address protocolTreasury = address(0xFEE5);
        address poolRecipient = address(0x5001);

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.lockLiquidationReserve(aliceAccount, 250 * 1e6);
        vm.stopPrank();

        uint64[] memory reservationIds = new uint64[](0);
        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementRetainedUsdc: 250 * 1e6,
            settlementSeizedUsdc: 600 * 1e6,
            freshTraderPayoutUsdc: 0,
            badDebtUsdc: 0,
            positionMarginUnlockedUsdc: 600 * 1e6,
            otherLockedMarginUnlockedUsdc: 0
        });

        vm.prank(engine);
        uint256 seizedUsdc = clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, reservationIds, plan, poolRecipient, keeper, 100 * 1e6, protocolTreasury, 50 * 1e6, 50 * 1e6
        );

        assertEq(seizedUsdc, 600 * 1e6, "Only the pool allocation should be returned as seized cash");
        assertEq(clearinghouse.balanceUsdc(aliceAccount), 250 * 1e6, "Source debit should include all allocations");
        assertEq(clearinghouse.balanceUsdc(keeper), 100 * 1e6, "Keeper should receive its internal credit");
        assertEq(
            clearinghouse.balanceUsdc(protocolTreasury),
            50 * 1e6,
            "Protocol treasury should receive its internal credit"
        );
        assertEq(
            usdc.balanceOf(poolRecipient), 600 * 1e6, "Only the pool allocation should leave clearinghouse custody"
        );
        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.pnlPledgeUsdc, 0, "Unused PnL pledge should become free after full liquidation");
        assertEq(buckets.liquidationReserveUsdc, 0, "Unused liquidation reserve should become free");
        assertEq(buckets.freeSettlementUsdc, 250 * 1e6);
    }

}

contract MarginClearinghouseAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
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

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-7 — fee-on-transfer accounting mismatch
    // H-02 FIX: free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Position should be open");

        uint256 freeBalance = clearinghouse.balanceUsdc(account) - clearinghouse.lockedMarginUsdc(account);
        assertGt(freeBalance, 0, "Alice should have free balance");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(account, freeBalance);
        assertEq(usdc.balanceOf(alice), balBefore + freeBalance, "Free equity withdrawn");
    }

    // Regression: Finding-8 — withdraw allowed after position close
    function test_WithdrawAllowedAfterClose() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 1e8, true);
        router.executeOrder(2, _mockPythUpdateData());

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be closed");

        uint256 balance = clearinghouse.balanceUsdc(account);
        vm.prank(alice);
        clearinghouse.withdraw(account, balance);
        assertEq(usdc.balanceOf(alice), balance, "Alice should receive her USDC");
    }

    function test_Withdraw_UsesEngineGuardParityForOpenPositions() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        WithdrawParityState memory state = _observeWithdrawParity(account, alice, 5000e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_Withdraw_FailsConsistentlyWhenGuardWouldFailOnStaleMark() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        WithdrawParityState memory state = _observeWithdrawParity(account, alice, 100e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
    }

    function test_Withdraw_UsesCarryAwareGuardParityForOpenPositions() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 100_000;
        _setRiskParams(params);

        _fundTrader(alice, 10_000 * 1e6);
        address account = alice;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        WithdrawParityState memory state = _observeWithdrawParity(account, alice, 80e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

}

contract NonUsdcCollateralTest is Test {

    MockToken usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        usdc = new MockToken("Mock USDC", "USDC", 6);

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine));
        TrancheVault seniorVault =
            new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        vm.warp(1_709_532_000);

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        usdc.approve(address(juniorVault), type(uint256).max);
        uint256 requestId = juniorVault.requestDeposit(5_000_000 * 1e6, address(this), address(this));
        vm.warp(pool.lpEpochStart(requestId));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.settleLpEpoch(0, 0);
        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, address(this));
        juniorVault.claimDeposit(requestId, claimableAssets, address(this), address(this));
    }

    function _deposit(
        address account,
        uint256 amount
    ) internal {
        address user = account;
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function externalOpen(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) external {
        _open(account, side, size, margin, price, depth);
    }

    // Regression: H-02 — non-USDC collateral blocks overleveraged position
    // Regression: H-02 — lockMargin accepts non-USDC equity


}
