// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

contract PositionProtectionViewsStub is IPositionProtectionViews {

    mapping(address => uint64) internal activeProtectionIds;
    mapping(uint64 => PositionProtectionTypes.PositionProtectionView) internal protections;

    function positionProtectionBook() external view returns (address book) {
        return address(this);
    }

    function setActivePositionProtectionId(
        address account,
        uint64 protectionId
    ) external {
        activeProtectionIds[account] = protectionId;
    }

    function activePositionProtectionId(
        address account
    ) external view returns (uint64 protectionId) {
        return activeProtectionIds[account];
    }

    function setPositionProtection(
        PositionProtectionTypes.PositionProtectionView calldata protection
    ) external {
        protections[protection.protectionId] = protection;
    }

    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection) {
        return protections[protectionId];
    }

}

contract PerpsPublicLensTest is BasePerpTest {

    uint64 internal constant SATURDAY_NOON = 1_710_021_600;

    function test_GetTraderAccount_UsesNetEquityAndEngineAwareWithdrawable() public {
        address trader = address(0xA11CE);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertGt(clearinghouse.getFreeBuyingPowerUsdc(account), 0, "setup should leave free buying power");
        assertEq(viewData.equityUsdc, uint256(snapshot.netEquityUsdc), "public equity should use net economic equity");
        assertEq(
            viewData.withdrawableUsdc,
            engineAccountLens.getWithdrawableUsdc(account),
            "lens should use account-lens withdrawability"
        );
        assertEq(viewData.withdrawableUsdc, 0, "withdrawable should zero when engine withdraws are stale-blocked");
    }

    function test_GetTraderAccount_WithdrawableMatchesEngineAndActualWithdrawBound() public {
        address trader = address(0xBEEF);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertGt(withdrawableUsdc, 0, "setup should produce a positive withdrawable amount");
        assertEq(
            viewData.withdrawableUsdc, withdrawableUsdc, "lens should delegate withdrawability to the account lens"
        );

        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableUsdc);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(account, 1);
    }

    function test_GetTraderAccount_FlatAccountUsesSettlementEquity() public {
        address trader = address(0xF1A7);
        address account = trader;

        _fundTrader(trader, 12_345e6);

        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertEq(viewData.equityUsdc, 12_345e6, "flat accounts should report settlement equity");
        assertEq(viewData.withdrawableUsdc, 12_345e6, "flat accounts should expose full engine withdrawability");
        assertFalse(viewData.hasOpenPosition, "flat account should not report an open position");
    }

    function test_GetPosition_PopulatesMaintenanceMargin() public {
        address trader = address(0xB0B);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(account);
        assertEq(
            viewData.maintenanceMarginUsdc,
            _maintenanceMarginUsdc(viewData.size, engine.lastMarkPrice()),
            "position view should expose the live maintenance margin requirement"
        );
    }

    function test_GetPosition_MirrorsAccountLensPositionState() public {
        address trader = address(0xB0B3);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 14 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(account);

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

    function test_GetActivePositionProtection_ForwardsRouterRecord() public {
        address account = address(0xA11CE);
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory expected;
        expected.protectionId = 7;
        expected.parentOrderId = 3;
        expected.account = account;
        expected.side = CfdTypes.Side.BEAR;
        expected.size = 42_000e18;
        expected.takeProfitTriggerPrice = 120_000_000;
        expected.stopLossTriggerPrice = 80_000_000;
        expected.triggerBountyUsdc = 200_000;
        expected.executionBountyUsdc = 200_000;
        expected.armedAt = 1_720_000_000;
        expected.armedBlock = 12_345;
        expected.status = PositionProtectionTypes.PositionProtectionStatus.Armed;
        protectionViews.setPositionProtection(expected);
        protectionViews.setActivePositionProtectionId(account, expected.protectionId);

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getActivePositionProtection(account);

        assertEq(
            keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "active protection should pass through"
        );
    }

    function test_GetActivePositionProtection_ReturnsNoneWhenAccountHasNoProtection() public {
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getActivePositionProtection(address(0xB0B));

        assertEq(actual.protectionId, 0, "missing active protection should have no id");
        assertEq(
            uint8(actual.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.None),
            "missing active protection should report None"
        );
    }

    function test_GetPositionProtection_ForwardsTerminalHistoryById() public {
        address account = address(0xCAFE);
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory expected;
        expected.protectionId = 9;
        expected.linkedOrderId = 11;
        expected.account = account;
        expected.side = CfdTypes.Side.BULL;
        expected.size = 10_000e18;
        expected.takeProfitTriggerPrice = 90_000_000;
        expected.stopLossTriggerPrice = 110_000_000;
        expected.triggerBountyUsdc = 200_000;
        expected.executionBountyUsdc = 200_000;
        expected.armedAt = 1_720_100_000;
        expected.armedBlock = 12_678;
        expected.triggerMarkPrice = 90_000_000;
        expected.triggerPublishTime = 1_720_100_015;
        expected.triggeredLeg = PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit;
        expected.status = PositionProtectionTypes.PositionProtectionStatus.Executed;
        protectionViews.setPositionProtection(expected);

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getPositionProtection(expected.protectionId);

        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "terminal history should pass through");
    }

    function test_GetTraderAccount_UsesCarryAwareNetEquity() public {
        address trader = address(0xB0B1);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertLt(
            snapshot.netEquityUsdc,
            int256(snapshot.accountEquityUsdc),
            "Carry-aware lens equity should be below raw settlement equity"
        );
        assertEq(
            viewData.equityUsdc, uint256(snapshot.netEquityUsdc), "Public equity should inherit carry-aware net equity"
        );
    }

    function test_GetTraderAccount_WithdrawableDropsToZeroAfterLargeLiveCarryAccrual() public {
        address trader = address(0xB0B4);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 2 * 365 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertEq(withdrawableUsdc, 0, "Account lens withdrawable should drop to zero after large live carry accrual");
        assertEq(viewData.withdrawableUsdc, withdrawableUsdc, "Public lens withdrawable should match the account lens");

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(account, 1);
    }

    function test_GetTraderAccount_WithdrawableDecreasesUnderLiveCarryAccrual() public {
        address trader = address(0xB0B5);
        address account = trader;

        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8);

        uint256 withdrawableBeforeCarry = engineAccountLens.getWithdrawableUsdc(account);
        assertGt(withdrawableBeforeCarry, 0, "Setup should start with positive withdrawable headroom");

        vm.warp(block.timestamp + 5 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertLt(withdrawableUsdc, withdrawableBeforeCarry, "Live carry accrual should reduce withdrawable headroom");
        assertEq(viewData.withdrawableUsdc, withdrawableUsdc, "Public lens withdrawable should match the account lens");

        if (withdrawableUsdc > 0) {
            vm.prank(trader);
            clearinghouse.withdraw(account, withdrawableUsdc);

            vm.prank(trader);
            vm.expectRevert();
            clearinghouse.withdraw(account, 1);
        }
    }

    function test_IsLiquidatable_UsesCarryAwareLensState() public {
        address trader = address(0xB0B2);
        address account = trader;

        _fundTrader(trader, 820e6);
        _open(account, CfdTypes.Side.BULL, 50_000e18, 800e6, 1e8);

        assertFalse(publicLens.isLiquidatable(account), "Setup should start above maintenance before carry accrues");

        vm.prank(address(router));
        engine.updateMarkPrice(100_500_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 2 * 365 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        assertTrue(
            snapshot.liquidatable, "Account lens should become liquidatable once carry erodes maintenance headroom"
        );
        assertTrue(publicLens.isLiquidatable(account), "Public lens should inherit carry-aware liquidatability");
    }

    function test_GetLpStatus_UsesActualFrozenWindowFreshness() public {
        address trader = address(0xCAFE);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_NOON - 4 days));

        PerpsViewTypes.LpStatusView memory viewData = publicLens.getLpStatus();
        assertFalse(pool.getPoolLiquidityView().markFresh, "setup should make the frozen mark stale");
        assertFalse(viewData.oracleFresh, "LP status should mirror the actual house-pool freshness policy");
    }

    function test_GetSeniorTranche_ExposesFrozenLpFeeWhenOracleFrozen() public {
        _fundSenior(address(0xA11CE), 100_000e6);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_NOON - 3 hours));

        PerpsViewTypes.TrancheView memory viewData = publicLens.getSeniorTranche();

        assertTrue(viewData.oracleFrozen, "Senior tranche view should expose the frozen-oracle flag");
        assertEq(viewData.frozenLpFeeBps, 25, "Senior tranche view should expose the active frozen LP fee");
    }

    function test_GetJuniorTranche_DoesNotChargeFrozenFeeDuringFadOnlyHour() public {
        uint256 sunday2130 = 1_710_106_200;
        vm.warp(sunday2130);

        assertTrue(engine.isFadWindow(), "setup should remain inside FAD");
        assertFalse(engine.isOracleFrozen(), "setup should be after the oracle-frozen window");

        PerpsViewTypes.TrancheView memory viewData = publicLens.getJuniorTranche();

        assertFalse(viewData.oracleFrozen, "Junior tranche view should report the live oracle state");
        assertEq(viewData.frozenLpFeeBps, 0, "FAD alone should not activate the frozen LP fee");
    }

}
