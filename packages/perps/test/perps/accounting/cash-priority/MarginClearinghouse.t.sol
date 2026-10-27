// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

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

}

contract MockMarginReservationRouter {

    IMarginClearinghouse internal clearinghouse;
    mapping(address => uint64) internal bountyIds;
    uint64 internal nextBountyId = 1;

    function setClearinghouse(
        address clearinghouse_
    ) external {
        clearinghouse = IMarginClearinghouse(clearinghouse_);
    }

    function setExecutionBountyAssets(
        address account,
        uint256 amount
    ) external {
        if (amount == 0) {
            clearinghouse.takeBountyReservation(account, IMarginClearinghouse.BountyKind.Order, bountyIds[account]);
        } else {
            uint64 id = nextBountyId++;
            bountyIds[account] = id;
            clearinghouse.recordBountyReservation(account, IMarginClearinghouse.BountyKind.Order, id, amount);
        }
    }

}

/// @dev Test-only corruption of the clearinghouse index exercises settlement's defensive checks.
contract ClearinghouseReservationIndexHarness is MarginClearinghouse {

    constructor(
        address settlementAsset_
    ) MarginClearinghouse(settlementAsset_) {}

    function setMarginReservationIds(
        address account,
        uint64[] memory ids
    ) external {
        reservationQueues[account] =
            ReservationQueue({head: ids[0], tail: ids[ids.length - 1], count: uint128(ids.length)});
        for (uint256 i; i < ids.length; ++i) {
            orderReservations[ids[i]].previousOrderId = i == 0 ? 0 : ids[i - 1];
            orderReservations[ids[i]].nextOrderId = i + 1 == ids.length ? 0 : ids[i + 1];
        }
    }

}

contract MarginClearinghouseAccountingHarness {

    function planOpenCostApplication(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets
    ) external pure returns (MarginClearinghouseAccountingLib.OpenCostPlan memory) {
        return MarginClearinghouseAccountingLib.planOpenCostApplication(buckets, marginDeltaAssets, tradeCostAssets);
    }

}

