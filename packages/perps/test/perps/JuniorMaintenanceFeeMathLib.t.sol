// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {JuniorMaintenanceFeeMathLib} from "@plether/perps/libraries/JuniorMaintenanceFeeMathLib.sol";
import {Test} from "forge-std/Test.sol";

contract JuniorMaintenanceFeeMathHarness {

    function ray() external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.RAY;
    }

    function maxAprBps() external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.MAX_APR_BPS;
    }

    function maxChargeHours() external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.MAX_CHARGE_HOURS;
    }

    function hourlyFeeRay(
        uint256 aprBps
    ) external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.hourlyFeeRay(aprBps);
    }

    function retentionRay(
        uint256 aprBps,
        uint256 chargeableHours
    ) external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.retentionRay(aprBps, chargeableHours);
    }

    function pendingFeeShares(
        uint256 rawSupply,
        uint256 aprBps,
        uint256 chargeableHours
    ) external pure returns (uint256) {
        return JuniorMaintenanceFeeMathLib.pendingFeeShares(rawSupply, aprBps, chargeableHours);
    }

}

contract JuniorMaintenanceFeeMathLibTest is Test {

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HOURS_PER_YEAR = 8760;
    uint256 internal constant MAX_APR_BPS = 1000;

    JuniorMaintenanceFeeMathHarness internal harness;

    function setUp() public {
        harness = new JuniorMaintenanceFeeMathHarness();
    }

    function test_ConstantsAreStable() public view {
        assertEq(harness.ray(), RAY);
        assertEq(harness.maxAprBps(), MAX_APR_BPS);
        assertEq(harness.maxChargeHours(), HOURS_PER_YEAR);
    }

    function test_ZeroRateAndZeroHoursNeverCharge() public view {
        assertEq(harness.hourlyFeeRay(0), 0);
        assertEq(harness.retentionRay(0, HOURS_PER_YEAR), RAY);
        assertEq(harness.retentionRay(MAX_APR_BPS, 0), RAY);
        assertEq(harness.pendingFeeShares(type(uint256).max, 0, HOURS_PER_YEAR), 0);
        assertEq(harness.pendingFeeShares(type(uint256).max, MAX_APR_BPS, 0), 0);
        assertEq(harness.pendingFeeShares(0, MAX_APR_BPS, HOURS_PER_YEAR), 0);
    }

    function test_TenPercentAnnualExample() public view {
        assertEq(harness.hourlyFeeRay(MAX_APR_BPS), 11_415_525_114_155_251_141_552);
        assertEq(harness.retentionRay(MAX_APR_BPS, HOURS_PER_YEAR), 904_836_901_572_463_003_134_684_023);
        assertEq(harness.pendingFeeShares(100 ether, MAX_APR_BPS, HOURS_PER_YEAR), 10_517_154_888_594_687_866);
    }

    function test_InvalidBoundsRevert() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                JuniorMaintenanceFeeMathLib.JuniorMaintenanceFeeMathLib__InvalidAprBps.selector, MAX_APR_BPS + 1
            )
        );
        harness.pendingFeeShares(1, MAX_APR_BPS + 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JuniorMaintenanceFeeMathLib.JuniorMaintenanceFeeMathLib__InvalidChargeableHours.selector,
                HOURS_PER_YEAR + 1
            )
        );
        harness.pendingFeeShares(1, MAX_APR_BPS, HOURS_PER_YEAR + 1);
    }

    function test_MaxUintSupplyQuoteDoesNotOverflow() public view {
        uint256 feeShares = harness.pendingFeeShares(type(uint256).max, MAX_APR_BPS, HOURS_PER_YEAR);

        assertGt(feeShares, 0);
        assertLt(feeShares, type(uint256).max / 9);
    }

    function test_MaxReachableSupplyCanAddTheFullYearFeeWithoutOverflow() public view {
        uint256 retainedRay = harness.retentionRay(MAX_APR_BPS, HOURS_PER_YEAR);
        uint256 safeRawSupply = Math.mulDiv(type(uint256).max, retainedRay, RAY, Math.Rounding.Floor);
        uint256 feeShares = harness.pendingFeeShares(safeRawSupply, MAX_APR_BPS, HOURS_PER_YEAR);

        assertLe(feeShares, type(uint256).max - safeRawSupply);
        assertGe(safeRawSupply + feeShares, safeRawSupply);
    }

    function testFuzz_HourlyRateIsTheSpecifiedFloor(
        uint256 aprSeed
    ) public view {
        uint256 aprBps = bound(aprSeed, 0, MAX_APR_BPS);
        uint256 hourlyRay = harness.hourlyFeeRay(aprBps);
        uint256 denominator = BPS * HOURS_PER_YEAR;

        assertLe(hourlyRay * denominator, aprBps * RAY);
        assertGt((hourlyRay + 1) * denominator, aprBps * RAY);
    }

    function testFuzz_OptimizedPowerTracksBruteForceHourlyIteration(
        uint256 aprSeed,
        uint256 hoursSeed
    ) public view {
        uint256 aprBps = bound(aprSeed, 0, MAX_APR_BPS);
        uint256 chargeableHours = bound(hoursSeed, 0, HOURS_PER_YEAR);
        uint256 optimizedRetention = harness.retentionRay(aprBps, chargeableHours);
        uint256 bruteForceRetention = _bruteForceRetention(aprBps, chargeableHours);
        uint256 difference = optimizedRetention > bruteForceRetention
            ? optimizedRetention - bruteForceRetention
            : bruteForceRetention - optimizedRetention;

        assertLe(optimizedRetention, RAY);
        assertGt(optimizedRetention, 0);
        assertLe(difference, 2 * chargeableHours, "power-rounding divergence");
    }

    function testFuzz_FeeNeverExceedsRoundedRetentionOrNominalCharge(
        uint256 supplySeed,
        uint256 aprSeed,
        uint256 hoursSeed
    ) public view {
        uint256 rawSupply = bound(supplySeed, 0, 1e36);
        uint256 aprBps = bound(aprSeed, 0, MAX_APR_BPS);
        uint256 chargeableHours = bound(hoursSeed, 0, HOURS_PER_YEAR);
        uint256 retainedRay = harness.retentionRay(aprBps, chargeableHours);
        uint256 dilutionRay = RAY - retainedRay;
        uint256 feeShares = harness.pendingFeeShares(rawSupply, aprBps, chargeableHours);

        assertLe(dilutionRay, harness.hourlyFeeRay(aprBps) * chargeableHours, "above nominal fee");
        assertLe(feeShares * retainedRay, rawSupply * dilutionRay, "share quote rounded up");
        assertGt((feeShares + 1) * retainedRay, rawSupply * dilutionRay, "share quote is not the exact floor");
        assertLe(feeShares * RAY, (rawSupply + feeShares) * dilutionRay, "recipient fraction too high");
    }

    function testFuzz_CheckpointPartitionDifferenceIsBounded(
        uint256 supplySeed,
        uint256 aprSeed,
        uint256 totalHoursSeed,
        uint256 firstPeriodSeed
    ) public view {
        uint256 rawSupply = bound(supplySeed, 0, 1e36);
        uint256 aprBps = bound(aprSeed, 0, MAX_APR_BPS);
        uint256 totalHours = bound(totalHoursSeed, 0, HOURS_PER_YEAR);
        uint256 firstPeriod = bound(firstPeriodSeed, 0, totalHours);
        uint256 secondPeriod = totalHours - firstPeriod;

        uint256 oneCheckpointSupply = rawSupply + harness.pendingFeeShares(rawSupply, aprBps, totalHours);
        uint256 firstCheckpointSupply = rawSupply + harness.pendingFeeShares(rawSupply, aprBps, firstPeriod);
        uint256 splitCheckpointSupply =
            firstCheckpointSupply + harness.pendingFeeShares(firstCheckpointSupply, aprBps, secondPeriod);
        uint256 difference = oneCheckpointSupply > splitCheckpointSupply
            ? oneCheckpointSupply - splitCheckpointSupply
            : splitCheckpointSupply - oneCheckpointSupply;
        uint256 greaterFinalSupply = Math.max(oneCheckpointSupply, splitCheckpointSupply);
        uint256 roundingBound = Math.mulDiv(greaterFinalSupply, 2 * totalHours + 64, RAY, Math.Rounding.Ceil) + 2;

        assertLe(difference, roundingBound, "partition-rounding divergence");
    }

    function _bruteForceRetention(
        uint256 aprBps,
        uint256 chargeableHours
    ) internal view returns (uint256 retainedRay) {
        uint256 hourlyRetentionRay = RAY - harness.hourlyFeeRay(aprBps);
        retainedRay = RAY;

        for (uint256 elapsedHours; elapsedHours < chargeableHours; ++elapsedHours) {
            retainedRay = Math.mulDiv(retainedRay, hourlyRetentionRay, RAY, Math.Rounding.Ceil);
        }
    }

}
