// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#oracle-and-freshness-policy

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract SyntheticFutureStoredMarkTest is BasePerpTest {

    address alice = address(0xA11CE);

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_SyntheticFutureStoredMarkPreservesGuardAndReconcileLiveness() public {
        address aliceAccount = alice;

        _fundSenior(address(0xBEEF), 100_000e6);
        _fundTrader(alice, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        // Synthetic trusted-router state: external oracle preparation rejects future publications.
        uint256 balanceBefore = clearinghouse.balanceUsdc(aliceAccount);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp + 5));

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(aliceAccount);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            clearinghouse.balanceUsdc(aliceAccount), balanceBefore, "Guard and reconciliation preserve trader custody"
        );
        assertEq(engine.lastMarkTime(), block.timestamp + 5);
        assertEq(pool.lastReconcileTime(), block.timestamp, "Reconcile uses current time without underflow");
    }

}

contract StaleLpSettlementFreshnessTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_MatureRedemptionCannotSettleAgainstStaleLiveMark() public {
        _fundJunior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Open a position so staleness path triggers (longMax+shortMax > 0)
        address trader = address(0xAAA);
        _fundTrader(trader, 50_000 * 1e6);
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        // Crash: LONG loses when oracle rises
        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 redeemShares = juniorVault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, alice, alice);

        // The request must mature, but settlement must not price it from a stale live-market mark.
        vm.warp(juniorVault.depositEpochStart(requestId));
        uint256 staleMarkPrice = engine.lastMarkPrice();
        uint256 staleMarkTime = engine.lastMarkTime();
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        vm.prank(address(router));
        pool.settleLpEpoch(staleMarkPrice, staleMarkTime);
    }

}

contract StaleMarkDepositAdmissionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_StaleLiveMarkBlocksSeniorDepositRequest() public {
        _fundSenior(bob, 500_000e6);
        _fundJunior(address(this), 500_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 100_000e6);

        assertEq(seniorVault.maxRequestDeposit(attacker), 0, "stale mark should zero senior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(100_000e6, attacker);
        vm.stopPrank();
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_StaleLiveMarkBlocksJuniorDepositRequest() public {
        _fundJunior(bob, 500_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 100_000e6);

        assertEq(juniorVault.maxRequestDeposit(attacker), 0, "stale mark should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(100_000e6, attacker);
        vm.stopPrank();
    }

}

contract LiveFadFreshnessTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _fridayAt(
        uint256 hourUtc
    ) internal pure returns (uint256) {
        uint256 fridayMidnight = 1_709_856_000;
        return fridayMidnight + (hourUtc * 3600);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_LiveFadStaleMarkBlocksTraderWithdrawal() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        // Friday 21:30 UTC: FAD active but oracle still live until 22:00.
        uint256 fridayEvening = _fridayAt(21) + 30 minutes;
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        // 29m 59s later: still before the 22:00 oracle freeze boundary.
        // Mark is far beyond the normal 120s limit and should revert.
        vm.warp(fridayEvening + 30 minutes - 1);

        vm.prank(alice);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(account, 100e6);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_LiveFadStaleMarkBlocksLpDepositRequest() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        uint256 fridayEvening = _fridayAt(21) + 30 minutes;
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        vm.warp(fridayEvening + 30 minutes - 1);

        // FAD alone does not relax mark age: the stale live-market mark blocks a new LP request.
        address lp = address(0x1111);
        uint256 depositAmount = pool.minTrancheDepositUsdc();
        usdc.mint(lp, depositAmount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), depositAmount);
        assertEq(juniorVault.maxRequestDeposit(lp), 0, "stale mark should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(depositAmount, lp);
        vm.stopPrank();
    }

}

contract ReservedSettlementBehaviorFreshnessTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_WithdrawMustRevertWhenMarkIsStale() public {
        _fundTrader(trader, 100_000 * 1e6);
        address account = trader;

        _open(account, CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.warp(block.timestamp + 1 days);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(account, 1e6);
    }

}
