// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract PerpsPublicLensTest is BasePerpTest {

    uint64 internal constant SATURDAY_NOON = 1_710_021_600;

    function test_GetTraderAccount_UsesNetEquityAndEngineAwareWithdrawable() public {
        address trader = address(0xA11CE);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(accountId);

        assertGt(clearinghouse.getFreeBuyingPowerUsdc(accountId), 0, "setup should leave free buying power");
        assertEq(viewData.equityUsdc, uint256(snapshot.netEquityUsdc), "public equity should use net economic equity");
        assertEq(
            viewData.withdrawableUsdc,
            engineAccountLens.getWithdrawableUsdc(accountId),
            "lens should use account-lens withdrawability"
        );
        assertEq(viewData.withdrawableUsdc, 0, "withdrawable should zero when engine withdraws are stale-blocked");
    }

    function test_GetTraderAccount_WithdrawableMatchesEngineAndActualWithdrawBound() public {
        address trader = address(0xBEEF);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(accountId);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(accountId);

        assertGt(withdrawableUsdc, 0, "setup should produce a positive withdrawable amount");
        assertEq(
            viewData.withdrawableUsdc, withdrawableUsdc, "lens should delegate withdrawability to the account lens"
        );

        vm.prank(trader);
        clearinghouse.withdraw(accountId, withdrawableUsdc);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(accountId, 1);
    }

    function test_GetTraderAccount_FlatAccountUsesSettlementEquity() public {
        address trader = address(0xF1A7);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 12_345e6);

        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(accountId);

        assertEq(viewData.equityUsdc, 12_345e6, "flat accounts should report settlement equity");
        assertEq(viewData.withdrawableUsdc, 12_345e6, "flat accounts should expose full engine withdrawability");
        assertFalse(viewData.hasOpenPosition, "flat account should not report an open position");
    }

    function test_GetPosition_PopulatesMaintenanceMargin() public {
        address trader = address(0xB0B);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(accountId);
        assertEq(
            viewData.maintenanceMarginUsdc,
            _maintenanceMarginUsdc(viewData.size, engine.lastMarkPrice()),
            "position view should expose the live maintenance margin requirement"
        );
    }

    function test_GetPosition_MirrorsAccountLensPositionState() public {
        address trader = address(0xB0B3);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 14 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(accountId);

        assertEq(viewData.exists, snapshot.hasPosition, "Public position existence should match account lens");
        assertEq(uint8(viewData.side), uint8(snapshot.side), "Public position side should match account lens");
        assertEq(viewData.size, snapshot.size, "Public position size should match account lens");
        assertEq(viewData.entryPrice, snapshot.entryPrice, "Public position entry price should match account lens");
        assertEq(viewData.marginUsdc, snapshot.margin, "Public position margin should match account lens");
        assertEq(
            viewData.unrealizedPnlUsdc,
            snapshot.unrealizedPnlUsdc,
            "Public unrealized pnl should match carry-aware account lens state"
        );
        assertEq(
            viewData.liquidatable,
            snapshot.liquidatable,
            "Public liquidatable flag should match carry-aware account lens state"
        );
    }

    function test_GetTraderAccount_UsesCarryAwareNetEquity() public {
        address trader = address(0xB0B1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(accountId);

        assertLt(
            snapshot.netEquityUsdc,
            int256(snapshot.accountEquityUsdc),
            "Carry-aware lens equity should be below raw settlement equity"
        );
        assertEq(
            viewData.equityUsdc, uint256(snapshot.netEquityUsdc), "Public equity should inherit carry-aware net equity"
        );
    }

    function test_IsLiquidatable_UsesCarryAwareLensState() public {
        address trader = address(0xB0B2);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 820e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 800e6, 1e8);

        assertFalse(publicLens.isLiquidatable(accountId), "Setup should start above maintenance before carry accrues");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 100 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        assertTrue(
            snapshot.liquidatable, "Account lens should become liquidatable once carry erodes maintenance headroom"
        );
        assertTrue(publicLens.isLiquidatable(accountId), "Public lens should inherit carry-aware liquidatability");
    }

    function test_GetLpStatus_UsesActualFrozenWindowFreshness() public {
        address trader = address(0xCAFE);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_NOON - 4 days));

        PerpsViewTypes.LpStatusView memory viewData = publicLens.getLpStatus();
        assertFalse(pool.getVaultLiquidityView().markFresh, "setup should make the frozen mark stale");
        assertFalse(viewData.oracleFresh, "LP status should mirror the actual house-pool freshness policy");
    }

}
