// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {VpiAccrualAccountingLib} from "@plether/perps/libraries/VpiAccrualAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Freezes pre-cleanup planner outcomes and checks the old equations independently of private helpers.
contract VpiCleanupEquivalenceTest is Test {

    uint256 private constant SIZE = 10_000e18;
    uint256 private constant PRICE = 1e8;
    uint256 private constant PLEDGE = 2000e6;
    uint256 private constant POOL_CASH = 1_000_000e6;
    // Captured from the integrated planner (including PR #155 protected top-ups and PR #165 close fee top-up): 144 CloseDelta outcomes.
    bytes32 private constant BASELINE_CLOSE_GRID = 0x134382e2f475e3bee7429a2643d3a30b90ededbfb00eee0badaa5f05667b1157;

    CfdEnginePlanner private planner;

    struct Case {
        int256 accrual;
        uint256 closeSize;
        uint256 price;
        uint256 excessReserve;
        bool frozen;
        bool zeroDepth;
        bool worsensSkew;
    }

    function setUp() public {
        planner = new CfdEnginePlanner();
    }

    function test_ClosePlanGridMatchesFrozenBaseline() public {
        bytes32 observed;
        int256[3] memory accruals = [int256(-100e6), int256(0), int256(100e6)];
        uint256[3] memory prices = [uint256(98_000_000), uint256(99_500_000), uint256(101_000_000)];
        for (uint256 a; a < accruals.length; ++a) {
            for (uint256 p; p < prices.length; ++p) {
                for (uint256 mode; mode < 16; ++mode) {
                    Case memory c = Case({
                        accrual: accruals[a],
                        closeSize: (mode & 1) == 0 ? SIZE : SIZE / 2,
                        price: prices[p],
                        excessReserve: 17e6,
                        frozen: (mode & 2) != 0,
                        zeroDepth: (mode & 4) != 0,
                        worsensSkew: (mode & 8) != 0
                    });
                    CfdEnginePlanTypes.CloseDelta memory d = _plan(c);
                    _assertLegacyAllocation(c, d);
                    observed = keccak256(abi.encode(observed, c, d));
                }
            }
        }
        // This is a complete typed-delta commitment, not only a sum of financial outcomes.
        emit log_named_bytes32("BASELINE_CLOSE_GRID", observed);
        assertEq(observed, BASELINE_CLOSE_GRID, "complete close-grid outcomes must match the pre-cleanup baseline");
    }

    function testFuzz_ProductionCloseKeepsLegacyFeeAndClawbackEquations(
        int128 accrualSeed,
        uint32 priceSeed,
        uint64 reserveSeed,
        uint8 mode
    ) public view {
        Case memory c = Case({
            accrual: bound(int256(accrualSeed), -200e6, 200e6),
            closeSize: (mode & 1) == 0 ? SIZE : SIZE / 2,
            price: bound(priceSeed, 98_000_000, 102_000_000),
            excessReserve: bound(reserveSeed, 0, 50e6),
            frozen: (mode & 2) != 0,
            zeroDepth: (mode & 4) != 0,
            worsensSkew: (mode & 8) != 0
        });
        _assertLegacyAllocation(c, _plan(c));
    }

    function testFuzz_NegativeContributionMatchesFrozenMagnitude(
        int256 accrued
    ) public pure {
        (, uint256 actual) = VpiAccrualAccountingLib.contribution(accrued);
        assertEq(actual, _legacyNegative(accrued));
    }

    function test_MinimumNegativeContributionMatchesFrozenMagnitude() public pure {
        (, uint256 actual) = VpiAccrualAccountingLib.contribution(type(int256).min);
        assertEq(actual, 1 << 255);
    }

    function testFuzz_ClawbackRemovalIdentityPreservesWholeSignedDomain(
        int256 accrued,
        uint256 removedSeed
    ) public pure {
        uint256 magnitude = accrued < 0 ? _legacyNegative(accrued) : uint256(accrued);
        uint256 removedMagnitude = bound(removedSeed, 0, magnitude);
        int256 removed = accrued < 0 ? _negativeSigned(removedMagnitude) : int256(removedMagnitude);
        uint256 oldClawback = _legacyNegative(accrued) - _legacyNegative(accrued - removed);
        (, uint256 removedClawback) = VpiAccrualAccountingLib.contribution(removed);
        assertEq(removedClawback, oldClawback);
    }

    function testFuzz_ProtocolTopUpRequestMatchesOldSaturation(
        uint256 desired,
        uint256 alreadyCredited,
        uint256 freeCash
    ) public pure {
        uint256 cappedCredit = alreadyCredited > desired ? desired : alreadyCredited;
        uint256 oldRequested = desired - cappedCredit;
        uint256 directRequested = desired > alreadyCredited ? desired - alreadyCredited : 0;
        assertEq(_min(directRequested, freeCash), _min(oldRequested, freeCash));
    }

    function testFuzz_CloseTopUpAdditionSubtractionMatchesDirectRequest(
        uint256 credited,
        uint256 requestSeed,
        uint256 freeCash
    ) public pure {
        // Existing planner deltas make credited + top-up representable. Keep that old checked domain.
        uint256 requested = bound(requestSeed, 0, type(uint256).max - credited);
        uint256 totalIntended = credited + requested;
        uint256 cappedCredit = credited > totalIntended ? totalIntended : credited;
        assertEq(_min(totalIntended - cappedCredit, freeCash), _min(requested, freeCash));
    }

    function testFuzz_DirectProtocolCreditIdentity(
        uint256 assessed,
        uint256 withheld,
        uint256 collectionSeed
    ) public pure {
        uint256 collected = bound(collectionSeed, 0, type(uint256).max - withheld);
        uint256 fee = _min(assessed, withheld + collected);
        uint256 oldCredit = _min(fee - _min(fee, withheld), collected);
        uint256 directCredit = fee > withheld ? fee - withheld : 0;
        assertEq(directCredit, oldCredit);
        assertLe(directCredit, collected);
    }

    function _assertLegacyAllocation(
        Case memory c,
        CfdEnginePlanTypes.CloseDelta memory d
    ) private pure {
        assertTrue(d.valid, "equivalence fixture must reach a valid full or partial close");
        int256 removed = (c.accrual * int256(c.closeSize)) / int256(SIZE);
        assertEq(d.posVpiAccruedReduction, removed, "signed proration must not change");
        assertEq(d.closeState.proportionalAccrualAssets, removed);
        assertGe(removed + d.closeState.vpiDeltaAssets, 0, "existing lifetime clamp");
        if (c.zeroDepth) {
            assertEq(d.closeState.vpiDeltaAssets, removed < 0 ? -removed : int256(0));
        }
        uint256 oldClawback = _legacyNegative(c.accrual) - _legacyNegative(c.accrual - removed);
        assertEq(d.vpiRebateReserveAfterAssets, _legacyNegative(c.accrual - removed));
        assertLe(d.vpiRebateReserveConsumedAssets, oldClawback);
        assertGe(
            d.vpiRebateReserveBeforeAssets - d.vpiRebateReserveAfterAssets - d.vpiRebateReserveConsumedAssets,
            c.excessReserve,
            "excess reserve is released, not collected as clawback"
        );
        uint256 oldClawbackWithheld = oldClawback - d.vpiRebateReserveConsumedAssets;
        uint256 nonClawbackWithheld = d.actionChargeWithheldAssets - oldClawbackWithheld;
        uint256 nonVpiCollected = d.actionChargeCollectedAssets - d.vpiRebateReserveConsumedAssets;
        uint256 oldFee = _min(d.closeState.executionFeeAssets, nonClawbackWithheld + nonVpiCollected);
        uint256 oldFeeWithheld = _min(oldFee, nonClawbackWithheld);
        uint256 oldDirectCredit = _min(oldFee - oldFeeWithheld, nonVpiCollected);
        assertEq(d.executionFeeAssets, oldFee, "fee eligibility and waiver must not change");
        assertEq(d.actionProtocolFeeCreditedAssets, oldDirectCredit, "old direct-credit allocation");
        uint256 rebateOffsetFee =
            d.closeState.executionFeeAssets - _min(d.closeState.executionFeeAssets, d.actionChargeAssessedAssets);
        assertLe(d.protocolFeeTopUpAssets, oldFee - oldDirectCredit + rebateOffsetFee);
    }

    function _plan(
        Case memory c
    ) private view returns (CfdEnginePlanTypes.CloseDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(c);
        CfdTypes.Order memory order;
        order.account = snap.account;
        order.isClose = true;
        order.sizeDelta = c.closeSize;
        return planner.planClose(snap, order, c.price);
    }

    function _snapshot(
        Case memory c
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 reserve = _legacyNegative(c.accrual) + c.excessReserve;
        uint256 action = reserve + 19e6;
        snap.account = address(0xA11CE);
        snap.currentTimestamp = 100;
        snap.capPrice = 2e8;
        snap.position = CfdTypes.Position(SIZE, PLEDGE, PRICE, 10_000e6, CfdTypes.Side.LONG, 1, 1, c.accrual);
        snap.positionEntryCostAssetAtoms = CfdMath.sizeToLots(SIZE) * PRICE;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot(
            10_000e6, SIZE, snap.positionEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE, PLEDGE
        );
        if (c.worsensSkew) {
            snap.shortSide.maxProfitAssets = 20_000e6;
            snap.shortSide.openInterest = 2 * SIZE;
            snap.shortSide.entryNotional = 2 * snap.longSide.entryNotional;
        }
        snap.poolAssets = c.zeroDepth ? 0 : POOL_CASH;
        snap.poolCashAssets = POOL_CASH;
        snap.totalPositiveVpiAccruedAssets = c.accrual > 0 ? uint256(c.accrual) : 0;
        snap.totalNegativeVpiAccruedAssets = _legacyNegative(c.accrual);
        snap.vpiRebateReserveAssets = reserve;
        snap.liquidationReserveAssets = 23e6;
        snap.actionReserveAssets = action;
        snap.protectedExecutionBountyAssets = 3e6;
        uint256 locked = PLEDGE + 23e6 + action;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: locked + 100e6,
            totalLockedMarginAssets: locked,
            activePositionMarginAssets: PLEDGE,
            otherLockedMarginAssets: 23e6 + action,
            freeSettlementAssets: 100e6
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets(PLEDGE, 0, action, locked);
        snap.executionFeeBps = 10;
        snap.oracleFrozen = c.frozen;
        snap.frozenCloseSpreadBps = 25;
        snap.riskParams.vpiFactor = 1e18;
        snap.riskParams.maintMarginBps = 100;
        snap.riskParams.fadMarginBps = 300;
    }

    /// @dev Frozen pre-cleanup formula with an explicit minimum-value branch, independent of the shared helper.
    function _legacyNegative(
        int256 value
    ) private pure returns (uint256) {
        if (value >= 0) {
            return 0;
        }
        if (value == type(int256).min) {
            return 1 << 255;
        }
        return uint256(-value);
    }

    function _negativeSigned(
        uint256 magnitude
    ) private pure returns (int256) {
        return magnitude == 1 << 255 ? type(int256).min : -int256(magnitude);
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

}
