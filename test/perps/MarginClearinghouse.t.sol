// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    function setOrderRouter(
        address router
    ) external {
        orderRouter = router;
    }

    function checkWithdraw(
        bytes32
    ) external pure {}

    function syncFunding() external {}

}

contract MarginClearinghouseTest is Test {

    MarginClearinghouse clearinghouse;
    MockToken usdc;
    MockClearinghouseEngine mockEngine;

    address alice = address(0x111);
    address engine;
    bytes32 aliceId;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        mockEngine = new MockClearinghouseEngine();
        engine = address(mockEngine);

        clearinghouse = new MarginClearinghouse(address(usdc));
        aliceId = bytes32(uint256(uint160(alice)));

        // Authorize our mock Engine to lock/seize funds
        clearinghouse.setEngine(engine);

        // Fund Alice
        usdc.mint(alice, 5000 * 1e6); // $5k USDC

        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6); // $5k USDC

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceId, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceId, 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, 1000 * 1e6);

        assertEq(usdc.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityUsdc(aliceId),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceId, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 500 * 1e6, "Free BP should be $500");

        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceId, 1000 * 1e6);
    }

    function test_GetAccountUsdcBuckets_SplitsTypedLockedMarginBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 300 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);

        assertEq(buckets.settlementBalanceUsdc, 2000 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1100 * 1e6);
    }

    function test_GetLockedMarginBuckets_ReturnsTypedBucketBreakdown() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 200 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 100 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);

        assertEq(buckets.positionMarginUsdc, 200 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 100 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 0);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
    }

    function test_UnlockCommittedOrderMargin_DoesNotTouchPositionBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 400 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 200 * 1e6);
        clearinghouse.unlockCommittedOrderMargin(aliceId, 200 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);
        assertEq(
            buckets.positionMarginUsdc, 400 * 1e6, "Unlocking committed order margin must not touch position margin"
        );
        assertEq(buckets.committedOrderMarginUsdc, 0, "Committed order margin should unlock independently");
        assertEq(buckets.totalLockedMarginUsdc, 400 * 1e6);
    }

    function test_ReserveCommittedOrderMargin_CreatesReservationAndMatchesBucketTotals() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 11, 200 * 1e6);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(11);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceId);

        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.accountId, aliceId);
        assertEq(uint256(reservation.bucket), uint256(IMarginClearinghouse.ReservationBucket.CommittedOrder));
        assertEq(reservation.originalAmountUsdc, 200 * 1e6);
        assertEq(reservation.remainingAmountUsdc, 200 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 200 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 200 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_ReleaseOrderReservation_ReleasesResidualAndMarksReleased() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 12, 180 * 1e6);

        vm.prank(engine);
        uint256 releasedUsdc = clearinghouse.releaseOrderReservation(12);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(12);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceId);

        assertEq(releasedUsdc, 180 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountUsdc, 0);
        assertEq(buckets.committedOrderMarginUsdc, 0);
        assertEq(summary.activeCommittedOrderMarginUsdc, 0);
        assertEq(summary.activeReservationCount, 0);
    }

    function test_ConsumeOrderReservation_ReducesResidualAndKeepsAggregateParity() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 13, 220 * 1e6);

        vm.prank(engine);
        uint256 consumedUsdc = clearinghouse.consumeOrderReservation(13, 70 * 1e6);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(13);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceId);

        assertEq(consumedUsdc, 70 * 1e6);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 150 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 150 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 150 * 1e6);
        assertEq(summary.activeReservationCount, 1);
    }

    function test_ConsumeAccountOrderReservations_ConsumesActiveReservationsInFifoOrder() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 21, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 22, 120 * 1e6);
        uint256 consumedUsdc = clearinghouse.consumeAccountOrderReservations(aliceId, 150 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.OrderReservation memory first = clearinghouse.getOrderReservation(21);
        IMarginClearinghouse.OrderReservation memory second = clearinghouse.getOrderReservation(22);
        IMarginClearinghouse.LockedMarginBuckets memory buckets = clearinghouse.getLockedMarginBuckets(aliceId);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(aliceId);

        assertEq(consumedUsdc, 150 * 1e6);
        assertEq(uint256(first.status), uint256(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(first.remainingAmountUsdc, 0);
        assertEq(uint256(second.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(second.remainingAmountUsdc, 70 * 1e6);
        assertEq(buckets.committedOrderMarginUsdc, 70 * 1e6);
        assertEq(summary.activeCommittedOrderMarginUsdc, 70 * 1e6);
        assertEq(summary.activeReservationCount, 1);
        assertEq(
            clearinghouse.reservationHeadIndex(aliceId), 1, "Head index should advance past terminal reservation prefix"
        );
    }

    function test_ConsumeOrderReservationsById_UsesSuppliedReservationOrder() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 51, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 52, 120 * 1e6);
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
        assertEq(
            clearinghouse.reservationHeadIndex(aliceId),
            0,
            "Out-of-order explicit consumption must not advance the FIFO head index past an active prefix"
        );
    }

    function test_ReleaseOrderReservation_AdvancesHeadIndexAcrossTerminalPrefix() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 71, 100 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 72, 120 * 1e6);
        clearinghouse.releaseOrderReservation(71);
        vm.stopPrank();

        assertEq(clearinghouse.reservationHeadIndex(aliceId), 1, "Head index should skip released prefix reservations");

        vm.prank(engine);
        clearinghouse.releaseOrderReservation(72);

        assertEq(
            clearinghouse.reservationHeadIndex(aliceId),
            2,
            "Head index should advance to array end once all reservations are terminal"
        );
    }

    function test_Withdraw_WrongOwner_Reverts() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        address bob = address(0x222);
        vm.prank(bob);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        clearinghouse.withdraw(aliceId, 500 * 1e6);
    }

    function test_UnlockPositionMargin_RevertsOnBucketUnderflow() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceId, 1000 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBucketMargin.selector);
        clearinghouse.unlockPositionMargin(aliceId, 2000 * 1e6);

        assertEq(
            clearinghouse.lockedMarginUsdc(aliceId),
            1000 * 1e6,
            "Bucketed lock should remain unchanged after failed over-unlock"
        );
    }

    function test_SeizeAsset_RecipientMustEqualOperator() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidSeizeRecipient.selector);
        clearinghouse.seizeUsdc(aliceId, 100 * 1e6, address(0xBEEF));
    }

    function test_C01_WithdrawUsdcBelowLockedMargin_ShouldRevert() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockPositionMargin(aliceId, 1000 * 1e6);

        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceId, 1000 * 1e6);
    }

    function test_ConsumeFundingLoss_PreservesOtherLockedBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.lockReservedSettlement(aliceId, 300 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 1200 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 100 * 1e6);
        assertEq(uncovered, 0);
        assertEq(buckets.settlementBalanceUsdc, 800 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 800 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 500 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeFundingLoss_ReturnsUncoveredWhenFreeAndActiveMarginInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 61, 300 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 2000 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(61);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 600 * 1e6);
        assertEq(uncovered, 300 * 1e6, "Funding loss planner should report residual uncovered loss");
        assertEq(buckets.settlementBalanceUsdc, 300 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 0);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 300 * 1e6);
    }

    function test_ConsumeLiquidationResidual_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 41, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 41;
        (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) =
            clearinghouse.consumeLiquidationResidual(aliceId, reservationIds, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(41);
        assertEq(seizedUsdc, 1800 * 1e6);
        assertEq(payoutUsdc, 0);
        assertEq(badDebtUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 200 * 1e6);
    }

    function test_ConsumeCloseLoss_ConsumesQueuedCommittedMarginBeforeShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.reserveCommittedOrderMargin(aliceId, 31, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](1);
        reservationIds[0] = 31;
        (uint256 seizedUsdc, uint256 shortfallUsdc) =
            clearinghouse.consumeCloseLoss(aliceId, reservationIds, 1800 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(31);
        assertEq(seizedUsdc, 1800 * 1e6);
        assertEq(shortfallUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6);
        assertEq(
            buckets.totalLockedMarginUsdc,
            200 * 1e6,
            "Close loss helper should keep only unconsumed queued margin locked"
        );
        assertEq(buckets.freeSettlementUsdc, 0);
        assertEq(uint256(reservation.status), uint256(IMarginClearinghouse.ReservationStatus.Active));
        assertEq(reservation.remainingAmountUsdc, 200 * 1e6);
    }

    function test_ConsumeCloseLoss_RevertsWhenReservationIdsDoNotCoverCommittedBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__IncompleteReservationCoverage.selector);
        clearinghouse.consumeCloseLoss(aliceId, reservationIds, 1800 * 1e6, 0, engine);
        vm.stopPrank();
    }

    function test_ConsumeCloseLoss_RevertsWhenCommittedBucketMissingFromReservationIdsEvenWithShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__IncompleteReservationCoverage.selector);
        clearinghouse.consumeCloseLoss(aliceId, reservationIds, 1500 * 1e6, 0, engine);
        vm.stopPrank();
    }

    function test_ConsumeLiquidationResidual_RevertsWhenReservationIdsDoNotCoverCommittedBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockPositionMargin(aliceId, 600 * 1e6);
        clearinghouse.lockCommittedOrderMargin(aliceId, 300 * 1e6);
        uint64[] memory reservationIds = new uint64[](0);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__IncompleteReservationCoverage.selector);
        clearinghouse.consumeLiquidationResidual(aliceId, reservationIds, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();
    }

    function test_CreditSettlementAndLockMargin_CreditsAndLocksSameBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditSettlementAndLockMargin(aliceId, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        assertEq(buckets.settlementBalanceUsdc, 1200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1000 * 1e6);
    }

    function test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.prank(engine);
        int256 netMarginChangeUsdc = clearinghouse.applyOpenCost(aliceId, 300 * 1e6, int256(200 * 1e6), engine);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId);
        assertEq(netMarginChangeUsdc, 100 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 1800 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1700 * 1e6);
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        clearinghouse.deposit(aliceId, 0);
    }

}

contract MarginClearinghouseAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
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

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 freeBalance = clearinghouse.balanceUsdc(accountId) - clearinghouse.lockedMarginUsdc(accountId);
        assertGt(freeBalance, 0, "Alice should have free balance");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeBalance);
        assertEq(usdc.balanceOf(alice), balBefore + freeBalance, "Free equity withdrawn");
    }

    // Regression: Finding-8 — withdraw allowed after position close
    function test_WithdrawAllowedAfterClose() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be closed");

        uint256 balance = clearinghouse.balanceUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, balance);
        assertEq(usdc.balanceOf(alice), balance, "Alice should receive her USDC");
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        vm.warp(1_709_532_000);

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(5_000_000 * 1e6, address(this));
    }

    function _deposit(
        bytes32 accountId,
        uint256 amount
    ) internal {
        address user = address(uint160(uint256(accountId)));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
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
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) external {
        _open(accountId, side, size, margin, price, depth);
    }

    // Regression: H-02 — non-USDC collateral blocks overleveraged position
    // Regression: H-02 — lockMargin accepts non-USDC equity


}
