// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditFullSecurityFailing_LiquidationFreeUsdc is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C1_LiquidationMustConsumeFreeUsdcCountedInEquity() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.09e8);

        vm.startPrank(address(router));
        engine.liquidatePosition(account, 1.09e8, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            preview.settlementRetainedUsdc,
            "Liquidation should leave exactly the previewed residual settlement after consuming free USDC"
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

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(HousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 800, "Rejected stale finalization should leave the prior senior rate in place");
        assertEq(pool.unpaidSeniorYield(), 0, "Stale-mark finalization should not back-apply senior yield");
    }

}

contract AuditFullSecurityFailing_BadDebtClearing is BasePerpTest {

    address winner = address(0xAAA1);
    address loser = address(0xBBB1);

    function test_L1_ClearBadDebtRequiresOnchainRecapitalizationProof() public {
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.BULL, 100_000e18, 1000e6, 0.5e8);

        vm.startPrank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        engine.liquidatePosition(loserAccount, 1e8, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        uint256 badDebt = engine.accumulatedBadDebtUsdc();
        assertGt(badDebt, 0, "Setup must realize bad debt");

        vm.expectRevert();
        engine.clearBadDebt(badDebt);
    }

}
