// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditFullSecurityFailing_LiquidationFreeUsdc is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C1_LiquidationMustConsumeFreeUsdcCountedInEquity() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.startPrank(address(router));
        engine.liquidatePosition(accountId, 1.09e8, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            796_500_000,
            "Liquidation should leave only residual equity after consuming free USDC"
        );
    }

}

contract AuditFullSecurityFailing_CooldownBypass is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_ThirdPartyDepositMustNotBypassCooldown() public {
        usdc.mint(helper, 100_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 100_000e6);
        juniorVault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        juniorVault.withdraw(100_000e6, alice, alice);
    }

}

contract AuditFullSecurityFailing_SeniorRateRetroactive is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);
    address trader = address(0x3333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M2_FinalizedSeniorRateMustNotBackApplyAcrossStalePeriod() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.unpaidSeniorYield(), 0, "Stale-mark finalization should not back-apply senior yield");
    }

}

contract AuditFullSecurityFailing_BadDebtClearing is BasePerpTest {

    address winner = address(0xAAA1);
    address loser = address(0xBBB1);

    function test_L1_ClearBadDebtRequiresOnchainRecapitalizationProof() public {
        bytes32 winnerId = bytes32(uint256(uint160(winner)));
        bytes32 loserId = bytes32(uint256(uint160(loser)));

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerId, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserId, CfdTypes.Side.BULL, 100_000e18, 1000e6, 0.5e8);

        vm.startPrank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        engine.liquidatePosition(loserId, 1e8, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        uint256 badDebt = engine.accumulatedBadDebtUsdc();
        assertGt(badDebt, 0, "Setup must realize bad debt");

        vm.expectRevert();
        engine.clearBadDebt(badDebt);
    }

}
