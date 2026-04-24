// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract PerpsReadParityTest is BasePerpTest {

    function test_ClosePreviewMatchesLive() public {
        address trader = address(0xAA11);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
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

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
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
        CfdEngine.AccountCollateralView memory collateralView = engineAccountLens.getAccountCollateralView(account);
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
            snapshot.deferredTraderCreditUsdc,
            engine.deferredTraderCreditUsdc(account),
            "Deferred payout should match engine state"
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
            protocolSnapshot.vaultAssetsUsdc, pool.totalAssets(), "Protocol lens vault assets should match pool assets"
        );
        assertEq(
            protocolSnapshot.withdrawalReservedUsdc,
            _withdrawalReservedUsdc(),
            "Protocol lens reserved cash should match live reservation state"
        );
        assertEq(
            protocolSnapshot.accumulatedFeesUsdc,
            engine.accumulatedFeesUsdc(),
            "Protocol lens fees should match engine state"
        );
        assertEq(
            protocolSnapshot.accumulatedBadDebtUsdc,
            engine.accumulatedBadDebtUsdc(),
            "Protocol lens bad debt should match engine state"
        );
        assertEq(
            protocolSnapshot.totalDeferredTraderCreditUsdc,
            engine.totalDeferredTraderCreditUsdc(),
            "Protocol lens deferred trader credit should match engine state"
        );
        assertEq(
            protocolSnapshot.totalDeferredKeeperCreditUsdc,
            engine.totalDeferredKeeperCreditUsdc(),
            "Protocol lens deferred keeper credit should match engine state"
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

}
