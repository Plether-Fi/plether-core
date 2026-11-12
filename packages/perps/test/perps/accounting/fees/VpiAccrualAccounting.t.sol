// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {VpiAccrualAccountingLib} from "@plether/perps/libraries/VpiAccrualAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract VpiAccrualLifecycleTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.01e18;
    }

    function test_AggregatesFollowSignCrossingsPartialCloseAndDeletion() public {
        _fundTrader(ALICE, 200_000e6);
        _fundTrader(BOB, 200_000e6);

        _open(ALICE, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 0.8e8);
        assertGt(_accrual(ALICE), 0);
        _assertAggregateParity();

        _open(BOB, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 0.8e8);
        assertLt(_accrual(BOB), 0);
        _assertAggregateParity();

        _open(BOB, CfdTypes.Side.SHORT, 400_000e18, 20_000e6, 0.8e8);
        assertGt(_accrual(BOB), 0, "increase must cross negative to positive lifetime VPI");
        _assertAggregateParity();

        _open(ALICE, CfdTypes.Side.LONG, 100_000e18, 20_000e6, 0.8e8);
        assertLt(_accrual(ALICE), 0, "increase must cross positive to negative lifetime VPI");
        _assertAggregateParity();

        _close(BOB, CfdTypes.Side.SHORT, 123_400e18, 0.8e8);
        _assertAggregateParity();
        _close(ALICE, CfdTypes.Side.LONG, 300_000e18, 0.8e8);
        _assertAggregateParity();
        _close(BOB, CfdTypes.Side.SHORT, 376_600e18, 0.8e8);
        (uint256 positiveAssets, uint256 negativeAssets) = engine.vpiAccountingSnapshot();
        assertEq(positiveAssets, 0, "deletion must remove every positive contribution");
        assertEq(negativeAssets, 0, "deletion must remove every negative contribution");
    }

    function test_LiquidationRemovesPositiveAccrual() public {
        _fundTrader(ALICE, 200_000e6);
        _open(ALICE, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 0.8e8);
        assertGt(engine.totalPositiveVpiAccruedAssets(), 0);

        uint256 depthAssets = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(ALICE, 1.2e8, depthAssets, uint64(block.timestamp), address(this));

        assertEq(engine.totalPositiveVpiAccruedAssets(), 0);
        _assertAggregateParity();
    }

    function test_LiquidationRemovesNegativeAccrualWithoutRemovingOtherAccountContribution() public {
        _fundTrader(ALICE, 200_000e6);
        _fundTrader(BOB, 200_000e6);
        _open(ALICE, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 0.8e8);
        _open(BOB, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 0.8e8);
        assertGt(engine.totalNegativeVpiAccruedAssets(), 0);
        uint256 positiveBefore = engine.totalPositiveVpiAccruedAssets();

        uint256 depthAssets = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(BOB, 0.4e8, depthAssets, uint64(block.timestamp), address(this));

        assertEq(engine.totalNegativeVpiAccruedAssets(), 0);
        assertEq(engine.totalPositiveVpiAccruedAssets(), positiveBefore);
        _assertAggregateParity();
    }

    function _accrual(
        address account
    ) private view returns (int256 accruedAssets) {
        (,,,,,, accruedAssets) = engine.positions(account);
    }

    function _assertAggregateParity() private view {
        int256 aliceAccrual = _accrual(ALICE);
        int256 bobAccrual = _accrual(BOB);
        uint256 expectedPositive = aliceAccrual > 0 ? uint256(aliceAccrual) : 0;
        uint256 expectedNegative = aliceAccrual < 0 ? uint256(-aliceAccrual) : 0;
        if (bobAccrual > 0) {
            expectedPositive += uint256(bobAccrual);
        } else if (bobAccrual < 0) {
            expectedNegative += uint256(-bobAccrual);
        }
        (uint256 positiveAssets, uint256 negativeAssets) = engine.vpiAccountingSnapshot();
        assertEq(positiveAssets, expectedPositive, "aggregate must match independently read live positions");
        assertEq(negativeAssets, expectedNegative, "aggregate must match independently read live positions");
    }

}

contract VpiAccrualBoundsTest is Test {

    function test_MinimumSignedValueHasSafeUnsignedMagnitude() public pure {
        (uint256 positiveAssets, uint256 negativeAssets) = VpiAccrualAccountingLib.contribution(type(int256).min);
        assertEq(positiveAssets, 0);
        assertEq(negativeAssets, 1 << 255);
    }

    function test_AggregateOverflowFailsPreflight() public pure {
        (bool valid,,) = VpiAccrualAccountingLib.tryReplace(type(uint256).max, 0, 0, 1);
        assertFalse(valid);
        (valid,,) = VpiAccrualAccountingLib.tryReplace(0, type(uint256).max, 0, -1);
        assertFalse(valid);
    }

    function test_MissingPriorContributionFailsPreflight() public pure {
        (bool valid,,) = VpiAccrualAccountingLib.tryReplace(0, 0, 1, 0);
        assertFalse(valid);
        (valid,,) = VpiAccrualAccountingLib.tryReplace(0, 0, -1, 0);
        assertFalse(valid);
    }

}
