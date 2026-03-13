// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditLatestStateFindingsFailing_KeeperReserveStripsMargin is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C1_KeeperReserveMustNotComeFromLockedPositionMargin() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 160e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 160e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        vm.prank(trader);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0, false);
    }

}

contract AuditLatestStateFindingsFailing_QueueEconomics is BasePerpTest {

    address attacker = address(0xBAD);

    function test_H1_TinyInvalidCloseBehindQueuedIntentTracksEscrowAndPendingCount() public {
        bytes32 accountId = bytes32(uint256(uint160(attacker)));
        _fundTrader(attacker, 1e6);

        vm.prank(attacker);
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, false);

        vm.prank(attacker);
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, true);

        OrderRouter.AccountEscrow memory escrow = router.getAccountEscrow(accountId);
        assertEq(escrow.pendingOrderCount, 2, "Async close intent should be queueable behind a pending open");
        assertEq(escrow.keeperReserveUsdc, 50_000, "Dust orders should escrow the minimum keeper fee so FIFO remains serviceable");
    }

}

contract AuditLatestStateFindingsFailing_TrancheCooldownBypass is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_SmallThirdPartyTopUpDoesNotRefreshCooldown() public {
        _fundJunior(alice, 100_000e6);
        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(helper, 1_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 1_000e6);
        juniorVault.deposit(1_000e6, alice);
        vm.stopPrank();

        vm.prank(alice);
        juniorVault.withdraw(101_000e6, alice, alice);
    }

}

contract AuditLatestStateFindingsFailing_LiquidationBounty is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 10,
            fadMarginBps: 1000,
            minBountyUsdc: 1e6,
            bountyBps: 1000
        });
    }

}

contract AuditLatestStateFindingsFailing_SeniorYieldCheckpoint is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);
    address trader = address(0x3333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M2_FinalizeSeniorRateMustNotEraseYieldDuringStaleMarkPeriod() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 before = pool.lastReconcileTime();
        uint256 oldRate = pool.seniorRateBps();
        uint256 principal = pool.seniorPrincipal();

        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 elapsed = block.timestamp - before;
        uint256 expectedOldYield = (principal * oldRate * elapsed) / (10_000 * 365 days);
        assertEq(
            pool.unpaidSeniorYield(),
            expectedOldYield,
            "Stale-mark intervals should defer senior yield accrual, not erase it when finalizing a new rate"
        );
    }

}