contract MarginClearinghouseTest is Test {

    event RiskOffOrderReservesRefunded(
        address indexed account, uint256 releasedMarginAssets, uint256 executionBountyAssets
    );

    MarginClearinghouse clearinghouse;
    MarginClearinghouseAccountingHarness accountingHarness;
    MockToken settlementToken;
    MockClearinghouseEngine mockEngine;
    MockMarginReservationRouter mockRouter;

    address alice = address(0x111);
    address engine;
    address aliceAccount;

    function setUp() public {
        settlementToken = new MockToken("SETTLEMENT", "SETTLEMENT", 6);
        mockEngine = new MockClearinghouseEngine();
        mockRouter = new MockMarginReservationRouter();
        engine = address(mockEngine);
        accountingHarness = new MarginClearinghouseAccountingHarness();

        clearinghouse = new ClearinghouseReservationIndexHarness(address(settlementToken));
        mockRouter.setClearinghouse(address(clearinghouse));
        aliceAccount = alice;

        // Authorize our mock engine to lock and settle funds.
        clearinghouse.setEngine(engine);
        mockEngine.setOrderRouter(address(mockRouter));

        // Fund Alice
        settlementToken.mint(alice, 5000 * 1e6); // $5k settlementToken

        vm.startPrank(alice);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6); // $5k settlementToken

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerAssets(aliceAccount);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceAccount, 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceAccount, 1000 * 1e6);

        assertEq(settlementToken.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityAssets(aliceAccount),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerAssets(aliceAccount);
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
            clearinghouse.getFreeBuyingPowerAssets(aliceAccount), 800 * 1e6, "free buying power should remain exposed"
        );
    }

    function test_GetAccountAssetBuckets_SplitsTypedLockedMarginBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 300 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);

        assertEq(buckets.settlementBalanceAssets, 2000 * 1e6);
        assertEq(buckets.totalLockedMarginAssets, 900 * 1e6);
        assertEq(buckets.activePositionMarginAssets, 600 * 1e6);
        assertEq(buckets.otherLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.freeSettlementAssets, 1100 * 1e6);
    }

    function test_GetPnlIsolationBuckets_ReportsFourIndependentLocks() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);
        clearinghouse.reclassifyPnlPledgeToLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 150 * 1e6);
        clearinghouse.lockReservedSettlement(aliceAccount, 50 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceAssets, 1000 * 1e6);
        assertEq(buckets.pnlPledgeAssets, 200 * 1e6);
        assertEq(buckets.liquidationReserveAssets, 100 * 1e6);
        assertEq(buckets.orderMarginAssets, 150 * 1e6);
        assertEq(buckets.actionReserveAssets, 50 * 1e6);
        assertEq(buckets.totalLockedAssets, 500 * 1e6);
        assertEq(buckets.freeSettlementAssets, 500 * 1e6);
    }

    function test_GetLockedMarginBuckets_ReturnsTypedBucketBreakdown() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 100 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);

        assertEq(buckets.positionMarginAssets, 200 * 1e6);
        assertEq(buckets.committedOrderMarginAssets, 100 * 1e6);
        assertEq(buckets.reservedSettlementAssets, 0);
        assertEq(buckets.totalLockedMarginAssets, 300 * 1e6);
    }

    function test_TerminalReservationRelease_DoesNotTouchPositionBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 400 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 1, 200 * 1e6);
        vm.stopPrank();
        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(1);

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        assertEq(
            buckets.positionMarginAssets, 400 * 1e6, "Unlocking committed order margin must not touch position margin"
        );
        assertEq(buckets.committedOrderMarginAssets, 0, "Committed order margin should unlock independently");
        assertEq(buckets.totalLockedMarginAssets, 400 * 1e6);
    }

    function test_ReserveCommittedOrderMargin_CheckpointsIndexedCarryDirectly() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 200 * 1e6);

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
        assertEq(reservation.originalAmountAssets, 200 * 1e6);
        assertEq(reservation.remainingAmountAssets, 200 * 1e6);
        assertEq(buckets.committedOrderMarginAssets, 200 * 1e6);
        assertEq(summary.activeCommittedOrderMarginAssets, 200 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_TerminalReservationRelease_ReleasesResidualAndMarksReleased() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 12, 180 * 1e6);

        vm.prank(address(mockRouter));
        uint256 releasedAssets = clearinghouse.releaseOrderReservationForTerminalCleanup(12);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(12);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(releasedAssets, 180 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountAssets, 0);
        assertEq(buckets.committedOrderMarginAssets, 0);
        assertEq(summary.activeCommittedOrderMarginAssets, 0);
        assertEq(summary.activeReservationCount, 0);
    }

    function test_TerminalReservationRelease_ClearsSummaryMetadata() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 14, 180 * 1e6);

        vm.prank(address(mockRouter));
        uint256 releasedAssets = clearinghouse.releaseOrderReservationForTerminalCleanup(14);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(14);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(releasedAssets, 180 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountAssets, 0);
        assertEq(buckets.committedOrderMarginAssets, 0);
        assertEq(summary.activeCommittedOrderMarginAssets, 0);
        assertEq(summary.activeReservationCount, 0);
    }

    function test_GenericReservedUnlockCheckpointsCarry() public {
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

        assertEq(clearinghouse.actionReserveAssets(aliceAccount), 0);
    }

    // Defense-in-depth: these malformed clearinghouse indexes cannot be created through production entrypoints.
    function _setupActionChargeReservations() private returns (address bob) {
        bob = address(0x222);
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 220e6);
        settlementToken.mint(bob, 100e6);
        vm.startPrank(bob);
        settlementToken.approve(address(clearinghouse), 100e6);
        clearinghouse.deposit(bob, 100e6);
        vm.stopPrank();
        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 1, 100e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 2, 100e6);
        clearinghouse.lockReservedSettlement(aliceAccount, 20e6);
        clearinghouse.reserveCommittedOrderMargin(bob, 3, 100e6);
        vm.stopPrank();
    }

    function _actionChargeState(
        address bob
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                clearinghouse.getAccountAssetBuckets(aliceAccount),
                clearinghouse.getAccountAssetBuckets(bob),
                clearinghouse.getAccountReservationSummary(aliceAccount),
                clearinghouse.getAccountReservationSummary(bob),
                clearinghouse.getOrderReservation(1),
                clearinghouse.getOrderReservation(2),
                clearinghouse.getOrderReservation(3),
                clearinghouse.balanceAssets(address(0xFEE)),
                settlementToken.balanceOf(address(clearinghouse)),
                settlementToken.balanceOf(engine)
            )
        );
    }

    function test_ConsumeActionCharge_RejectsForeignActiveReservation() public {
        address bob = _setupActionChargeReservations();
        uint64[] memory ids = new uint64[](1);
        ids[0] = 3;
        ClearinghouseReservationIndexHarness(address(clearinghouse)).setMarginReservationIds(aliceAccount, ids);
        bytes32 beforeState = _actionChargeState(bob);
        vm.prank(engine);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginClearinghouse.MarginClearinghouse__ReservationAccountMismatch.selector,
                uint64(3),
                aliceAccount,
                bob
            )
        );
        clearinghouse.consumeActionCharge(aliceAccount, 70e6, 20e6, 50e6, engine, address(0xFEE), 10e6);
        assertEq(_actionChargeState(bob), beforeState, "Foreign reservation rejection must leave all accounting intact");
    }

    function test_ConsumeActionCharge_ForeignReservationRollsBackEarlierConsumption() public {
        address bob = _setupActionChargeReservations();
        uint64[] memory ids = new uint64[](2);
        ids[0] = 1;
        ids[1] = 3;
        ClearinghouseReservationIndexHarness(address(clearinghouse)).setMarginReservationIds(aliceAccount, ids);
        bytes32 beforeState = _actionChargeState(bob);
        vm.prank(engine);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginClearinghouse.MarginClearinghouse__ReservationAccountMismatch.selector,
                uint64(3),
                aliceAccount,
                bob
            )
        );
        clearinghouse.consumeActionCharge(aliceAccount, 170e6, 20e6, 150e6, engine, address(0xFEE), 10e6);
        assertEq(_actionChargeState(bob), beforeState, "Earlier reserve and reservation mutations must roll back");
    }

    function test_ConsumeActionCharge_SkipsUnknownConsumedAndForeignReleasedReservations() public {
        address bob = _setupActionChargeReservations();
        vm.prank(engine);
        clearinghouse.consumeActionCharge(aliceAccount, 120e6, 20e6, 100e6, engine, address(0), 0);
        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(3);
        uint64[] memory ids = new uint64[](4);
        ids[0] = 999;
        ids[1] = 1;
        ids[2] = 3;
        ids[3] = 2;
        ClearinghouseReservationIndexHarness(address(clearinghouse)).setMarginReservationIds(aliceAccount, ids);
        vm.prank(engine);
        (uint256 collected,) = clearinghouse.consumeActionCharge(aliceAccount, 50e6, 0, 50e6, engine, address(0), 0);
        assertEq(collected, 50e6);
        assertEq(clearinghouse.getOrderReservation(2).remainingAmountAssets, 50e6);
        assertEq(clearinghouse.balanceAssets(aliceAccount), 50e6);
        assertEq(clearinghouse.orderMarginAssets(aliceAccount), 50e6);
        assertEq(clearinghouse.balanceAssets(bob), 100e6);
    }

    function test_ConsumeActionCharge_IncompleteCoverageRollsBack() public {
        address bob = _setupActionChargeReservations();
        uint64[] memory ids = new uint64[](1);
        ids[0] = 1;
        ClearinghouseReservationIndexHarness(address(clearinghouse)).setMarginReservationIds(aliceAccount, ids);
        bytes32 beforeState = _actionChargeState(bob);
        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__IncompleteReservationCoverage.selector);
        clearinghouse.consumeActionCharge(aliceAccount, 170e6, 20e6, 150e6, engine, address(0xFEE), 10e6);
        assertEq(_actionChargeState(bob), beforeState);
    }

    function test_ConsumeActionCharge_ZeroChargeDoesNotConsumeMalformedIndex() public {
        address bob = _setupActionChargeReservations();
        uint64[] memory ids = new uint64[](1);
        ids[0] = 3;
        ClearinghouseReservationIndexHarness(address(clearinghouse)).setMarginReservationIds(aliceAccount, ids);
        bytes32 beforeState = _actionChargeState(bob);
        vm.prank(engine);
        (uint256 collected, uint256 credited) =
            clearinghouse.consumeActionCharge(aliceAccount, 0, 0, 0, engine, address(0), 0);
        assertEq(collected, 0);
        assertEq(credited, 0);
        assertEq(_actionChargeState(bob), beforeState);
    }

    function test_ConsumeActionCharge_RejectsTraderAndRouter() public {
        address bob = _setupActionChargeReservations();
        bytes32 beforeState = _actionChargeState(bob);
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.consumeActionCharge(aliceAccount, 20e6, 20e6, 0, engine, address(0), 0);
        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.consumeActionCharge(aliceAccount, 20e6, 20e6, 0, engine, address(0), 0);
        assertEq(_actionChargeState(bob), beforeState);
    }

    function test_ConsumeActionCharge_ConsumesActiveReservationsInFifoOrder() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 220 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 21, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 22, 120 * 1e6);
        (uint256 consumedAssets,) =
            clearinghouse.consumeActionCharge(aliceAccount, 150 * 1e6, 0, 150 * 1e6, engine, address(0), 0);
        vm.stopPrank();

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(21);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(22);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);

        assertEq(consumedAssets, 150 * 1e6);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(first.remainingAmountAssets, 0);
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(second.remainingAmountAssets, 70 * 1e6);
        assertEq(buckets.committedOrderMarginAssets, 70 * 1e6);
        assertEq(summary.activeCommittedOrderMarginAssets, 70 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_TerminalReservationRelease_ClearsTerminalReservationsWithoutHistoricalHeadTracking() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 71, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 72, 120 * 1e6);
        vm.stopPrank();
        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(71);

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(71);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Released));

        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(72);

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
            clearinghouse.lockedMarginAssets(aliceAccount),
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
        uint256 releasedAssets = clearinghouse.releaseOrderReservationForTerminalCleanup(99);
        vm.stopPrank();

        assertEq(releasedAssets, 200 * 1e6, "router should release its own active reservation");
        assertEq(
            clearinghouse.getLockedMarginBuckets(aliceAccount).reservedSettlementAssets,
            100 * 1e6,
            "router should still be able to reserve execution-bounty settlement"
        );

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.settleAssets(aliceAccount, int256(1e6));

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.transferReservedSettlement(aliceAccount, address(0xB0B), 1);
    }

    function test_ReleaseInvalidatedOrderReserves_AuthorizesOnlyReportedRouter() public {
        uint64[] memory orderIds = new uint64[](0);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 0);

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 0);
    }

    function test_ReleaseInvalidatedOrderReserves_UnknownIdsAndZeroBountyAreEventfulNoop() public {
        uint64[] memory orderIds = new uint64[](2);
        orderIds[0] = 1001;
        orderIds[1] = 1002;
        vm.mockCallRevert(
            address(mockRouter),
            abi.encodeWithSignature("getAccountReservations(address)", aliceAccount),
            "router must not be consulted"
        );
        uint256 checkpointCallsBefore = mockEngine.carryCheckpointCalls();

        vm.expectEmit(true, false, false, true, address(clearinghouse));
        emit RiskOffOrderReservesRefunded(aliceAccount, 0, 0);
        vm.prank(address(mockRouter));
        uint256 releasedMarginAssets = clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 0);

        assertEq(releasedMarginAssets, 0);
        assertEq(clearinghouse.balanceAssets(aliceAccount), 0);
        assertEq(clearinghouse.lockedMarginAssets(aliceAccount), 0);
        assertEq(mockEngine.carryCheckpointCalls(), checkpointCallsBefore, "risk-off no-op must not checkpoint carry");
    }

    function test_ReleaseInvalidatedOrderReserves_ReleasesRemainingMatchingReservationsAndExactBounty() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 101, 200 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 102, 150 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 103, 50 * 1e6);
        clearinghouse.consumeActionCharge(aliceAccount, 560 * 1e6, 0, 60 * 1e6, engine, address(0), 0);
        vm.stopPrank();
        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(103);
        // Restore the charged custody so this test isolates the subsequent risk-off release.
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 560 * 1e6);

        vm.prank(address(mockRouter));
        clearinghouse.lockReservedSettlement(aliceAccount, 75 * 1e6);
        mockRouter.setExecutionBountyAssets(aliceAccount, 0);

        uint64[] memory orderIds = new uint64[](6);
        orderIds[0] = 101;
        orderIds[1] = 999;
        orderIds[2] = 103;
        orderIds[3] = 102;
        orderIds[4] = 101;
        orderIds[5] = 1000;

        uint256 settlementBalanceBefore = clearinghouse.balanceAssets(aliceAccount);
        uint256 clearinghouseTokensBefore = settlementToken.balanceOf(address(clearinghouse));
        uint256 checkpointCallsBefore = mockEngine.carryCheckpointCalls();

        vm.prank(address(mockRouter));
        uint256 releasedMarginAssets = clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 75 * 1e6);

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceAccount);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceAccount);
        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(101);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(102);
        IMarginClearinghouse.OrderReservation memory alreadyTerminal = clearinghouse.getOrderReservation(103);

        assertEq(releasedMarginAssets, 290 * 1e6, "only the two active reservation remainders should release");
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(uint256(alreadyTerminal.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(buckets.positionMarginAssets, 100 * 1e6, "PnL pledge must remain isolated");
        assertEq(buckets.committedOrderMarginAssets, 0);
        assertEq(buckets.reservedSettlementAssets, 0, "the exact invalidated bounty should unlock");
        assertEq(summary.activeCommittedOrderMarginAssets, 0);
        assertEq(summary.activeReservationCount, 0);
        assertEq(clearinghouse.balanceAssets(aliceAccount), settlementBalanceBefore, "settlement balance must not move");
        assertEq(
            settlementToken.balanceOf(address(clearinghouse)), clearinghouseTokensBefore, "token custody must not move"
        );
        assertEq(mockEngine.carryCheckpointCalls(), checkpointCallsBefore, "risk-off refund must not checkpoint carry");
    }

    function test_ReleaseInvalidatedOrderReserves_RevertsAndRollsBackOnReservationAccountMismatch() public {
        address bob = address(0x222);
        settlementToken.mint(bob, 500 * 1e6);
        vm.startPrank(bob);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bob, 500 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 500 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 201, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(bob, 202, 120 * 1e6);
        vm.stopPrank();

        uint64[] memory orderIds = new uint64[](2);
        orderIds[0] = 201;
        orderIds[1] = 202;

        vm.prank(address(mockRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginClearinghouse.MarginClearinghouse__ReservationAccountMismatch.selector,
                uint64(202),
                aliceAccount,
                bob
            )
        );
        clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 0);

        assertEq(
            uint256(clearinghouse.getOrderReservation(201).status),
            uint256(IMarginClearinghouse.ReservationStatus.Active),
            "an earlier matching release must roll back"
        );
        assertEq(clearinghouse.getLockedMarginBuckets(aliceAccount).committedOrderMarginAssets, 100 * 1e6);
    }

    function test_ReleaseInvalidatedOrderReserves_RejectsTerminalReservationOwnedByAnotherAccount() public {
        address bob = address(0x222);
        settlementToken.mint(bob, 500 * 1e6);
        vm.startPrank(bob);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bob, 500 * 1e6);
        vm.stopPrank();

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(bob, 211, 120 * 1e6);
        vm.stopPrank();
        vm.prank(address(mockRouter));
        clearinghouse.releaseOrderReservationForTerminalCleanup(211);

        uint64[] memory orderIds = new uint64[](1);
        orderIds[0] = 211;

        vm.prank(address(mockRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginClearinghouse.MarginClearinghouse__ReservationAccountMismatch.selector,
                uint64(211),
                aliceAccount,
                bob
            )
        );
        clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 0);
    }

    function test_ReleaseInvalidatedOrderReserves_ProtectsVpiAndRemainingLiveBounties() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockVpiRebateReserve(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 221, 40 * 1e6);
        vm.stopPrank();
        vm.prank(address(mockRouter));
        clearinghouse.lockReservedSettlement(aliceAccount, 70 * 1e6);
        mockRouter.setExecutionBountyAssets(aliceAccount, 50 * 1e6);

        uint64[] memory orderIds = new uint64[](1);
        orderIds[0] = 221;
        uint256 checkpointCallsBefore = mockEngine.carryCheckpointCalls();

        vm.prank(address(mockRouter));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ActionReserveMismatch.selector);
        clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 21 * 1e6);

        assertEq(clearinghouse.actionReserveAssets(aliceAccount), 170 * 1e6, "failed floor check must roll back");
        assertEq(clearinghouse.vpiRebateReserveAssets(aliceAccount), 100 * 1e6);
        assertEq(
            uint256(clearinghouse.getOrderReservation(221).status),
            uint256(IMarginClearinghouse.ReservationStatus.Active),
            "reservation release must roll back with the floor rejection"
        );
        assertEq(clearinghouse.orderMarginAssets(aliceAccount), 40 * 1e6);
        assertEq(mockEngine.carryCheckpointCalls(), checkpointCallsBefore, "floor rejection must not checkpoint carry");

        vm.prank(address(mockRouter));
        uint256 releasedMarginAssets = clearinghouse.releaseInvalidatedOrderReserves(aliceAccount, orderIds, 20 * 1e6);

        assertEq(releasedMarginAssets, 40 * 1e6);
        assertEq(clearinghouse.actionReserveAssets(aliceAccount), 150 * 1e6, "exact protected floor should remain");
        assertEq(clearinghouse.vpiRebateReserveAssets(aliceAccount), 100 * 1e6);
        assertEq(clearinghouse.orderMarginAssets(aliceAccount), 0);
        assertEq(
            mockEngine.carryCheckpointCalls(), checkpointCallsBefore, "successful refund must not checkpoint carry"
        );
    }

    function test_WithdrawAssetsBelowLockedMargin_ShouldRevert() public {
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
            clearinghouse.consumeSettlementLoss(aliceAccount, 1200 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);
        assertEq(freeConsumed, 600 * 1e6);
        assertEq(marginConsumed, 600 * 1e6, "Canonical stored margin overrides the legacy zero hint");
        assertEq(uncovered, 0);
        assertEq(buckets.settlementBalanceAssets, 800 * 1e6);
        assertEq(buckets.totalLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.activePositionMarginAssets, 0);
        assertEq(buckets.otherLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.freeSettlementAssets, 500 * 1e6);
    }

    function test_ConsumeSettlementLoss_ReturnsUncoveredWhenFreeAndActiveMarginInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 61, 300 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeSettlementLoss(aliceAccount, 2000 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(61);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 600 * 1e6);
        assertEq(uncovered, 300 * 1e6, "Only unrelated locked margin remains protected");
        assertEq(buckets.settlementBalanceAssets, 300 * 1e6);
        assertEq(buckets.totalLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.activePositionMarginAssets, 0);
        assertEq(buckets.otherLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.freeSettlementAssets, 0);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountAssets, 300 * 1e6);
    }

    function test_ConsumeLiquidationResidual_RejectsOrderMarginConsumption() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 41, 300 * 1e6);
        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementSeizedAssets: 1800 * 1e6,
            positionMarginUnlockedAssets: 600 * 1e6,
            otherLockedMarginUnlockedAssets: 100 * 1e6
        });
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidMarginBucket.selector);
        clearinghouse.applyLiquidationSettlementPlan(aliceAccount, plan, engine, address(0), 0, address(0), 0, 0);
        vm.stopPrank();
    }

    function test_ConsumePnlPledgeLoss_ConsumesOnlyPnlPledge() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 31, 300 * 1e6);
        (uint256 seizedAssets, uint256 shortfallAssets) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 1800 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);
        assertEq(seizedAssets, 600 * 1e6);
        assertEq(shortfallAssets, 1200 * 1e6);
        assertEq(buckets.settlementBalanceAssets, 1400 * 1e6);
        assertEq(buckets.totalLockedMarginAssets, 300 * 1e6);
        assertEq(buckets.freeSettlementAssets, 1100 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountAssets, 300 * 1e6);
    }

    function test_ConsumePnlPledgeLoss_DoesNotRequireReservationIds() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 300 * 1e6);
        (uint256 seizedAssets, uint256 shortfallAssets) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 1800 * 1e6, engine);
        vm.stopPrank();

        assertEq(seizedAssets, 600 * 1e6);
        assertEq(shortfallAssets, 1200 * 1e6);
        assertEq(clearinghouse.orderMarginAssets(aliceAccount), 300 * 1e6);
    }

    function test_ConsumePnlPledgeLoss_LeavesAggregateOrderMarginUntouched() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 300 * 1e6);
        (uint256 seizedAssets, uint256 shortfallAssets) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 1500 * 1e6, engine);
        vm.stopPrank();

        assertEq(seizedAssets, 600 * 1e6);
        assertEq(shortfallAssets, 900 * 1e6);
        assertEq(clearinghouse.orderMarginAssets(aliceAccount), 300 * 1e6);
    }

    function test_CreditPnlPledge_CreditsCustodyClassificationWithoutIncreasingFreeSettlement() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditPnlPledge(aliceAccount, 200 * 1e6);

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceAssets, 1200 * 1e6);
        assertEq(buckets.pnlPledgeAssets, 200 * 1e6);
        assertEq(buckets.freeSettlementAssets, 1000 * 1e6);
    }

    function test_ConsumePnlPledgeLoss_ProtectsFreeAndEveryReserveBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 200 * 1e6);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);
        clearinghouse.reclassifyPnlPledgeToLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 100 * 1e6);
        clearinghouse.lockReservedSettlement(aliceAccount, 100 * 1e6);
        (uint256 consumedAssets, uint256 shortfallAssets) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 350 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(consumedAssets, 200 * 1e6);
        assertEq(shortfallAssets, 150 * 1e6);
        assertEq(buckets.settlementBalanceAssets, 800 * 1e6);
        assertEq(buckets.pnlPledgeAssets, 0);
        assertEq(buckets.liquidationReserveAssets, 100 * 1e6);
        assertEq(buckets.orderMarginAssets, 100 * 1e6);
        assertEq(buckets.actionReserveAssets, 100 * 1e6);
        assertEq(buckets.freeSettlementAssets, 500 * 1e6);
    }

    function test_ConsumeActionCharge_UsesSpendableReserveThenFreeAndPreservesRouterBounty() public {
        address recipient = address(0x5001);
        address protocolTreasury = address(0xFEE5);
        address keeper = address(0xB0A7);

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 1200 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 300 * 1e6);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);
        clearinghouse.reclassifyPnlPledgeToLiquidationReserve(aliceAccount, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, 100 * 1e6);
        clearinghouse.lockReservedSettlement(aliceAccount, 350 * 1e6);
        mockRouter.setExecutionBountyAssets(aliceAccount, 150 * 1e6);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ActionReserveMismatch.selector);
        clearinghouse.consumeActionCharge(aliceAccount, 450 * 1e6, 350 * 1e6, 0, recipient, protocolTreasury, 50 * 1e6);

        (uint256 collectedAssets, uint256 protocolFeeCreditedAssets) = clearinghouse.consumeActionCharge(
            aliceAccount, 450 * 1e6, 200 * 1e6, 0, recipient, protocolTreasury, 50 * 1e6
        );

        IMarginClearinghouse.PnlIsolationBuckets memory beforeBountyPayment =
            clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(beforeBountyPayment.actionReserveAssets, 150 * 1e6);

        mockRouter.setExecutionBountyAssets(aliceAccount, 0);
        clearinghouse.transferReservedSettlement(aliceAccount, keeper, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(collectedAssets, 450 * 1e6);
        assertEq(protocolFeeCreditedAssets, 50 * 1e6);
        assertEq(buckets.settlementBalanceAssets, 600 * 1e6);
        assertEq(buckets.pnlPledgeAssets, 300 * 1e6);
        assertEq(buckets.liquidationReserveAssets, 100 * 1e6);
        assertEq(buckets.orderMarginAssets, 100 * 1e6);
        assertEq(buckets.actionReserveAssets, 0);
        assertEq(buckets.freeSettlementAssets, 100 * 1e6);
        assertEq(clearinghouse.balanceAssets(protocolTreasury), 50 * 1e6);
        assertEq(clearinghouse.balanceAssets(keeper), 150 * 1e6);
        assertEq(settlementToken.balanceOf(recipient), 400 * 1e6);
    }

    function test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.prank(engine);
        (int256 netMarginChangeAssets, uint256 protocolFeeCreditedAssets) =
            clearinghouse.applyOpenCost(aliceAccount, 300 * 1e6, int256(200 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);
        assertEq(netMarginChangeAssets, 100 * 1e6);
        assertEq(buckets.settlementBalanceAssets, 1800 * 1e6);
        assertEq(buckets.totalLockedMarginAssets, 100 * 1e6);
        assertEq(buckets.freeSettlementAssets, 1700 * 1e6);
    }

    function test_ApplyOpenCost_DoesNotUnlockExistingPnlPledgeForTradeCost() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 100 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 100 * 1e6);

        assertEq(
            clearinghouse.getAccountAssetBuckets(aliceAccount).freeSettlementAssets,
            0,
            "setup must start with zero free settlement"
        );

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.applyOpenCost(aliceAccount, 0, int256(20 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(aliceAccount);
        assertEq(buckets.settlementBalanceAssets, 100 * 1e6);
        assertEq(buckets.activePositionMarginAssets, 100 * 1e6);
        assertEq(buckets.freeSettlementAssets, 0);
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
        (int256 netMarginChangeAssets,) =
            clearinghouse.applyOpenCost(aliceAccount, 200 * 1e6, -int256(50 * 1e6), engine, address(0), 0);

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(netMarginChangeAssets, int256(200 * 1e6));
        assertEq(buckets.settlementBalanceAssets, 350 * 1e6);
        assertEq(buckets.pnlPledgeAssets, 200 * 1e6);
        assertEq(buckets.freeSettlementAssets, 150 * 1e6, "Rebate must not auto-increase PnL pledge");
    }

    function testFuzz_ApplyOpenCost_MatchesSharedOpenPlan(
        uint256 settlementBalanceAssets,
        uint256 positionMarginAssets,
        uint256 committedOrderMarginAssets,
        uint256 reservedSettlementAssets,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets
    ) public {
        settlementBalanceAssets = bound(settlementBalanceAssets, 1, 5000e6);
        positionMarginAssets = bound(positionMarginAssets, 0, settlementBalanceAssets);
        uint256 remainingAfterPosition = settlementBalanceAssets - positionMarginAssets;
        committedOrderMarginAssets = bound(committedOrderMarginAssets, 0, remainingAfterPosition);
        uint256 remainingAfterCommitted = remainingAfterPosition - committedOrderMarginAssets;
        reservedSettlementAssets = bound(reservedSettlementAssets, 0, remainingAfterCommitted);
        marginDeltaAssets = bound(marginDeltaAssets, 0, 5000e6);
        tradeCostAssets = int256(bound(tradeCostAssets, -5000e6, 5000e6));

        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, settlementBalanceAssets);

        vm.startPrank(engine);
        if (positionMarginAssets > 0) {
            clearinghouse.lockPositionMargin(aliceAccount, positionMarginAssets);
        }
        if (committedOrderMarginAssets > 0) {
            clearinghouse.reserveCommittedOrderMargin(aliceAccount, type(uint64).max, committedOrderMarginAssets);
        }
        if (reservedSettlementAssets > 0) {
            clearinghouse.lockReservedSettlement(aliceAccount, reservedSettlementAssets);
        }
        vm.stopPrank();

        IMarginClearinghouse.AccountAssetBuckets memory bucketsBefore =
            clearinghouse.getAccountAssetBuckets(aliceAccount);
        MarginClearinghouseAccountingLib.OpenCostPlan memory plan =
            accountingHarness.planOpenCostApplication(bucketsBefore, marginDeltaAssets, tradeCostAssets);

        vm.startPrank(engine);
        if (plan.insufficientFreeEquity) {
            vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
            clearinghouse.applyOpenCost(aliceAccount, marginDeltaAssets, tradeCostAssets, engine, address(0), 0);
        } else {
            (int256 netMarginChangeAssets, uint256 protocolFeeCreditedAssets) =
                clearinghouse.applyOpenCost(aliceAccount, marginDeltaAssets, tradeCostAssets, engine, address(0), 0);
            IMarginClearinghouse.AccountAssetBuckets memory bucketsAfter =
                clearinghouse.getAccountAssetBuckets(aliceAccount);
            assertEq(
                netMarginChangeAssets, plan.netMarginChangeAssets, "Live open-cost net margin change should match plan"
            );
            assertEq(
                bucketsAfter.settlementBalanceAssets,
                plan.resultingSettlementBalanceAssets,
                "Live settlement balance should match planned open-cost mutation"
            );
            assertEq(
                bucketsAfter.activePositionMarginAssets,
                plan.resultingPositionMarginAssets,
                "Live position margin should match planned open-cost mutation"
            );
            assertEq(
                bucketsAfter.freeSettlementAssets,
                plan.resultingFreeSettlementAssets,
                "Live free settlement should match planned open-cost mutation"
            );
        }
        vm.stopPrank();
    }

    function test_ConsumePnlPledgeLoss_LeavesFreeAndOrderMarginOutsideTerminalPriceLossCap() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 31, 300 * 1e6);
        vm.stopPrank();

        vm.prank(engine);
        (uint256 seizedAssets, uint256 shortfallAssets) =
            clearinghouse.consumePnlPledgeLoss(aliceAccount, 1800 * 1e6, engine);

        IMarginClearinghouse.AccountAssetBuckets memory bucketsAfter =
            clearinghouse.getAccountAssetBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);
        assertEq(seizedAssets, 600 * 1e6);
        assertEq(shortfallAssets, 1200 * 1e6);
        assertEq(bucketsAfter.settlementBalanceAssets, 1400 * 1e6);
        assertEq(bucketsAfter.activePositionMarginAssets, 0);
        assertEq(bucketsAfter.freeSettlementAssets, 1100 * 1e6);
        assertEq(reservation.remainingAmountAssets, 300 * 1e6);
    }

    function test_ApplyLiquidationSettlementPlan_ConsumesPnlPledgeWithoutTouchingOrderMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceAccount, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceAccount, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceAccount, 41, 300 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan =
            IMarginClearinghouse.LiquidationSettlementPlan({
                settlementSeizedAssets: 600 * 1e6,
                positionMarginUnlockedAssets: 600 * 1e6,
                otherLockedMarginUnlockedAssets: 0
            });

        vm.prank(engine);
        uint256 seizedAssets = clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, settlementPlan, engine, address(0), 0, address(0), 0, 0
        );

        IMarginClearinghouse.AccountAssetBuckets memory bucketsAfter =
            clearinghouse.getAccountAssetBuckets(aliceAccount);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(41);
        assertEq(seizedAssets, 600 * 1e6);
        assertEq(bucketsAfter.settlementBalanceAssets, 1400 * 1e6);
        assertEq(bucketsAfter.activePositionMarginAssets, 0, "Liquidation should unlock the full live position margin");
        assertEq(bucketsAfter.freeSettlementAssets, 1100 * 1e6);
        assertEq(reservation.remainingAmountAssets, 300 * 1e6);
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
        clearinghouse.lockPositionMargin(aliceAccount, 250 * 1e6);
        clearinghouse.reclassifyPnlPledgeToLiquidationReserve(aliceAccount, 250 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementSeizedAssets: 600 * 1e6,
            positionMarginUnlockedAssets: 600 * 1e6,
            otherLockedMarginUnlockedAssets: 0
        });

        vm.prank(engine);
        uint256 seizedAssets = clearinghouse.applyLiquidationSettlementPlan(
            aliceAccount, plan, poolRecipient, keeper, 100 * 1e6, protocolTreasury, 50 * 1e6, 50 * 1e6
        );

        assertEq(seizedAssets, 600 * 1e6, "Only the pool allocation should be returned as seized cash");
        assertEq(clearinghouse.balanceAssets(aliceAccount), 250 * 1e6, "Source debit should include all allocations");
        assertEq(clearinghouse.balanceAssets(keeper), 100 * 1e6, "Keeper should receive its internal credit");
        assertEq(
            clearinghouse.balanceAssets(protocolTreasury),
            50 * 1e6,
            "Protocol treasury should receive its internal credit"
        );
        assertEq(
            settlementToken.balanceOf(poolRecipient),
            600 * 1e6,
            "Only the pool allocation should leave clearinghouse custody"
        );
        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(aliceAccount);
        assertEq(buckets.pnlPledgeAssets, 0, "Unused PnL pledge should become free after full liquidation");
        assertEq(buckets.liquidationReserveAssets, 0, "Unused liquidation reserve should become free");
        assertEq(buckets.freeSettlementAssets, 250 * 1e6);
    }

}

