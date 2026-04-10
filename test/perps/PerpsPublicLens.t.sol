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
