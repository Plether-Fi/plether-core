// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CarryReferenceLedger} from "../../invariant/ghost/CarryReferenceLedger.sol";
import {CarryReferenceVectors} from "../../shared/CarryReferenceVectors.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract CarryReferenceArithmeticTest is Test {

    CarryReferenceLedger private referenceLedger;

    function setUp() public {
        referenceLedger = new CarryReferenceLedger(0, 0, 0);
    }

    function test_OfflineRationalVectorsMatchReferenceAndProduction() public view {
        CarryReferenceVectors.Vector[] memory vectors = CarryReferenceVectors.all();
        for (uint256 i; i < vectors.length; ++i) {
            CarryReferenceVectors.Vector memory v = vectors[i];
            assertEq(
                referenceLedger.utilization(v.sideBorrowBase, v.poolDepth),
                v.expectedUtilization,
                "reference utilization"
            );
            assertEq(
                referenceLedger.indexIncrement(v.sideBorrowBase, v.poolDepth, v.annualBps, v.elapsed) + v.storedIndex,
                v.expectedIndex,
                "reference index vs offline Fraction"
            );
            assertEq(
                referenceLedger.amountFromIndex(v.positionBorrowBase, v.expectedIndex - v.lastPositionIndex),
                v.expectedAmount,
                "reference assessment vs offline Fraction"
            );
            assertEq(
                PositionRiskAccountingLib.computeBorrowUtilizationBps(v.sideBorrowBase, v.poolDepth),
                v.expectedUtilization,
                "production utilization vs offline Fraction"
            );
            uint256 actualIndex = PositionRiskAccountingLib.computeCurrentCarryIndex(
                v.storedIndex, 0, v.elapsed, v.sideBorrowBase, v.poolDepth, v.annualBps
            );
            assertEq(actualIndex, v.expectedIndex, "production index vs offline Fraction");
            assertEq(
                PositionRiskAccountingLib.computeIndexedCarryUsdc(
                    v.positionBorrowBase, actualIndex - v.lastPositionIndex
                ),
                v.expectedAmount,
                "production assessment vs offline Fraction"
            );
        }
    }

    function testFuzz_RationalCarryAtGovernableRates(
        uint256 baseSeed,
        uint256 depthSeed,
        uint256 rateSeed,
        uint256 timeSeed,
        uint256 positionSeed
    ) public view {
        uint256 base = bound(baseSeed, 0, 1e24);
        uint256 depth = bound(depthSeed, 0, 2e24);
        uint256 rate = bound(rateSeed, 0, 100_000);
        uint256 elapsed = bound(timeSeed, 0, 250 * 365 days);
        uint256 positionBase = bound(positionSeed, 0, base);
        uint256 expectedIndex = referenceLedger.indexIncrement(base, depth, rate, elapsed);
        uint256 actualIndex = PositionRiskAccountingLib.computeCurrentCarryIndex(0, 0, elapsed, base, depth, rate);
        assertEq(actualIndex, expectedIndex, "independent reduced-rational index");
        assertEq(
            PositionRiskAccountingLib.computeIndexedCarryUsdc(positionBase, actualIndex),
            referenceLedger.amountFromIndex(positionBase, expectedIndex),
            "independent reduced-rational assessment"
        );
    }

    function test_CreditOrderingRetainsArrearsAndNeverSpendsProtectedFunds() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(90, 0, 10_000);
        address account = address(1);
        ledger.initializeAccount(account, 0, 100, 10, 3, 7, 0);
        CarryReferenceLedger.Collection memory first = ledger.checkpoint(account, 365 days);
        assertEq(first.newCarry, 90);
        assertEq(first.fromMargin, 10);
        assertEq(first.fromFree, 3);
        assertEq(first.unpaid, 77);

        ledger.creditFree(account, 5, 365 days);
        assertEq(ledger.accountState(account).arrears, 77, "bounty remains intact during its credit call");
        assertEq(ledger.accountState(account).free, 5);
        CarryReferenceLedger.Collection memory sameTime = ledger.checkpoint(account, 365 days);
        assertEq(sameTime.newCarry, 0, "elapsed time is not charged twice");
        assertEq(sameTime.unpaid, 72);

        ledger.deposit(account, 5, 365 days);
        assertEq(ledger.accountState(account).free, 0, "deposit can pay arrears immediately");
        assertEq(ledger.accountState(account).arrears, 67);
        ledger.creditClaim(account, 20, 20, 365 days);
        assertEq(ledger.accountState(account).pledge, 20, "claim becomes pledge without a second collection pass");
        assertEq(ledger.accountState(account).arrears, 67);
        ledger.checkpoint(account, 365 days);
        assertEq(ledger.accountState(account).arrears, 47);
        assertEq(ledger.accountState(account).protectedFunds, 7);
        assertEq(ledger.totalNewCarry(), ledger.totalCollected() + ledger.accountState(account).arrears);
    }

    function test_FlatClaimCreditIsFreeAndDepositDoesNotAdvanceOtherAccounts() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(1000, 0, 500);
        ledger.initializeAccount(address(1), 0, 100, 10, 0, 0, 0);
        ledger.initializeFlatAccount(address(2), 0, 0, 0);
        ledger.deposit(address(2), 20, 365 days);
        assertEq(ledger.sideState(0).timestamp, 0, "flat deposit does not checkpoint global clocks");
        ledger.creditClaim(address(2), 25, 25, 365 days);
        assertEq(ledger.accountState(address(2)).free, 45);
        assertEq(ledger.accountState(address(2)).pledge, 0);
        assertEq(ledger.sideState(0).timestamp, 365 days, "claim service does checkpoint global clocks");
    }

    function test_ChangingDepthBasisAndRateDoesNotRepriceOldTime() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(300e6, 0, 10_000);
        ledger.initializeAccount(address(1), 0, 100e6, 20e6, 10e6, 2e6, 0);
        ledger.initializeAccount(address(2), 1, 200e6, 50e6, 10e6, 2e6, 0);
        ledger.checkpoint(address(1), 365 days);
        assertEq(ledger.sideState(0).index, 0.2666e18);
        assertEq(ledger.sideState(1).index, 0.5e18, "both sides use old depth before collection");
        assertEq(ledger.accountState(address(1)).free, 8_672_000);
        assertEq(ledger.poolDepth(), 321_328_000);

        ledger.changeDepth(600e6, 365 days);
        ledger.addMargin(address(1), 5e6, 365 days);
        ledger.changeRate(500, 365 days);
        ledger.advance(2 * 365 days);
        assertEq(ledger.sideState(0).index, 0.274515e18);
        assertEq(ledger.sideState(1).index, 0.5125e18);
        assertEq(ledger.accountState(address(1)).borrowBase, 95e6);
        assertEq(ledger.accountState(address(2)).borrowBase, 150e6);
    }

    function test_OfflineRecoveryVectorsDistinguishPhysicalCashFromWithheldGain() public {
        CarryReferenceVectors.RecoveryVector[] memory vectors = CarryReferenceVectors.recoveries();
        for (uint256 i; i < vectors.length; ++i) {
            CarryReferenceVectors.RecoveryVector memory v = vectors[i];
            CarryReferenceLedger ledger = _recover(v);
            _assertRecovery(ledger, v);
            assertEq(ledger.sideState(0).timestamp, v.elapsed, "terminal recovery preserves checkpoint clock");
            assertEq(ledger.sideState(0).index, v.expectedIndex, "terminal recovery preserves checkpoint index");
            assertEq(ledger.accountState(address(1)).protectedFunds, v.protectedFunds - v.physicalPaid);
        }
    }

    function test_OfflinePassiveDepthVectorsPreserveBothClocksUntilAssessment() public {
        CarryReferenceVectors.PassiveDepthVector[] memory vectors = CarryReferenceVectors.passiveDepths();
        for (uint256 i; i < vectors.length; ++i) {
            CarryReferenceVectors.PassiveDepthVector memory v = vectors[i];
            CarryReferenceLedger ledger = new CarryReferenceLedger(v.initialDepth, 0, v.annualBps);
            ledger.initializeAccount(address(1), 0, v.longBase, 0, 0, 0, 0);
            ledger.initializeAccount(address(2), 1, v.shortBase, 0, 0, 0, 0);
            ledger.changeDepthWithoutCheckpoint(v.finalDepth);
            assertEq(ledger.sideState(0).timestamp, 0, "passive cash change must not checkpoint Long");
            assertEq(ledger.sideState(1).timestamp, 0, "passive cash change must not checkpoint Short");
            assertEq(ledger.sideState(0).index, 0);
            assertEq(ledger.sideState(1).index, 0);
            bytes32 beforePreview = _ledgerDigest(ledger);
            assertEq(ledger.previewCheckpoint(address(1), v.elapsed).newCarry, v.expectedLongCarry);
            assertEq(ledger.previewCheckpoint(address(2), v.elapsed).newCarry, v.expectedShortCarry);
            assertEq(_ledgerDigest(ledger), beforePreview, "independent projection is read-only");
            assertEq(ledger.checkpoint(address(1), v.elapsed).newCarry, v.expectedLongCarry);
            assertEq(ledger.checkpoint(address(2), v.elapsed).newCarry, v.expectedShortCarry);
            assertEq(ledger.sideState(0).index, v.expectedLongIndex);
            assertEq(ledger.sideState(1).index, v.expectedShortIndex);
            assertEq(ledger.poolDepth(), v.finalDepth, "unpaid carry creates no cash");
        }
    }

    function test_PreviewCollectsNewClaimBackingBeforeClassifyingStoredArrears() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(90, 0, 10_000);
        ledger.initializeAccount(address(1), 0, 100, 10, 3, 7, 0);
        ledger.checkpoint(address(1), 365 days);
        ledger.creditClaim(address(1), 100, 100, 365 days);
        assertEq(ledger.accountState(address(1)).arrears, 77, "claim credit preserves old arrears");
        assertEq(ledger.accountState(address(1)).pledge, 100, "new claim credit remains available");
        bytes32 beforePreview = _ledgerDigest(ledger);
        CarryReferenceLedger.Collection memory projected = ledger.previewCheckpoint(address(1), 365 days);
        assertEq(projected.newCarry, 0);
        assertEq(projected.assessed, 77);
        assertEq(projected.fromMargin, 77);
        assertEq(projected.fromFree, 0);
        assertEq(projected.unpaid, 0, "stored arrears alone do not prove uncovered carry");
        assertEq(_ledgerDigest(ledger), beforePreview, "health projection cannot collect or advance carry");
        CarryReferenceLedger.Collection memory actual = ledger.checkpoint(address(1), 365 days);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(projected)));
        assertEq(ledger.accountState(address(1)).pledge, 23);
        assertEq(ledger.poolDepth(), 80);
    }

    function test_ReservationReclassificationPreservesClocksArrearsAndEconomicCollections() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(90, 0, 10_000);
        ledger.initializeAccount(address(1), 0, 100, 10, 3, 7, 0);
        ledger.checkpoint(address(1), 365 days);
        ledger.creditClaim(address(1), 40, 40, 365 days);
        ledger.creditFree(address(1), 9, 365 days);
        // The bounty credit collected the existing pledge before preserving its own newly credited free cash.
        assertEq(ledger.accountState(address(1)).arrears, 37);
        ledger.creditClaim(address(1), 20, 20, 365 days);
        assertEq(ledger.accountState(address(1)).arrears, 28);
        assertEq(ledger.accountState(address(1)).pledge, 20);
        ledger.creditFree(address(1), 9, 365 days);
        assertEq(ledger.accountState(address(1)).arrears, 8);
        // New backing may coexist with stored arrears. Classification-only cleanup must preserve that distinction.
        ledger.releaseToPledgeWithoutCheckpoint(address(1), 5);
        ledger.reserveBountyWithoutCheckpoint(address(1), 7, 3);
        assertEq(ledger.accountState(address(1)).pledge, 2);
        assertEq(ledger.accountState(address(1)).free, 2);
        assertEq(ledger.accountState(address(1)).protectedFunds, 12);
        assertEq(ledger.accountState(address(1)).borrowBase, 98);
        ledger.releaseProtectedWithoutCheckpoint(address(1), 4);
        ledger.releaseToPledgeWithoutCheckpoint(address(1), 3);
        ledger.consumeProtectedWithoutCheckpoint(address(1), 2);
        CarryReferenceLedger.Account memory state = ledger.accountState(address(1));
        assertEq(state.pledge, 5);
        assertEq(state.free, 6);
        assertEq(state.protectedFunds, 3);
        assertEq(state.borrowBase, 95);
        assertEq(state.arrears, 8, "reservations and cleanup do not collect retained arrears");
        assertEq(state.totalNewCarry, 90);
        assertEq(state.totalCollected, 82);
        assertEq(state.lastTime, 365 days);
        assertEq(state.lastIndex, 1e18);
        assertEq(ledger.sideState(0).timestamp, 365 days);
        assertEq(ledger.sideState(0).index, 1e18);
        assertEq(ledger.sideState(0).borrowBase, 95);
    }

    function test_ExcessReservationAndRecoveryRevertWithoutLosingEconomicHistory() public {
        CarryReferenceLedger ledger = new CarryReferenceLedger(90, 0, 10_000);
        ledger.initializeAccount(address(1), 0, 100, 10, 3, 7, 0);
        bytes32 before = _ledgerDigest(ledger);
        vm.expectRevert(CarryReferenceLedger.InsufficientFree.selector);
        ledger.reserveBountyWithoutCheckpoint(address(1), 4, 0);
        vm.expectRevert(CarryReferenceLedger.InsufficientPledge.selector);
        ledger.reserveBountyWithoutCheckpoint(address(1), 3, 11);
        vm.expectRevert(CarryReferenceLedger.InsufficientProtected.selector);
        ledger.releaseProtectedWithoutCheckpoint(address(1), 8);
        vm.expectRevert(CarryReferenceLedger.InsufficientProtected.selector);
        ledger.releaseToPledgeWithoutCheckpoint(address(1), 8);
        vm.expectRevert(CarryReferenceLedger.InsufficientProtected.selector);
        ledger.consumeProtectedWithoutCheckpoint(address(1), 8);
        assertEq(_ledgerDigest(ledger), before, "failed classification is atomic");
        ledger.checkpoint(address(1), 365 days);
        before = _ledgerDigest(ledger);
        vm.expectRevert(CarryReferenceLedger.InvalidArrearsSettlement.selector);
        ledger.settleActionArrears(address(1), 7, 50, 21);
        assertEq(_ledgerDigest(ledger), before, "over-recovery cannot erase or duplicate arrears");
        ledger.settleActionArrears(address(1), 7, 50, 20);
        before = _ledgerDigest(ledger);
        vm.expectRevert(CarryReferenceLedger.InvalidArrearsSettlement.selector);
        ledger.settleActionArrears(address(1), 0, 1, 0);
        assertEq(_ledgerDigest(ledger), before, "duplicate terminal recovery cannot collect twice");
    }

    function test_RecoveryGoldenRejectsPhantomCashAndDoubleEconomicCollection() public {
        CarryReferenceVectors.RecoveryVector memory v = CarryReferenceVectors.recoveries()[2];
        CarryReferenceLedger ledger = _recover(v);
        this.assertRecoveryGolden(ledger, v);
        vm.mockCall(
            address(ledger), abi.encodeCall(ledger.poolDepth, ()), abi.encode(v.expectedPoolDepth + v.gainWithheld)
        );
        vm.expectRevert();
        this.assertRecoveryGolden(ledger, v);
        vm.clearMockedCalls();
        vm.mockCall(
            address(ledger), abi.encodeCall(ledger.totalCollected, ()), abi.encode(v.expectedCollected + v.gainWithheld)
        );
        vm.expectRevert();
        this.assertRecoveryGolden(ledger, v);
        vm.clearMockedCalls();
        this.assertRecoveryGolden(ledger, v);
    }

    function test_VpiOffsetDischargesCarryWithoutCashOrWithheldPriceGain() public {
        CarryReferenceVectors.RecoveryVector memory v = CarryReferenceVectors.recoveries()[9];
        CarryReferenceLedger ledger = _recover(v);
        this.assertRecoveryGolden(ledger, v);
        assertEq(ledger.totalVpiOffset(), 77, "rebate credit independently discharges all terminal arrears");
        assertEq(ledger.totalWithheld(), 0, "no fresh price gain was withheld");
        assertEq(ledger.poolDepth(), 103, "only the ordinary thirteen-atom carry collection enters pool cash");
        assertEq(ledger.totalCollected(), 90, "ordinary cash plus noncash offset conserves economic carry");
        vm.mockCall(address(ledger), abi.encodeCall(ledger.totalVpiOffset, ()), abi.encode(uint256(0)));
        vm.expectRevert();
        this.assertRecoveryGolden(ledger, v);
        vm.clearMockedCalls();
        this.assertRecoveryGolden(ledger, v);
        bytes32 before = _ledgerDigest(ledger);
        vm.expectRevert(CarryReferenceLedger.InvalidArrearsSettlement.selector);
        ledger.settleActionArrears(address(1), 0, 0, 1, 0);
        assertEq(_ledgerDigest(ledger), before, "the same carry cannot be offset twice");
    }

    function assertRecoveryGolden(
        CarryReferenceLedger ledger,
        CarryReferenceVectors.RecoveryVector memory v
    ) external view {
        _assertRecovery(ledger, v);
    }

    function _recover(
        CarryReferenceVectors.RecoveryVector memory v
    ) private returns (CarryReferenceLedger ledger) {
        ledger = new CarryReferenceLedger(v.initialDepth, 0, v.annualBps);
        ledger.initializeAccount(address(1), 0, v.maxProfit, v.pledge, v.free, v.protectedFunds, 0);
        assertEq(ledger.checkpoint(address(1), v.elapsed).newCarry, v.expectedNewCarry);
        ledger.consumeProtectedWithoutCheckpoint(address(1), v.physicalPaid);
        ledger.settleActionArrears(address(1), v.physicalPaid, v.gainWithheld, v.vpiOffset, v.waived);
    }

    function _assertRecovery(
        CarryReferenceLedger ledger,
        CarryReferenceVectors.RecoveryVector memory v
    ) private view {
        CarryReferenceLedger.Account memory state = ledger.accountState(address(1));
        assertEq(ledger.poolDepth(), v.expectedPoolDepth, "only physically recovered carry increases pool cash");
        assertEq(ledger.totalCollected(), v.expectedCollected, "cash and gain withholding recover carry once");
        assertEq(ledger.totalWithheld(), v.gainWithheld);
        assertEq(ledger.totalVpiOffset(), v.vpiOffset);
        assertEq(ledger.totalWaived(), v.waived);
        assertEq(state.totalCollected, v.expectedCollected);
        assertEq(state.totalWithheld, v.gainWithheld);
        assertEq(state.totalVpiOffset, v.vpiOffset);
        assertEq(state.arrears, v.expectedRemainingArrears);
        assertEq(state.borrowBase, v.expectedBorrowBase);
        assertEq(ledger.totalNewCarry(), ledger.totalCollected() + ledger.totalWaived() + state.arrears);
    }

    function _ledgerDigest(
        CarryReferenceLedger ledger
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                ledger.accountState(address(1)),
                ledger.accountState(address(2)),
                ledger.sideState(0),
                ledger.sideState(1),
                ledger.poolDepth(),
                ledger.totalNewCarry(),
                ledger.totalCollected(),
                ledger.totalWithheld(),
                ledger.totalVpiOffset(),
                ledger.totalWaived()
            )
        );
    }

}

