// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineClosePreviewTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_PreviewClose_UsesCanonicalPoolDepthWhileSimulateCloseAllowsWhatIfDepth() public {
        address longAccount = address(uint160(0xC10));
        address shortAccount = address(uint160(0xC11));
        _fundTrader(longAccount, 5000e6);
        _fundTrader(shortAccount, 5000e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        uint256 canonicalDepth = pool.totalAssets();
        ICfdEngineTypes.ClosePreview memory canonicalPreview = engineLens.previewClose(shortAccount, 10_000e18, 1e8);
        ICfdEngineTypes.ClosePreview memory matchedSimulation =
            engineLens.simulateClose(shortAccount, 10_000e18, 1e8, canonicalDepth);
        ICfdEngineTypes.ClosePreview memory lowDepthSimulation =
            engineLens.simulateClose(shortAccount, 10_000e18, 1e8, canonicalDepth / 10);

        _assertClosePreviewEquals(canonicalPreview, matchedSimulation);
    }

    function test_PreviewClose_ReturnsClaimAndImmediateSettlementBreakdown() public {
        address trader = address(0xAB13);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory normalPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(normalPreview.valid);
        assertGt(normalPreview.immediatePayoutUsdc, 0);
        assertEq(normalPreview.traderClaimBalanceUsdc, 0);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        ICfdEngineTypes.ClosePreview memory illiquidPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(illiquidPreview.valid);
        assertEq(illiquidPreview.immediatePayoutUsdc, 0);
        assertGt(illiquidPreview.traderClaimBalanceUsdc, 0);
        assertEq(illiquidPreview.remainingSize, 0);
    }

    function test_SimulateClose_UsesHypotheticalPoolCashForPayoutBreakdown() public {
        address trader = address(0xAB1301);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 canonicalDepth = pool.totalAssets();
        ICfdEngineTypes.ClosePreview memory canonicalPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        ICfdEngineTypes.ClosePreview memory hypotheticalPreview =
            engineLens.simulateClose(account, 100_000e18, 80_000_000, 1);

        assertTrue(canonicalPreview.valid);
        assertGt(canonicalPreview.immediatePayoutUsdc, 0, "Live preview should reflect currently available pool cash");
        assertEq(canonicalPreview.traderClaimBalanceUsdc, 0, "Live preview should not defer when cash is available");
        assertEq(canonicalDepth, pool.totalAssets(), "Setup should keep canonical depth unchanged");

        assertTrue(hypotheticalPreview.valid);
        assertEq(hypotheticalPreview.immediatePayoutUsdc, 0, "Hypothetical close should use caller-supplied pool cash");
        assertGt(hypotheticalPreview.traderClaimBalanceUsdc, 0, "Low hypothetical cash should defer the payout");
    }

    function test_PreviewClose_ReportsPostOpDegradedStateAfterLatch() public {
        address longTrader = address(0xAB130C);
        address shortTrader = address(0xAB130D);
        address residualShortTrader = address(0xAB130E);
        address longAccount = longTrader;
        address shortAccount = shortTrader;
        address residualShortAccount = residualShortTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _fundTrader(residualShortTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 900_000e18, 45_000e6, 1e8);
        _open(residualShortAccount, CfdTypes.Side.SHORT, 99_000e18, 5000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);

        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);
        assertTrue(engine.degradedMode(), "Setup close should latch degraded mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(shortAccount, 900_000e18, 20_000_000);
        assertTrue(preview.valid, "Full close should remain previewable after degraded mode latches");
        assertFalse(preview.triggersDegradedMode, "Transition flag should stay false after degraded mode latches");
        assertEq(
            preview.postOpDegradedMode,
            preview.effectiveAssetsAfterUsdc < preview.maxLiabilityAfterUsdc,
            "Preview should expose raw post-op solvency values for integrators even after degraded mode latches"
        );
    }

    function test_PreviewClose_NegativeVpiDoesNotPanic() public {
        address trader = address(0xAB1301);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1e8);

        assertTrue(preview.valid, "Preview should remain valid when close earns a negative VPI rebate");
        assertLt(preview.vpiDeltaUsdc, 0, "Preview should expose negative VPI as a rebate instead of panicking");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI charge field should clamp rebates to zero");
        assertEq(preview.frozenSpreadUsdc, 0, "Live-market close should not assess the frozen spread");
    }

    function test_PreviewClose_FadButLiveMarketKeepsSignedVpiRebate() public {
        address trader = address(0xAB1311);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        vm.warp(1_709_934_300); // Friday 21:45 UTC: FAD, but not oracle-frozen.
        assertTrue(engine.isFadWindow(), "Setup should be in FAD");
        assertFalse(engine.isOracleFrozen(), "FAD runway should still be live-market mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1e8);

        assertTrue(preview.valid, "Live FAD close should be previewable");
        assertLt(preview.vpiDeltaUsdc, 0, "Live FAD should keep normal signed VPI rebate behavior");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI field should clamp normal rebates to zero");
        assertEq(preview.frozenSpreadUsdc, 0, "FAD-only close should not assess the frozen spread");
        assertEq(preview.frozenSpreadPaidUsdc, 0, "FAD-only close should not pay the frozen spread");
        assertEq(preview.frozenSpreadWaivedUsdc, 0, "FAD-only close should not waive a frozen spread");
    }

    function test_PreviewClose_OracleFrozenSkewHealingCloseKeepsSignedVpiAndPaysFixedSpread() public {
        address trader = address(0xAB1312);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        vm.warp(1_709_985_600); // Saturday 12:00 UTC: oracle-frozen close-only mode.
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 0.8e8);

        assertTrue(preview.valid, "Frozen close should be previewable");
        assertLt(preview.vpiDeltaUsdc, 0, "Frozen skew-healing close should keep the normal VPI rebate");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI field should clamp the signed rebate to zero");
        assertEq(preview.frozenSpreadUsdc, 400e6, "Frozen close should assess 50 bps of $80,000 notional");
        uint256 vpiRebateUsdc = uint256(-preview.vpiDeltaUsdc);
        uint256 expectedPaidSpreadUsdc =
            preview.frozenSpreadUsdc > vpiRebateUsdc ? preview.frozenSpreadUsdc - vpiRebateUsdc : 0;
        assertEq(
            preview.frozenSpreadPaidUsdc,
            expectedPaidSpreadUsdc,
            "Signed VPI rebate should offset frozen spread before physical collection"
        );
        assertEq(
            preview.frozenSpreadPaidUsdc + preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc,
            "VPI-offset and paid spread must conserve the assessment"
        );

        ICfdEngineTypes.ClosePreview memory partialPreview = engineLens.previewClose(account, 25_000e18, 0.8e8);
        assertTrue(partialPreview.valid, "Funded frozen reduction should be previewable");
        assertEq(partialPreview.frozenSpreadUsdc, 100e6, "A 25% reduction should assess $100 of fixed spread");
        uint256 partialVpiRebateUsdc = uint256(-partialPreview.vpiDeltaUsdc);
        assertEq(
            partialPreview.frozenSpreadPaidUsdc,
            partialPreview.frozenSpreadUsdc - partialVpiRebateUsdc,
            "Partial frozen spread should use the same signed-VPI offset ordering"
        );
    }

    function test_PreviewClose_OracleFrozenSkewWorseningCloseKeepsSignedVpiAndPaysSameFixedSpread() public {
        address longTrader = address(0xAB1313);
        address shortTrader = address(0xAB1314);
        _fundTrader(longTrader, 10_000e6);
        _fundTrader(shortTrader, 10_000e6);

        _open(longTrader, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);
        _open(shortTrader, CfdTypes.Side.SHORT, 150_000e18, 6000e6, 1e8);

        vm.warp(1_709_985_600);
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(longTrader, 100_000e18, 0.8e8);

        assertTrue(preview.valid, "Frozen close should be previewable");
        assertGt(preview.vpiDeltaUsdc, 0, "Frozen skew-worsening close should keep the normal positive VPI charge");
        assertEq(preview.vpiUsdc, uint256(preview.vpiDeltaUsdc), "Positive VPI field should expose the charge");
        assertEq(preview.frozenSpreadUsdc, 400e6, "Spread should depend on notional, not skew direction");
        assertEq(preview.frozenSpreadPaidUsdc, 400e6, "Funded frozen close should pay the same fixed spread");
        assertEq(preview.frozenSpreadWaivedUsdc, 0, "Funded frozen close should not waive spread");
    }

    function test_PreviewClose_OracleFrozenZeroCrossingCloseUsesNormalCurveAndFixedSpread() public {
        address longTrader = address(0xAB1315);
        address shortTrader = address(0xAB1316);
        _fundTrader(longTrader, 20_000e6);
        _fundTrader(shortTrader, 10_000e6);

        _open(longTrader, CfdTypes.Side.LONG, 200_000e18, 8000e6, 1e8);
        _open(shortTrader, CfdTypes.Side.SHORT, 100_000e18, 4000e6, 1e8);

        vm.warp(1_709_985_600);
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(longTrader, 150_000e18, 0.8e8);

        assertTrue(preview.valid, "Frozen partial close should be previewable");
        assertLt(preview.vpiDeltaUsdc, 0, "Zero crossing that reduces absolute skew should keep the normal rebate");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI field should clamp the signed rebate to zero");
        assertEq(preview.frozenSpreadUsdc, 600e6, "Spread should assess 50 bps of $120,000 notional");
        uint256 vpiRebateUsdc = uint256(-preview.vpiDeltaUsdc);
        assertEq(
            preview.frozenSpreadPaidUsdc,
            preview.frozenSpreadUsdc - vpiRebateUsdc,
            "Zero-crossing VPI rebate should offset frozen spread before collection"
        );
        assertEq(
            preview.frozenSpreadPaidUsdc + preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc,
            "Paid and VPI-offset spread must conserve the assessment"
        );
    }

    function test_PreviewClose_OracleFrozenFullCloseWaivesOnlyUncollectibleSpread() public {
        address trader = address(0xAB1318);
        address account = trader;
        _fundTrader(trader, 2000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.warp(1_709_985_600);
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1.019e8);

        assertTrue(preview.valid, "Terminal close should remain live when only spread is uncollectible");
        assertEq(preview.frozenSpreadUsdc, 509_500_000, "Spread should assess 50 bps of $101,900 notional");
        assertEq(preview.executionFeeUsdc, _engineExecutionFeeUsdc(100_000e18, 1.019e8));
        assertEq(
            preview.frozenSpreadPaidUsdc,
            clearinghouse.liquidationReserveUsdc(account) - preview.executionFeeUsdc,
            "Released liquidation reserve pays the fee before the residual frozen spread"
        );
        assertEq(
            preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc - preview.frozenSpreadPaidUsdc,
            "Only the spread exceeding released surplus should be waived"
        );
        assertEq(
            preview.frozenSpreadPaidUsdc + preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc,
            "Paid and waived spread should conserve the assessment"
        );
        assertEq(preview.badDebtUsdc, 0, "Waived spread should not become LP bad debt");

        vm.expectEmit(true, false, false, true, address(engine.settlementSidecar()));
        emit FrozenCloseSpreadSettled(
            account, preview.frozenSpreadUsdc, preview.frozenSpreadPaidUsdc, preview.frozenSpreadWaivedUsdc
        );
        _close(account, CfdTypes.Side.LONG, 100_000e18, 1.019e8);

        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0, "Full close should complete despite the waived spread");
        assertEq(
            terminalNavBook.curveHashOf(account),
            bytes32(0),
            "Terminal close should remove the account's exact terminal-NAV curve"
        );
    }

    function test_PreviewClose_OracleFrozenPartialCloseCannotWaiveSpread() public {
        address trader = address(0xAB1319);
        address account = trader;
        _fundTrader(trader, 2000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.warp(1_709_985_600);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 1.019e8);

        assertFalse(preview.valid, "Partial close must not evade an uncollectible frozen spread");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdTypes.CloseInvalidReason.PartialCloseUnhealthy),
            "An unhealthy remainder is diagnosed before fee funding"
        );
        assertEq(preview.badDebtUsdc, 0, "Spread-only shortfall should remain distinct from base bad debt");
    }

    function test_PreviewClose_RejectsUnhealthyReleaseWithoutTouchingQueuedBacking() public {
        address trader = address(0xAB1302);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 900e6, type(uint256).max, false);

        uint256 freeSettlementBeforePreview = _freeSettlementUsdc(account);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 110_000_000);

        assertFalse(preview.valid, "pledge cannot unlock into an unhealthy remainder");
        assertEq(uint8(preview.invalidReason), uint8(CfdTypes.CloseInvalidReason.PartialCloseUnhealthy));
        assertEq(_freeSettlementUsdc(account), freeSettlementBeforePreview);
    }

    function test_PreviewClose_ClampsOraclePriceToCap() public {
        address trader = address(0xAB1305);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.SHORT, 100_000e18, 4000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory cappedPreview = engineLens.previewClose(account, 100_000e18, 2e8);
        ICfdEngineTypes.ClosePreview memory overCapPreview = engineLens.previewClose(account, 100_000e18, 3e8);

        assertEq(
            overCapPreview.executionPrice,
            cappedPreview.executionPrice,
            "Preview execution price should clamp to CAP_PRICE"
        );
        assertEq(overCapPreview.realizedPnlUsdc, cappedPreview.realizedPnlUsdc, "Preview PnL should clamp to CAP_PRICE");
        assertEq(overCapPreview.vpiDeltaUsdc, cappedPreview.vpiDeltaUsdc, "Preview VPI should clamp to CAP_PRICE");
        assertEq(
            overCapPreview.executionFeeUsdc, cappedPreview.executionFeeUsdc, "Preview fee should clamp to CAP_PRICE"
        );
        assertEq(
            overCapPreview.immediatePayoutUsdc,
            cappedPreview.immediatePayoutUsdc,
            "Preview payout should clamp to CAP_PRICE"
        );
        assertEq(
            overCapPreview.traderClaimBalanceUsdc,
            cappedPreview.traderClaimBalanceUsdc,
            "Preview trader claim should clamp to CAP_PRICE"
        );
        assertEq(overCapPreview.badDebtUsdc, cappedPreview.badDebtUsdc, "Preview bad debt should clamp to CAP_PRICE");
    }

}
