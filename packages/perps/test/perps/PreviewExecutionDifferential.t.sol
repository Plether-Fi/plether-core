// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

contract PreviewExecutionDifferentialTest is BasePerpTest {

    address internal constant KEEPER = address(0xC0FFEE);

    struct CloseExecutionCheckpoint {
        IMarginClearinghouse.AccountUsdcBuckets bucketsBefore;
        uint256 settlementBefore;
        uint256 traderClaimBefore;
        uint256 executionBountyUsdc;
    }

    function testFuzz_PreviewOpen_MatchesLiveExecution_AfterCarryAndSkew(
        bool isLong,
        uint256 initialMarginFuzz,
        uint256 marginDeltaFuzz,
        uint256 sizeDeltaFuzz,
        uint256 oraclePriceFuzz,
        uint256 carryDelayFuzz
    ) public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.0002e18;
        _setRiskParams(params);

        address trader = address(0xC109);
        address account = trader;
        CfdTypes.Side side = isLong ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;
        uint256 initialMargin = bound(initialMarginFuzz, 20_000e6, 70_000e6);
        uint256 marginDelta = bound(marginDeltaFuzz, 0, 40_000e6);
        uint256 sizeDelta = bound(sizeDeltaFuzz, 1000e18, 40_000e18);
        uint256 oraclePrice = bound(oraclePriceFuzz, 80_000_000, 120_000_000);
        uint256 carryDelay = bound(carryDelayFuzz, 1 days, 60 days);

        _fundTrader(trader, 150_000e6);
        _open(account, side, 75_000e18, initialMargin, 1e8);
        vm.warp(block.timestamp + carryDelay);

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp));
        vm.assume(preview.valid);
        assertGt(preview.pendingCarryUsdc, 0, "Setup should exercise pending carry realization");

        _executeOpen(account, side, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp));

        _assertOpenPreviewMatchesLive(account, side, preview);
    }

    function test_PreviewOpen_VpiRebateMatchesLiveExecution() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.0005e18;
        _setRiskParams(params);

        address longTrader = address(0xC10A);
        address shortTrader = address(0xC10B);
        _fundTrader(longTrader, 20_000e6);
        _fundTrader(shortTrader, 20_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        ICfdEngineTypes.OpenPreview memory preview = engineLens.previewOpen(
            shortTrader, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, uint64(block.timestamp)
        );
        assertTrue(preview.valid, "Healing open should be valid");
        assertLt(preview.vpiUsdc, 0, "Healing open should receive a VPI rebate");

        _executeOpen(shortTrader, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, uint64(block.timestamp));

        _assertOpenPreviewMatchesLive(shortTrader, CfdTypes.Side.SHORT, preview);
    }

    function testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution(
        uint256 initialMarginFuzz,
        uint256 marginDeltaFuzz,
        uint256 sizeDeltaFuzz,
        uint256 oraclePriceFuzz,
        uint256 carryDelayFuzz
    ) public {
        address trader = address(0xC108);
        address account = trader;
        uint256 initialMargin = bound(initialMarginFuzz, 5000e6, 25_000e6);
        uint256 sizeDelta = bound(sizeDeltaFuzz, 1000e18, 50_000e18);
        uint256 oraclePrice = bound(oraclePriceFuzz, 80_000_000, 120_000_000);
        uint256 carryDelay = bound(carryDelayFuzz, 0, 30 days);

        _fundTrader(trader, 60_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, initialMargin, 1e8);

        if (carryDelay > 0) {
            vm.warp(block.timestamp + carryDelay);
        }

        uint256 marginDelta = bound(marginDeltaFuzz, 0, _freeSettlementUsdc(account));
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: oraclePrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp)
        );

        vm.assume(revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.OK));
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.None),
            "Valid preview open should not carry a failure category"
        );

        vm.startPrank(address(router));
        try engine.processOrderTyped(order, oraclePrice, pool.totalAssets(), uint64(block.timestamp)) {
            vm.stopPrank();
        } catch (bytes memory revertData) {
            vm.stopPrank();
            assertEq(
                _revertSelector(revertData),
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                "Valid preview open unexpectedly hit an untyped revert"
            );
            fail("Valid preview open unexpectedly reverted on the live open path");
        }
    }

    function _executeOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) internal {
        uint256 poolDepthUsdc = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: sizeDelta,
                marginDelta: marginDelta,
                targetPrice: oraclePrice,
                commitTime: publishTime,
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            oraclePrice,
            poolDepthUsdc,
            publishTime
        );
    }

    function _assertOpenPreviewMatchesLive(
        address account,
        CfdTypes.Side side,
        ICfdEngineTypes.OpenPreview memory preview
    ) internal view {
        (
            uint256 liveSize,
            uint256 liveMargin,
            uint256 liveEntryPrice,,
            CfdTypes.Side liveSide,,
            int256 liveVpiAccrued
        ) = engine.positions(account);
        assertEq(uint256(liveSide), uint256(side), "Open preview side should match live execution");
        assertEq(liveSize, preview.postSize, "Open preview size should match live execution");
        assertEq(liveMargin, preview.postMarginUsdc, "Open preview margin should match live execution");
        assertEq(liveEntryPrice, preview.postEntryPrice, "Open preview entry should match live execution");
        assertEq(liveVpiAccrued, preview.postVpiAccrued, "Open preview VPI accrual should match live execution");
        assertEq(engine.unsettledCarryUsdc(account), 0, "Valid open should clear realizable pending carry");

        ICfdEngineTypes.LiquidationPreview memory liquidationAtExecution =
            engineLens.previewLiquidation(account, preview.executionPrice);
        assertEq(
            liquidationAtExecution.pnlUsdc,
            preview.postUnrealizedPnlUsdc,
            "Open preview PnL should match post-execution liquidation lens"
        );
        int256 liveEquityUsdc = _liveOpenExactPriceEquityUsdc(account, liquidationAtExecution.pnlUsdc);
        assertEq(liveEquityUsdc, preview.postEquityUsdc, "Open preview equity should match live P+C price equity");
        assertEq(
            liquidationAtExecution.liquidatable,
            preview.postLiquidatable,
            "Open preview liquidatable flag should match post-execution liquidation lens"
        );

        uint256 liveMaintenanceMarginUsdc = _maintenanceMarginUsdc(preview.postSize, preview.executionPrice);
        assertEq(
            preview.maintenanceMarginUsdc,
            liveMaintenanceMarginUsdc,
            "Open preview maintenance margin should match live risk config"
        );
        assertEq(
            preview.postHealthBps,
            _healthBps(preview.postEquityUsdc, liveMaintenanceMarginUsdc),
            "Open preview health should match live risk inputs"
        );
        _assertOpenLiquidationThresholdMatchesLive(account, side, preview);
    }

    function _liveOpenExactPriceEquityUsdc(
        address account,
        int256 livePnlUsdc
    ) internal view returns (int256 equityUsdc) {
        uint256 priceCollateralUsdc = clearinghouse.pnlPledgeUsdc(account) + engine.traderClaimBalanceUsdc(account);
        equityUsdc = int256(priceCollateralUsdc) + livePnlUsdc;
    }

    function _assertOpenLiquidationThresholdMatchesLive(
        address account,
        CfdTypes.Side side,
        ICfdEngineTypes.OpenPreview memory preview
    ) internal view {
        if (!preview.hasLiquidationPrice) {
            assertFalse(
                engineLens.previewLiquidation(account, 0).liquidatable,
                "Missing threshold should mean zero price is solvent"
            );
            assertFalse(
                engineLens.previewLiquidation(account, CAP_PRICE).liquidatable,
                "Missing threshold should mean cap price is solvent"
            );
            return;
        }

        assertTrue(
            engineLens.previewLiquidation(account, preview.liquidationPrice).liquidatable,
            "Returned liquidation threshold should be liquidatable"
        );
        if (side == CfdTypes.Side.LONG) {
            if (preview.liquidationPrice > 0) {
                assertFalse(
                    engineLens.previewLiquidation(account, preview.liquidationPrice - 1).liquidatable,
                    "LONG should be solvent below liquidation threshold"
                );
            }
            return;
        }

        if (preview.liquidationPrice < CAP_PRICE) {
            assertFalse(
                engineLens.previewLiquidation(account, preview.liquidationPrice + 1).liquidatable,
                "SHORT should be solvent above liquidation threshold"
            );
        }
    }

    function _healthBps(
        int256 equityUsdc,
        uint256 maintenanceMarginUsdc
    ) internal pure returns (uint256 healthBps) {
        if (equityUsdc <= 0 || maintenanceMarginUsdc == 0) {
            return 0;
        }
        return (uint256(equityUsdc) * 10_000) / maintenanceMarginUsdc;
    }

    function testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault(
        uint256 closePriceFuzz
    ) public {
        address trader = address(0xC100);
        address account = trader;
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);
        closePrice -= closePrice % 2;

        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint64 closeOrderId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        uint256 executionBountyUsdc = _executionBountyReserve(closeOrderId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        vm.assume(preview.valid);

        CloseExecutionCheckpoint memory checkpoint = _closeExecutionCheckpoint(account, executionBountyUsdc);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(closePrice)), 0, int32(-8), block.timestamp, block.timestamp - 1
        );
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        _assertFullClosePreviewMatchesLive(account, preview, checkpoint);
    }

    function testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault(
        uint256 closePriceFuzz
    ) public {
        address trader = address(0xC101);
        address account = trader;
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);
        closePrice -= closePrice % 2;

        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        uint64 closeOrderId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        uint256 executionBountyUsdc = _executionBountyReserve(closeOrderId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        vm.assume(preview.valid);

        CloseExecutionCheckpoint memory checkpoint = _closeExecutionCheckpoint(account, executionBountyUsdc);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(closePrice)), 0, int32(-8), block.timestamp, block.timestamp - 1
        );
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        _assertFullClosePreviewMatchesLive(account, preview, checkpoint);
    }

    function _closeExecutionCheckpoint(
        address account,
        uint256 executionBountyUsdc
    ) internal view returns (CloseExecutionCheckpoint memory checkpoint) {
        checkpoint.bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        checkpoint.settlementBefore = clearinghouse.balanceUsdc(account);
        checkpoint.traderClaimBefore = engine.traderClaimBalanceUsdc(account);
        checkpoint.executionBountyUsdc = executionBountyUsdc;
    }

    function _assertFullClosePreviewMatchesLive(
        address account,
        ICfdEngineTypes.ClosePreview memory preview,
        CloseExecutionCheckpoint memory checkpoint
    ) internal view {
        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        uint256 expectedSettlement = checkpoint.settlementBefore + preview.immediatePayoutUsdc
            - preview.seizedCollateralUsdc - checkpoint.executionBountyUsdc;

        assertEq(sizeAfter, preview.remainingSize, "Close preview remaining size should match live execution");
        assertEq(marginAfter, preview.remainingMargin, "Close preview remaining margin should match live execution");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            checkpoint.bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc
                - checkpoint.executionBountyUsdc,
            "Close preview should match the live settlement-balance mutation"
        );
        assertEq(
            bucketsAfter.activePositionMarginUsdc,
            preview.remainingMargin,
            "Close preview remaining margin should match the live position-margin bucket"
        );
        assertEq(
            bucketsAfter.totalLockedMarginUsdc,
            preview.remainingMargin,
            "Full close should leave no locked margin beyond the surviving position margin"
        );
        assertEq(
            clearinghouse.balanceUsdc(account), expectedSettlement, "Close preview settlement delta should match live"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account) - checkpoint.traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Close preview trader claim should match live trader claim delta"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 close write-off must not create accumulated debt");
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Close preview degraded-mode flag should match live outcome"
        );
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function test_PreviewClose_PartialCloseMatchesLiveExecution_AfterPositiveCarryAccrual() public {
        address longTrader = address(0xC103);
        address shortTrader = address(0xC104);
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        _fundJunior(address(0xC105), 1_000_000e6);
        _fundTrader(longTrader, 80_000e6);
        _fundTrader(shortTrader, 80_000e6);

        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 30_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(shortAccount, 50_000e18, 1e8);
        assertTrue(preview.valid, "Positive-carry partial close preview should remain valid");

        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(shortAccount);

        _close(shortAccount, CfdTypes.Side.SHORT, 50_000e18, 1e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(shortAccount);
        assertEq(sizeAfter, preview.remainingSize, "Partial close preview remaining size should match live execution");
        assertEq(
            marginAfter, preview.remainingMargin, "Partial close preview remaining margin should match live execution"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(shortAccount) - traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Partial close preview trader claim should match live trader claim delta"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 partial-close write-off must not create accumulated debt");
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Partial close preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.postOpDegradedMode,
            engine.degradedMode(),
            "Partial close preview post-op degraded flag should match live outcome"
        );
        _assertTerminalCurveMatchesEngine(shortAccount);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function test_PreviewClose_PartialCloseIgnoresQueuedCommittedMarginInLiveExecution() public {
        address trader = address(0xC106);
        address account = trader;

        _fundJunior(address(0xC107), 1_000_000e6);
        _fundTrader(trader, 8000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 4000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 900e6, type(uint256).max, false);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Keep the surviving position solvent so this remains a Router reservation-isolation regression. V2
        // intentionally terminalizes underwater partial closes at the post-position-equity policy boundary.
        uint256 executionPrice = 102_000_000;
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, executionPrice);
        assertTrue(preview.valid, "Partial close preview should remain valid without queued margin support");

        uint256 committedBefore = _remainingCommittedMargin(2);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(executionPrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Queued-margin partial close size should match preview");
        assertEq(marginAfter, preview.remainingMargin, "Queued-margin partial close margin should match preview");
        assertEq(
            _remainingCommittedMargin(2), committedBefore, "Queued open-order committed margin must remain untouched"
        );
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.keeperShareBps = 2500;
        params.protocolShareBps = 2500;
        _setRiskParams(params);

        address trader = address(0xC102);
        address account = trader;
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);
        liquidationPrice -= liquidationPrice % 2;

        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 protocolTreasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(account);
        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Liquidation should fully clear the position");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc
                - preview.keeperBountyUsdc - preview.protocolLiquidationFeeUsdc,
            "Liquidation preview should match the live settlement-balance mutation"
        );
        assertEq(bucketsAfter.activePositionMarginUsdc, 0, "Liquidation should clear the live position-margin bucket");
        assertEq(bucketsAfter.totalLockedMarginUsdc, 0, "Liquidation should clear all locked margin in the simple path");
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Liquidation preview keeper bounty should match live clearinghouse credit"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - protocolTreasuryBefore,
            preview.protocolLiquidationFeeUsdc,
            "Liquidation preview protocol fee should match live treasury credit"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account) - traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Liquidation preview trader claim should match live trader claim delta"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 liquidation write-off must not create accumulated debt");
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.freshTraderPayoutUsdc,
            preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy trader claim exists"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc, 0, "Fresh liquidation path should not consume legacy trader claim"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc, 0, "Fresh liquidation path should not leave legacy trader claim"
        );
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        address trader = address(0xC103);
        address account = trader;
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);
        liquidationPrice -= liquidationPrice % 2;

        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(account);
        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Illiquid liquidation should fully clear the position");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc
                - preview.keeperBountyUsdc - preview.protocolLiquidationFeeUsdc,
            "Illiquid liquidation preview should match the live settlement-balance mutation"
        );
        assertEq(bucketsAfter.activePositionMarginUsdc, 0, "Illiquid liquidation should clear the live position margin");
        assertEq(
            bucketsAfter.totalLockedMarginUsdc,
            0,
            "Illiquid liquidation should clear all locked margin in the simple path"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Illiquid liquidation preview keeper bounty should match live clearinghouse credit"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account) - traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Illiquid liquidation preview trader claim should match live trader claim delta"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 illiquid liquidation write-off must not create accumulated debt");
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Illiquid liquidation preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.freshTraderPayoutUsdc,
            preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy trader claim exists"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Fresh illiquid liquidation path should not consume legacy trader claim"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc,
            0,
            "Fresh illiquid liquidation path should not leave legacy trader claim"
        );
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function test_PreviewLiquidation_IncludesIncomingSeizureWhenRoutingFreshPayout() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.keeperShareBps = 2500;
        params.protocolShareBps = 2500;
        _setRiskParams(params);

        address trader = address(0xC10C);
        address account = trader;
        uint256 liquidationPrice = 99_500_000;

        vm.warp(1_729_283_399); // Friday 20:29:59 UTC, immediately before the daylight-time FAD window.
        _fundTrader(trader, 200e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);
        vm.warp(1_729_283_400); // Friday 20:30:00 UTC, when the higher FAD margin becomes active.

        uint256 targetPoolCash = 48e6;
        uint256 poolCash = usdc.balanceOf(address(pool));
        assertGt(poolCash, targetPoolCash, "Setup should have enough pool cash to create the boundary");
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolCash - targetPoolCash);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        assertTrue(preview.liquidatable, "FAD margin should make the profitable position liquidatable");
        assertGt(preview.freshTraderPayoutUsdc, 0, "Setup should produce a fresh trader payout");
        assertGt(preview.seizedCollateralUsdc, 0, "Setup should transfer the LP fee to the pool");
        assertLt(targetPoolCash, preview.freshTraderPayoutUsdc, "Pre-seizure cash should be insufficient");
        assertGe(
            targetPoolCash + preview.seizedCollateralUsdc,
            preview.freshTraderPayoutUsdc,
            "Incoming seizure should make the fresh payout serviceable"
        );
        assertEq(
            preview.immediatePayoutUsdc,
            preview.freshTraderPayoutUsdc,
            "Preview should include incoming seizure before routing the fresh payout"
        );
        assertEq(preview.traderClaimBalanceUsdc, 0, "Preview should not create a serviceable trader claim");

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(account);
        uint256 protocolTreasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc
                - preview.keeperBountyUsdc - preview.protocolLiquidationFeeUsdc,
            "Previewed immediate payout should match the live settlement mutation"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - protocolTreasuryBefore,
            preview.protocolLiquidationFeeUsdc,
            "Previewed protocol fee should match the live treasury credit"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account) - traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Previewed trader claim should match live routing at the seizure boundary"
        );
    }

    function test_PreviewLiquidation_MatchesLiveExecution_WithQueuedExecutionReservationOutsideReachability() public {
        address trader = address(0xC104);
        address account = trader;
        uint256 liquidationPrice = 102_500_000;

        _fundTrader(trader, 260e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 vpiRebateReserveBefore = clearinghouse.vpiRebateReserveUsdc(account);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(account);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        assertEq(
            preview.reachableCollateralUsdc,
            snapshotBefore.terminalPriceCollectibleCapUsdc + vpiRebateReserveBefore,
            "Liquidation preview must expose the exact terminal price cap plus only its dedicated VPI reserve"
        );
        assertEq(
            snapshotBefore.liquidationReachableSettlementUsdc,
            snapshotBefore.settlementBalanceUsdc - snapshotBefore.executionBountyReserveUsdc,
            "Account liquidation custody should exclude the queued execution bounty"
        );
        assertLt(
            preview.reachableCollateralUsdc,
            snapshotBefore.liquidationReachableSettlementUsdc,
            "Generic free settlement must remain outside terminal price reachability"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Queued-reservation liquidation preview keeper bounty should match live outcome"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account) - traderClaimBefore,
            preview.traderClaimBalanceUsdc,
            "Queued-reservation liquidation preview trader claim should match live outcome"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 queued-reservation liquidation must not create accumulated debt");
        assertEq(
            usdc.balanceOf(address(router)),
            0,
            "Queued execution reservation should be removed from the router on liquidation"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Queued-reservation liquidation preview degraded-mode flag should match live outcome"
        );
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

}
