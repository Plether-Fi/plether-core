// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

contract PerpsReadParityTest is BasePerpTest {

    function test_OpenPreview_NewBullMatchesLiveOpenStorage() public {
        address trader = address(0xAA01);
        address account = trader;
        uint256 size = 100_000e18;
        uint256 margin = 9000e6;
        uint256 price = 1e8;
        uint64 publishTime = uint64(block.timestamp);
        _fundTrader(trader, 9500e6);

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(account, CfdTypes.Side.BULL, size, margin, price, publishTime);

        assertTrue(preview.valid, "Open preview should be valid");
        assertEq(uint8(preview.invalidReason), uint8(CfdEnginePlanTypes.OpenRevertCode.OK), "Open reason");
        assertEq(
            uint256(preview.failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.None),
            "Open failure category"
        );
        assertEq(preview.executionPrice, price, "Execution price should match");
        assertEq(preview.sizeDelta, size, "Size delta should match");
        assertEq(preview.notionalUsdc, 100_000e6, "Notional should match");
        assertEq(preview.marginDeltaUsdc, margin, "Margin delta should match");
        assertEq(preview.executionFeeUsdc, _engineExecutionFeeUsdc(size, price), "Execution fee should match");
        assertEq(preview.tradeCostUsdc, int256(preview.executionFeeUsdc), "Trade cost should match fee");
        assertEq(preview.initialMarginRequirementUsdc, 1500e6, "Initial margin should match");
        assertEq(preview.maintenanceMarginUsdc, 1000e6, "Maintenance margin should match");
        assertEq(preview.postSize, size, "Post size should match");
        assertEq(preview.postEntryPrice, price, "Post entry should match");
        assertEq(preview.postMarginUsdc, margin - preview.executionFeeUsdc, "Post margin should net fee");
        assertEq(preview.postVpiAccrued, 0, "Default VPI should be zero");
        assertEq(preview.postUnrealizedPnlUsdc, 0, "Post PnL at entry should be zero");
        assertEq(preview.postEquityUsdc, int256(9500e6 - preview.executionFeeUsdc), "Post equity should match");
        assertFalse(preview.postLiquidatable, "Post position should be healthy");
        assertTrue(preview.postHealthBps > 10_000, "Health should be above maintenance");
        assertTrue(preview.hasLiquidationPrice, "Bull should have a liquidation threshold");
        assertTrue(preview.liquidationPrice > price, "Bull liquidation should be above entry");

        ICfdEngineTypes.OpenPreview memory capped =
            engineLens.previewOpen(account, CfdTypes.Side.BULL, size, margin, CAP_PRICE + 1, publishTime);
        assertEq(capped.executionPrice, CAP_PRICE, "Execution price should cap");
        assertEq(capped.notionalUsdc, 200_000e6, "Capped notional should use cap price");

        _open(account, CfdTypes.Side.BULL, size, margin, price);

        (uint256 liveSize, uint256 liveMargin, uint256 liveEntryPrice,,, int256 liveVpiAccrued) =
            _livePositionPreviewFields(account);
        assertEq(liveSize, preview.postSize, "Live size should match preview");
        assertEq(liveMargin, preview.postMarginUsdc, "Live margin should match preview");
        assertEq(liveEntryPrice, preview.postEntryPrice, "Live entry should match preview");
        assertEq(liveVpiAccrued, preview.postVpiAccrued, "Live VPI accrued should match preview");
    }

    function test_OpenPreview_NewBearAndIncreaseExposePostTradeFields() public {
        address trader = address(0xAA02);
        address account = trader;
        uint256 firstSize = 80_000e18;
        uint256 secondSize = 20_000e18;
        uint256 price = 1e8;
        _fundTrader(trader, 20_000e6);

        ICfdEngineTypes.OpenPreview memory first =
            engineLens.previewOpen(account, CfdTypes.Side.BEAR, firstSize, 8000e6, price, uint64(block.timestamp));
        assertTrue(first.valid, "Bear open should be valid");
        assertEq(first.postSize, firstSize, "Bear post size should match");
        assertEq(first.postEntryPrice, price, "Bear post entry should match");
        assertTrue(first.hasLiquidationPrice, "Bear should have a liquidation threshold");
        assertTrue(first.liquidationPrice < price, "Bear liquidation should be below entry");

        _open(account, CfdTypes.Side.BEAR, firstSize, 8000e6, price);

        ICfdEngineTypes.OpenPreview memory increase = engineLens.previewOpen(
            account, CfdTypes.Side.BEAR, secondSize, 2000e6, 120_000_000, uint64(block.timestamp)
        );
        assertTrue(increase.valid, "Same-side increase should be valid");
        assertEq(increase.postSize, firstSize + secondSize, "Increase post size should add");
        assertEq(increase.postEntryPrice, 104_000_000, "Increase post entry should weighted-average");
        assertEq(increase.notionalUsdc, 24_000e6, "Increase notional should use execution price");
        assertEq(increase.executionFeeUsdc, _engineExecutionFeeUsdc(secondSize, 120_000_000), "Increase fee");
    }

    function test_OpenPreview_VpiChargeAndRebate() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.0005e18;
        _setRiskParams(params);

        address bullTrader = address(0xAA03);
        address bearTrader = address(0xAA04);
        uint256 size = 100_000e18;
        uint256 price = 1e8;
        _fundTrader(bullTrader, 20_000e6);
        _fundTrader(bearTrader, 20_000e6);

        ICfdEngineTypes.OpenPreview memory skewing =
            engineLens.previewOpen(bullTrader, CfdTypes.Side.BULL, size, 10_000e6, price, uint64(block.timestamp));
        assertTrue(skewing.valid, "Skewing open should be valid");
        assertTrue(skewing.vpiUsdc > 0, "Skewing open should pay VPI");
        assertEq(skewing.tradeCostUsdc, skewing.vpiUsdc + int256(skewing.executionFeeUsdc), "Charge trade cost");

        _open(bullTrader, CfdTypes.Side.BULL, size, 10_000e6, price);

        ICfdEngineTypes.OpenPreview memory healing =
            engineLens.previewOpen(bearTrader, CfdTypes.Side.BEAR, size, 10_000e6, price, uint64(block.timestamp));
        assertTrue(healing.valid, "Healing open should be valid");
        assertTrue(healing.vpiUsdc < 0, "Healing open should receive VPI rebate");
        assertEq(healing.tradeCostUsdc, healing.vpiUsdc + int256(healing.executionFeeUsdc), "Rebate trade cost");
        assertEq(healing.poolRebatePayoutUsdc, 0, "Fee-limited rebate should not create pool payout");
    }

    function test_OpenPreview_InvalidReasonMatchesLegacyPreviewMethods() public {
        address trader = address(0xAA05);
        address account = trader;
        _fundTrader(trader, 100e6);

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(account, CfdTypes.Side.BULL, 100_000e18, 0, 1e8, uint64(block.timestamp));
        uint8 legacyCode =
            engineLens.previewOpenRevertCode(account, CfdTypes.Side.BULL, 100_000e18, 0, 1e8, uint64(block.timestamp));
        CfdEnginePlanTypes.OpenFailurePolicyCategory legacyCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.BULL, 100_000e18, 0, 1e8, uint64(block.timestamp)
        );

        assertFalse(preview.valid, "Preview should be invalid");
        assertEq(uint8(preview.invalidReason), legacyCode, "Invalid reason should match legacy code");
        assertEq(uint256(preview.failureCategory), uint256(legacyCategory), "Failure category should match");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "Expected fee drain"
        );
    }

    function test_OpenPreview_LiquidationThresholdAgreesWithLiquidationPreview() public {
        address bullTrader = address(0xAA06);
        address bearTrader = address(0xAA07);
        uint256 size = 100_000e18;
        uint256 margin = 9000e6;
        uint256 price = 1e8;
        _fundTrader(bullTrader, 9500e6);
        _fundTrader(bearTrader, 9500e6);

        ICfdEngineTypes.OpenPreview memory bullPreview =
            engineLens.previewOpen(bullTrader, CfdTypes.Side.BULL, size, margin, price, uint64(block.timestamp));
        _open(bullTrader, CfdTypes.Side.BULL, size, margin, price);
        assertTrue(bullPreview.hasLiquidationPrice, "Bull threshold should exist");
        assertFalse(
            engineLens.previewLiquidation(bullTrader, bullPreview.liquidationPrice - 1).liquidatable,
            "Bull should be solvent below threshold"
        );
        assertTrue(
            engineLens.previewLiquidation(bullTrader, bullPreview.liquidationPrice).liquidatable,
            "Bull should liquidate at threshold"
        );

        ICfdEngineTypes.OpenPreview memory bearPreview =
            engineLens.previewOpen(bearTrader, CfdTypes.Side.BEAR, size, margin, price, uint64(block.timestamp));
        _open(bearTrader, CfdTypes.Side.BEAR, size, margin, price);
        assertTrue(bearPreview.hasLiquidationPrice, "Bear threshold should exist");
        assertTrue(
            engineLens.previewLiquidation(bearTrader, bearPreview.liquidationPrice).liquidatable,
            "Bear should liquidate at threshold"
        );
        assertFalse(
            engineLens.previewLiquidation(bearTrader, bearPreview.liquidationPrice + 1).liquidatable,
            "Bear should be solvent above threshold"
        );
    }

    function test_OpenPreview_NoLiquidationThresholdWhenFullyOvercollateralized() public {
        address trader = address(0xAA08);
        uint256 size = 100_000e18;
        uint256 price = 1e8;
        _fundTrader(trader, 310_000e6);

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(trader, CfdTypes.Side.BULL, size, 300_000e6, price, uint64(block.timestamp));

        assertTrue(preview.valid, "Overcollateralized open should be valid");
        assertFalse(preview.hasLiquidationPrice, "No in-range liquidation threshold should exist");
        assertEq(preview.liquidationPrice, 0, "Missing threshold price should be zero");
        _open(trader, CfdTypes.Side.BULL, size, 300_000e6, price);
        assertFalse(engineLens.previewLiquidation(trader, CAP_PRICE).liquidatable, "Cap price should stay solvent");
    }

    function test_ClosePreviewMatchesLive() public {
        address trader = address(0xAA11);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_LiquidationPreviewMatchesLive() public {
        address trader = address(0xAA12);
        address account = trader;
        address keeper = address(0xAA13);

        _fundTrader(trader, 900e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 70e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_AccountLensMirrorsLiveCustodyAndEngineState() public {
        address trader = address(0xAA14);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.AccountCollateralView memory collateralView =
            engineAccountLens.getAccountCollateralView(account);
        (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(account);

        assertEq(
            snapshot.settlementBalanceUsdc,
            clearinghouse.balanceUsdc(account),
            "Account lens settlement should match clearinghouse"
        );
        assertEq(
            snapshot.activePositionMarginUsdc,
            collateralView.activePositionMarginUsdc,
            "Active position margin should match collateral view"
        );
        assertEq(
            snapshot.otherLockedMarginUsdc,
            collateralView.otherLockedMarginUsdc,
            "Other locked margin should match collateral view"
        );
        assertEq(
            snapshot.freeSettlementUsdc,
            collateralView.freeSettlementUsdc,
            "Free settlement should match collateral view"
        );
        assertEq(
            snapshot.terminalReachableUsdc,
            collateralView.terminalReachableUsdc,
            "Terminal reachable collateral should match collateral view"
        );
        assertEq(
            snapshot.accountEquityUsdc, collateralView.accountEquityUsdc, "Account equity should match collateral view"
        );
        assertEq(
            snapshot.freeBuyingPowerUsdc,
            collateralView.freeBuyingPowerUsdc,
            "Buying power should match collateral view"
        );
        assertEq(
            snapshot.traderClaimBalanceUsdc,
            engine.traderClaimBalanceUsdc(account),
            "Trader claim should match engine state"
        );
        assertEq(snapshot.size, size, "Account lens size should match engine position");
        assertEq(snapshot.margin, margin, "Account lens margin should match engine position");
        assertEq(snapshot.entryPrice, entryPrice, "Account lens entry price should match engine position");
        assertEq(uint8(snapshot.side), uint8(side), "Account lens side should match engine position");
    }

    function test_PublicLensMirrorsAccountLens() public {
        address trader = address(0xAA15);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.TraderAccountView memory traderView = publicLens.getTraderAccount(account);
        PerpsViewTypes.PositionView memory positionView = publicLens.getPosition(account);

        assertEq(
            traderView.equityUsdc,
            uint256(snapshot.netEquityUsdc),
            "Public trader equity should match account lens net equity"
        );
        assertEq(
            traderView.withdrawableUsdc,
            engineAccountLens.getWithdrawableUsdc(account),
            "Public withdrawable should match account lens"
        );
        assertEq(
            traderView.hasOpenPosition, snapshot.hasPosition, "Public open-position flag should match account lens"
        );
        assertEq(traderView.liquidatable, snapshot.liquidatable, "Public liquidatable flag should match account lens");
        assertEq(positionView.exists, snapshot.hasPosition, "Public position existence should match account lens");
        assertEq(positionView.size, snapshot.size, "Public position size should match account lens");
        assertEq(positionView.marginUsdc, snapshot.margin, "Public position margin should match account lens");
        assertEq(positionView.entryPrice, snapshot.entryPrice, "Public position entry price should match account lens");
        assertEq(positionView.unrealizedPnlUsdc, snapshot.unrealizedPnlUsdc, "Public pnl should match account lens");
        assertEq(positionView.liquidatable, snapshot.liquidatable, "Public liquidatable should match account lens");
    }

    function test_ProtocolLensMirrorsPostOpProtocolSnapshot() public {
        address trader = address(0xAA16);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            protocolSnapshot.poolAssetsUsdc, pool.totalAssets(), "Protocol lens pool assets should match pool assets"
        );
        assertEq(
            protocolSnapshot.withdrawalReservedUsdc,
            _withdrawalReservedUsdc(),
            "Protocol lens reserved cash should match live reservation state"
        );
        assertEq(
            protocolSnapshot.protocolTreasuryBalanceUsdc,
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Protocol lens fees should match engine state"
        );
        assertEq(
            protocolSnapshot.accumulatedBadDebtUsdc,
            engine.accumulatedBadDebtUsdc(),
            "Protocol lens bad debt should match engine state"
        );
        assertEq(
            protocolSnapshot.totalTraderClaimBalanceUsdc,
            engine.totalTraderClaimBalanceUsdc(),
            "Protocol lens trader claim balance should match engine state"
        );
        assertEq(
            protocolSnapshot.degradedMode,
            engine.degradedMode(),
            "Protocol lens degraded mode should match engine state"
        );
        assertEq(
            protocolSnapshot.maxLiabilityUsdc,
            _maxLiability(),
            "Protocol lens max liability should match live side state"
        );
    }

    function _livePositionPreviewFields(
        address account
    )
        internal
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            int256 vpiAccrued
        )
    {
        (size, margin, entryPrice, maxProfitUsdc, side,, vpiAccrued) = engine.positions(account);
    }

}
