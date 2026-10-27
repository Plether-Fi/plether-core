// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineExecutionParityTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_OpenParity_HealthyPreviewMatchesLiveExecution() public {
        address account = address(uint160(0xBEEF2));
        _fundTrader(account, 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Preview should accept the healthy open"
        );

        uint256 feesBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);

        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        assertEq(size, 100_000e18, "Live open should match the previewed size");
        assertGt(margin, 0, "Live open should leave positive position margin");
        assertLt(margin, 5000e6, "Live open margin should reflect execution costs after the successful preview");
        assertGt(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - feesBefore,
            0,
            "Live open should collect protocol revenue after success"
        );
    }

    function test_CloseParity_ImmediateProfitMatchesPreview() public {
        address trader = address(0xD3A1);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertGt(preview.immediatePayoutAssets, 0, "Profitable liquid close should pay immediately");
        assertEq(preview.traderClaimBalanceAssets, 0, "Liquid profitable close should not defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_TraderClaimProfitMatchesPreview() public {
        address trader = address(0xD3A2);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutAssets, 0, "Illiquid profitable close should not pay immediately");
        assertGt(preview.traderClaimBalanceAssets, 0, "Illiquid profitable close should defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_LossConsumesSettlementMatchesPreview() public {
        address trader = address(0xD3A3);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 5000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 10_000e18, 120_000_000);
        assertTrue(preview.valid, "Setup loss close preview should be valid");
        assertEq(preview.immediatePayoutAssets, 0, "Loss-making close should not create immediate payout");
        assertEq(preview.traderClaimBalanceAssets, 0, "Loss-making close should not create trader claim");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.LONG, 10_000e18, 120_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_PreviewClose_TriggersDegradedModeMatchesLiveClose() public {
        address longTrader = address(0xAB1308);
        address shortTrader = address(0xAB1309);
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(longAccount, 500_000e18, 20_000_000);
        assertTrue(preview.triggersDegradedMode, "Preview should flag the profitable close that reveals insolvency");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(longAccount);
        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);

        CloseParityObserved memory observed = _observeCloseParity(longAccount, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertTrue(engine.degradedMode(), "Live close should match preview degraded-mode trigger");
    }

    function test_PreviewClose_OracleFrozenFixedSpreadMatchesLiveCloseAndStaysOutOfTreasury() public {
        address trader = address(0xAB1317);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        vm.warp(1_709_985_600);
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 0.8e8);
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());

        _close(account, CfdTypes.Side.LONG, 100_000e18, 0.8e8);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);

        assertLt(preview.vpiDeltaAssets, 0, "Frozen close should preserve normal signed VPI");
        assertEq(preview.frozenSpreadAssets, 400e6, "Preview should assess the configured fixed spread");
        uint256 vpiRebateAssets = uint256(-preview.vpiDeltaAssets);
        assertEq(
            preview.frozenSpreadPaidAssets,
            preview.frozenSpreadAssets - vpiRebateAssets,
            "Preview should offset the signed VPI rebate before collecting frozen spread"
        );
        assertEq(
            preview.frozenSpreadPaidAssets + preview.frozenSpreadWaivedAssets,
            preview.frozenSpreadAssets,
            "Previewed paid and offset spread must conserve the assessment"
        );
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            preview.executionFeeAssets,
            "Treasury should receive the execution fee but none of the LP-owned frozen spread"
        );
    }

    function test_PreviewClose_UnderwaterPartialMatchesLiveRevert() public {
        address juniorLp = address(0xAB1306);
        address trader = address(0xAB1307);
        _fundJunior(juniorLp, 1_000_000 * 1e6);
        _fundTrader(trader, 22_000 * 1e6);

        address account = trader;
        _open(account, CfdTypes.Side.SHORT, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000 * 1e18, 80_000_000);
        (uint256 sizeBefore, uint256 marginBefore,,,,,) = engine.positions(account);

        assertFalse(preview.valid);
        assertEq(uint8(preview.invalidReason), uint8(CfdTypes.CloseInvalidReason.PartialCloseUnhealthy));
        uint256 depth = pool.totalAssets();
        vm.expectRevert(
            abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, uint8(1), uint8(6), true)
        );
        _close(account, CfdTypes.Side.SHORT, 100_000e18, 0.8e8, depth);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, sizeBefore, "Rejected close preserves size");
        assertEq(marginAfter, marginBefore, "Rejected close preserves pledge");
        _assertTerminalCurveMatchesEngine(account);
    }

    function test_PreviewClose_FullLossWriteoffMatchesLiveSettlement() public {
        address trader = address(0xAB1304);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 110_000_000);
        uint256 collectibleCapAssets =
            engineAccountLens.getAccountLedgerSnapshot(account).terminalPriceCollectibleCapAssets;
        uint256 poolAssetsBefore = pool.totalAssets();

        assertTrue(preview.valid, "Terminal price tail must not block a full close");
        assertLt(preview.realizedPnlAssets, 0, "Setup must realize a terminal price loss");
        uint256 priceLossAssets = uint256(-preview.realizedPnlAssets);
        assertGt(priceLossAssets, collectibleCapAssets, "Setup must exceed the exact price collectible cap");
        assertEq(preview.seizedCollateralAssets, collectibleCapAssets, "Preview must collect the exact price cap only");

        uint256 writtenOffAssets = priceLossAssets - collectibleCapAssets;
        vm.expectEmit(true, false, false, true, address(engine.settlementSidecar()));
        emit PriceLossWrittenOff(account, writtenOffAssets);
        _close(account, CfdTypes.Side.LONG, 100_000e18, 110_000_000);

        assertEq(
            pool.totalAssets() - poolAssetsBefore,
            collectibleCapAssets,
            "Only the exact collectible price cap should become LP cash"
        );
        assertEq(
            terminalNavBook.curveHashOf(account),
            bytes32(0),
            "A full-loss close should remove the exact terminal-NAV curve instead of creating a debt ledger"
        );
        assertFalse(
            engine.degradedMode(), "A terminal price write-off must not create protocol debt or degrade the engine"
        );
    }

    function test_LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold() public {
        address trader = address(0xAB1401);
        address account = trader;
        uint256 poolDepth = pool.totalAssets();
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        vm.warp(block.timestamp + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(vm.getBlockTimestamp()));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 110_000_000);

        assertTrue(viewData.liquidatable, "Position view should use current notional for maintenance threshold");
        assertTrue(preview.liquidatable, "Liquidation preview should use current notional for maintenance threshold");

        vm.prank(address(router));
        engine.liquidatePosition(account, 110_000_000, poolDepth, uint64(vm.getBlockTimestamp()), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Live liquidation should agree with preview and position view");
    }

    function test_LiquidationParity_ImmediatePayoutMatchesPreview() public {
        address trader = address(0xAB14A1);
        address keeper = address(0xAB14A2);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        assertTrue(preview.liquidatable, "Setup liquidation preview should be liquidatable");

        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_LiquidationPreview_InterfaceMatchesContractStructLayout() public {
        address trader = address(0xAB1402);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        ICfdEngineTypes.LiquidationPreview memory contractPreview = engineLens.previewLiquidation(account, 110_000_000);
        ICfdEngineTypes.LiquidationPreview memory interfacePreview = engineLens.previewLiquidation(account, 110_000_000);

        assertEq(interfacePreview.liquidatable, contractPreview.liquidatable);
        assertEq(interfacePreview.oraclePrice, contractPreview.oraclePrice);
        assertEq(interfacePreview.equityAssets, contractPreview.equityAssets);
        assertEq(interfacePreview.pnlAssets, contractPreview.pnlAssets);
        assertEq(interfacePreview.reachableCollateralAssets, contractPreview.reachableCollateralAssets);
        assertEq(interfacePreview.liquidationChargeAssets, contractPreview.liquidationChargeAssets);
        assertEq(interfacePreview.keeperBountyAssets, contractPreview.keeperBountyAssets);
        assertEq(interfacePreview.protocolLiquidationFeeAssets, contractPreview.protocolLiquidationFeeAssets);
        assertEq(interfacePreview.lpLiquidationFeeAssets, contractPreview.lpLiquidationFeeAssets);
        assertEq(interfacePreview.seizedCollateralAssets, contractPreview.seizedCollateralAssets);
        assertEq(interfacePreview.immediatePayoutAssets, contractPreview.immediatePayoutAssets);
        assertEq(interfacePreview.traderClaimBalanceAssets, contractPreview.traderClaimBalanceAssets);
        assertEq(interfacePreview.triggersDegradedMode, contractPreview.triggersDegradedMode);
        assertEq(interfacePreview.postOpDegradedMode, contractPreview.postOpDegradedMode);
        assertEq(interfacePreview.effectiveAssetsAfterAssets, contractPreview.effectiveAssetsAfterAssets);
        assertEq(interfacePreview.maxLiabilityAfterAssets, contractPreview.maxLiabilityAfterAssets);
    }

    function test_LiquidationPreview_IlliquidTraderClaimMatchesLiveOutcome() public {
        address trader = address(0xAB1404);
        address keeper = address(0xAB1405);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 1);

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.traderClaimBalanceAssets(account),
            preview.traderClaimBalanceAssets,
            "Illiquid liquidation preview should match live trader claim balance"
        );
        assertEq(
            terminalNavBook.curveHashOf(account),
            bytes32(0),
            "Illiquid terminal liquidation must still remove the authenticated account curve"
        );
    }

    function test_PreviewLiquidation_TriggersDegradedModeMatchesLiveLiquidation() public {
        address trader = address(0xAB1410);
        address keeper = address(0xAB1411);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome"
        );
    }

    function test_CheckWithdrawParity_FailThenLiveWithdrawReverts() public {
        address trader = address(0x515816);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        WithdrawParityState memory state = _observeWithdrawParity(account, trader, 5000e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_CheckWithdrawParity_StaleLiveMarkBlocksWithdraw() public {
        address trader = address(0x515817);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        WithdrawParityState memory state = _observeWithdrawParity(account, trader, 100e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
    }

}