/// @notice Reachable carry accrual and collection against an independently advanced ledger. Trade setup uses the
///      Engine's Router capability; deposits, margin additions and withdrawals use real account entrypoints. Neither
///      storage mutation, previewed arithmetic, actual carry events nor production index helpers feed expectations.
contract CarryReferenceExecutionTest is BasePerpTest {

    address private constant ALICE = address(0xCA770101);
    address private constant BOB = address(0xCA770102);
    address private constant SOURCE = address(0xCA770103);
    uint256 private constant PRICE = 80_000_000;
    uint256 private constant INITIAL_DEPTH = 1_002_000e6;
    CarryReferenceLedger private referenceLedger;

    function setUp() public override {
        super.setUp();
        uint256 timestamp = vm.getBlockTimestamp();
        referenceLedger = new CarryReferenceLedger(INITIAL_DEPTH, timestamp, 500);
        _fundTrader(ALICE, 50_000e6);
        _open(ALICE, CfdTypes.Side.LONG, 100_000e18, 20_000e6, PRICE);
        _fundTrader(BOB, 40_000e6);
        _open(BOB, CfdTypes.Side.SHORT, 50_000e18, 12_000e6, PRICE);
        // Supplied margin funds the 4 bps execution fee and 10 bps liquidation reserve before becoming PnL pledge.
        referenceLedger.initializeAccount(ALICE, 0, 80_000e6, 19_888e6, 30_000e6, 80e6, timestamp);
        referenceLedger.initializeAccount(BOB, 1, 60_000e6, 11_944e6, 28_000e6, 40e6, timestamp);
        _assertSystem();
    }

    function testFuzz_TwoSideCheckpointsAndChangingBasisMatchIndependentLedger(
        uint256 firstInterval,
        uint256 secondInterval,
        uint256 depositSeed
    ) public {
        vm.warp(vm.getBlockTimestamp() + bound(firstInterval, 1, 365 days));
        _collect(ALICE);
        uint256 deposit = bound(depositSeed, 1, 1000e6);
        _fundTrader(BOB, deposit);
        referenceLedger.deposit(BOB, deposit, vm.getBlockTimestamp());
        _assertSystem();

        vm.prank(ALICE);
        engine.addMargin(ALICE, 1000e6);
        referenceLedger.addMargin(ALICE, 1000e6, vm.getBlockTimestamp());
        _assertSystem();

        vm.warp(vm.getBlockTimestamp() + bound(secondInterval, 1, 365 days));
        uint256 expectedDepthAfterDonation = referenceLedger.poolDepth() + 50_000e6;
        // accountExcess checkpoints the old effective assets before booking this external donation.
        usdc.mint(address(pool), 50_000e6);
        pool.accountExcess();
        referenceLedger.changeDepth(expectedDepthAfterDonation, vm.getBlockTimestamp());
        _assertSystem();
        _collect(BOB);
        _collect(ALICE);
    }

    function test_ExhaustionProtectsReservationsAndDistinguishesBountyFromDepositCredit() public {
        _reserveAlice(1000e6);
        _fundTrader(SOURCE, 75e6);
        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(SOURCE, 75e6);

        vm.warp(vm.getBlockTimestamp() + 500 * 365 days);
        _collect(ALICE);
        CarryReferenceLedger.Account memory exhausted = referenceLedger.accountState(ALICE);
        assertGt(exhausted.arrears, 100e6, "real elapsed carry must exhaust the funded account");
        assertEq(exhausted.pledge, 0);
        assertEq(exhausted.free, 0);
        assertEq(exhausted.protectedFunds, 1080e6);
        assertEq(clearinghouse.orderMarginUsdc(ALICE), 1000e6);
        assertEq(clearinghouse.liquidationReserveUsdc(ALICE), 80e6);

        vm.prank(address(router));
        engine.creditBounty(SOURCE, ALICE, 75e6, PRICE, uint64(vm.getBlockTimestamp()));
        referenceLedger.creditFree(ALICE, 75e6, vm.getBlockTimestamp());
        _assertSystem();
        assertEq(engine.unsettledCarryUsdc(ALICE), exhausted.arrears, "new bounty is not immediately recollected");
        assertEq(_freeSettlementUsdc(ALICE), 75e6);

        _fundTrader(ALICE, 1e6);
        referenceLedger.deposit(ALICE, 1e6, vm.getBlockTimestamp());
        _assertSystem();
        assertEq(engine.unsettledCarryUsdc(ALICE), exhausted.arrears - 76e6);
        assertEq(_freeSettlementUsdc(ALICE), 0, "post-deposit collector can use both new deposit and earlier bounty");
        assertEq(clearinghouse.orderMarginUsdc(ALICE), 1000e6);
    }

    function test_UnpaidExpiryPreservesCarryBasisForLaterCollection() public {
        _assertRefundCarryHistory(0, 30 days);
    }

    function test_UnpaidExpiryPreservesFreeCashWithoutExecutorCredit() public {
        _assertRefundCarryHistory(100_000, 30 days);
    }

    function test_UnpaidExpiryPreservesAccruedCarryUntilSubsequentCollection() public {
        _assertRefundCarryHistory(0, 500 * 365 days);
    }

    function _assertRefundCarryHistory(
        uint256 freeFunding,
        uint256 interval
    ) private {
        // The ledger is initialized from fixture constants. All expected states below are submitted actions.
        // A strictly newer publication replaces the fixture's initial $1 mark with the $0.80 entry mark.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(PRICE, uint64(vm.getBlockTimestamp()));
        referenceLedger.advance(vm.getBlockTimestamp());
        vm.prank(ALICE);
        clearinghouse.withdraw(ALICE, 30_000e6 - freeFunding);
        referenceLedger.withdraw(ALICE, 30_000e6 - freeFunding, vm.getBlockTimestamp());
        vm.prank(ALICE);
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, type(uint256).max, true);
        referenceLedger.checkpoint(ALICE, vm.getBlockTimestamp());

        _assertSystem();

        uint256 custodyBeforeRefund = clearinghouse.balanceUsdc(ALICE);
        uint256 poolBeforeRefund = referenceLedger.poolDepth();
        vm.warp(vm.getBlockTimestamp() + interval);

        uint256 retained = referenceLedger.accountState(ALICE).arrears;

        vm.prank(BOB);
        OrderV3Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        _assertSystem();
        assertEq(clearinghouse.balanceUsdc(ALICE), custodyBeforeRefund);
        assertEq(engine.unsettledCarryUsdc(ALICE), retained, "restoring pledge does not pay or erase carry");

        assertEq(pool.totalAssets(), poolBeforeRefund, "unpaid expiry performs no carry collection or credit");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _collect(ALICE);
        uint256 collected = referenceLedger.totalCollected();
        uint256 arrears = referenceLedger.accountState(ALICE).arrears;
        _collect(ALICE);
        assertEq(referenceLedger.totalCollected(), collected, "same-time repeat cannot double collect carry");
        assertEq(referenceLedger.accountState(ALICE).arrears, arrears);
        _collect(BOB);
    }

    function test_FlatBountyOnlyAdvancesIndexesForFreshMarkAndZeroCreditDoesNothing() public {
        address recipient = address(0xCA770104);
        referenceLedger.initializeFlatAccount(recipient, 0, 0, vm.getBlockTimestamp());
        _fundTrader(SOURCE, 100e6);
        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(SOURCE, 100e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.prank(address(router));
        engine.creditBounty(SOURCE, recipient, 0, PRICE, uint64(vm.getBlockTimestamp()));
        referenceLedger.creditFree(recipient, 0, vm.getBlockTimestamp());
        _assertSystem();

        uint64 publication = uint64(vm.getBlockTimestamp());
        vm.prank(address(router));
        engine.creditBounty(SOURCE, recipient, 75e6, PRICE, publication);
        referenceLedger.advance(vm.getBlockTimestamp());
        referenceLedger.creditFree(recipient, 75e6, vm.getBlockTimestamp());
        _assertSystem();
        assertEq(_freeSettlementUsdc(recipient), referenceLedger.accountState(recipient).free);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(router));
        engine.creditBounty(SOURCE, recipient, 25e6, PRICE, publication);
        referenceLedger.creditFree(recipient, 25e6, vm.getBlockTimestamp());
        _assertSystem();
        assertEq(_freeSettlementUsdc(recipient), 100e6);
        assertEq(engine.sideCarryTimestamp(0), publication, "flat old-mark credit leaves carry clocks alone");
    }

    function test_FailedWithdrawalRollsBackCarryAndRetryUsesOriginalHistory() public {
        _reserveAlice(1000e6);
        vm.warp(vm.getBlockTimestamp() + 500 * 365 days);
        vm.prank(address(router));
        engine.updateMarkPrice(PRICE, uint64(vm.getBlockTimestamp()));
        referenceLedger.advance(vm.getBlockTimestamp());
        bytes32 expectedBefore = _referenceDigest();
        bytes32 actualBefore = _productionDigest();

        vm.expectRevert(CarryReferenceLedger.CarryDelinquency.selector);
        referenceLedger.withdraw(ALICE, 1e6, vm.getBlockTimestamp());
        assertEq(_referenceDigest(), expectedBefore, "rejected reference withdrawal rolls back all collections");
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(ALICE);
        clearinghouse.withdraw(ALICE, 1e6);
        assertEq(_productionDigest(), actualBefore, "rejected withdrawal rolls back balances, bases and curve");
        _assertSystem();
        _collect(ALICE);
        assertGt(referenceLedger.accountState(ALICE).arrears, 0);
    }

    function test_ReferenceComparisonRejectsDoubleCollectionAndLostArrears() public {
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _collect(ALICE);
        CarryReferenceLedger.Account memory expected = referenceLedger.accountState(ALICE);
        assertGt(expected.totalCollected, 0, "control requires real accrued and collected carry");
        vm.mockCall(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.pnlPledgeUsdc, (ALICE)),
            abi.encode(expected.pledge - expected.totalCollected)
        );
        vm.expectRevert();
        this.assertReferenceSystem();
        vm.clearMockedCalls();
        this.assertReferenceSystem();

        vm.warp(vm.getBlockTimestamp() + 500 * 365 days);
        _collect(ALICE);
        assertGt(referenceLedger.accountState(ALICE).arrears, 0, "control requires reachable unpaid carry");
        vm.mockCall(address(engine), abi.encodeCall(engine.unsettledCarryUsdc, (ALICE)), abi.encode(uint256(0)));
        vm.expectRevert();
        this.assertReferenceSystem();
        vm.clearMockedCalls();
        this.assertReferenceSystem();
    }

    function assertReferenceSystem() external view {
        _assertSystem();
    }

    function _reserveAlice(
        uint256 amount
    ) private {
        // Isolate the real clearinghouse reservation capability; the mixed-history campaign exercises Router commit.
        vm.prank(address(engine));
        clearinghouse.reserveCommittedOrderMargin(ALICE, 9_999_999, amount);
        referenceLedger.reserveFree(ALICE, amount, vm.getBlockTimestamp());
        _assertSystem();
    }

    function _collect(
        address account
    ) private {
        referenceLedger.checkpoint(account, vm.getBlockTimestamp());
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(account);
        _assertSystem();
    }

    function _assertSystem() private view {
        _assertAccount(ALICE);
        _assertAccount(BOB);
        for (uint8 side; side < 2; ++side) {
            CarryReferenceLedger.Side memory expected = referenceLedger.sideState(side);
            assertEq(engine.sideBorrowBaseUsdc(side), expected.borrowBase, "independent aggregate borrow base");
            assertEq(engine.sideCarryIndex(side), expected.index, "independent directional index");
            assertEq(engine.sideCarryTimestamp(side), expected.timestamp, "directional accrual clock");
        }
        assertEq(pool.totalAssets(), referenceLedger.poolDepth(), "independent effective pool depth");
        assertEq(
            usdc.balanceOf(address(pool)), referenceLedger.poolDepth(), "collected carry reaches physical pool custody"
        );
        assertEq(
            referenceLedger.totalNewCarry(),
            referenceLedger.totalCollected() + referenceLedger.accountState(ALICE).arrears
                + referenceLedger.accountState(BOB).arrears,
            "newly assessed carry is collected or retained exactly once"
        );
    }

    function _assertAccount(
        address account
    ) private view {
        CarryReferenceLedger.Account memory expected = referenceLedger.accountState(account);
        (uint256 base, uint256 index, uint64 timestamp) = engine.positionCarryState(account);
        assertEq(base, expected.borrowBase, "independent position borrow base");
        assertEq(index, expected.lastIndex, "position checkpoint index");
        assertEq(timestamp, expected.lastTime, "position checkpoint time");
        assertEq(clearinghouse.pnlPledgeUsdc(account), expected.pledge, "margin-first carry collection");
        assertEq(_freeSettlementUsdc(account), expected.free, "free cash pays only after pledge");
        assertEq(engine.unsettledCarryUsdc(account), expected.arrears, "independent uncollected carry");
        assertEq(
            clearinghouse.balanceUsdc(account),
            expected.pledge + expected.free + expected.protectedFunds,
            "settlement custody partitions exactly"
        );
    }

    function _referenceDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                referenceLedger.accountState(ALICE),
                referenceLedger.accountState(BOB),
                referenceLedger.sideState(0),
                referenceLedger.sideState(1),
                referenceLedger.poolDepth(),
                referenceLedger.totalNewCarry(),
                referenceLedger.totalCollected()
            )
        );
    }

    function _productionDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                clearinghouse.getAccountUsdcBuckets(ALICE),
                clearinghouse.getAccountUsdcBuckets(BOB),
                _productionCarryDigest(ALICE),
                _productionCarryDigest(BOB),
                engine.unsettledCarryUsdc(ALICE),
                engine.sideCarryIndex(0),
                engine.sideCarryIndex(1),
                pool.totalAssets(),
                pool.accountedAssets(),
                terminalNavBook.curveHashOf(ALICE)
            )
        );
    }

    function _productionCarryDigest(
        address account
    ) private view returns (bytes32) {
        (uint256 base, uint256 index, uint64 timestamp) = engine.positionCarryState(account);
        return keccak256(abi.encode(base, index, timestamp));
    }

}
