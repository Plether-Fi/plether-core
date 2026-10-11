// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CarryReferenceLedger} from "../../invariant/ghost/CarryReferenceLedger.sol";
import {CarryReferenceVectors} from "../../shared/CarryReferenceVectors.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
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