contract MarginClearinghouseAccountHealthTest is BasePerpTest {

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
            minBountyAssets: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Position should be open");

        uint256 freeBalance = clearinghouse.balanceAssets(account) - clearinghouse.lockedMarginAssets(account);
        assertGt(freeBalance, 0, "Alice should have free balance");

        uint256 balBefore = settlementToken.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(account, freeBalance);
        assertEq(settlementToken.balanceOf(alice), balBefore + freeBalance, "Free equity withdrawn");
    }

    function test_WithdrawAllowedAfterClose() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 0, 1e8, true);
        router.executeOrder(2, _mockPythUpdateData());

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be closed");

        uint256 balance = clearinghouse.balanceAssets(account);
        vm.prank(alice);
        clearinghouse.withdraw(account, balance);
        assertEq(settlementToken.balanceOf(alice), balance, "Alice should receive her settlementToken");
    }

    function test_Withdraw_UsesEngineGuardParityForOpenPositions() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        WithdrawParityState memory state = _observeWithdrawParity(account, alice, 5000e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_Withdraw_FailsConsistentlyWhenGuardWouldFailOnStaleMark() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        address account = alice;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, false);
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
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 1600e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        WithdrawParityState memory state = _observeWithdrawParity(account, alice, 80e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

}

contract NonAssetsCollateralTest is Test {

    MockToken settlementToken;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        settlementToken = new MockToken("Mock Settlement Token", "SETTLEMENT", 6);

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        clearinghouse = new MarginClearinghouse(address(settlementToken));
        engine = new CfdEngine(address(settlementToken), address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(settlementToken), address(engine), address(new HousePoolRedemptionMathSidecar()));
        TrancheVault seniorVault = new TrancheVault(
            IERC20(address(settlementToken)), address(pool), true, "Senior LP", "seniorAssets", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(settlementToken)), address(pool), false, "Junior LP", "juniorAssets", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        vm.warp(1_709_532_000);

        settlementToken.mint(address(this), 10_000_000 * 1e6);
        settlementToken.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        settlementToken.approve(address(juniorVault), type(uint256).max);
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
        settlementToken.mint(user, amount);
        vm.startPrank(user);
        settlementToken.approve(address(clearinghouse), amount);
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

}
