// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdVault} from "../../src/perps/interfaces/ICfdVault.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
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

    function test_H1_TinyInvalidCloseBehindQueuedIntentIsRejectedAtCommit() public {
        bytes32 accountId = bytes32(uint256(uint160(attacker)));
        _fundTrader(attacker, 2e6);

        vm.prank(attacker);
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, false);

        vm.prank(attacker);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, true);

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(escrow.pendingOrderCount, 1, "Rejected close intent should not be queued behind the pending open");
    }

}

contract AuditLatestStateFindingsFailing_TrancheCooldownBypass is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_SmallThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);
        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(helper, 1000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 1000e6);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(1000e6, alice);
        vm.stopPrank();
    }

}

contract AuditLatestStateFindingsFailing_LiquidationBounty is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 1000,
            baseCarryBps: 500,
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

        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(HousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(
            pool.lastReconcileTime(), before, "Rejected stale finalization should leave the accrual clock untouched"
        );
    }

}

contract AuditLatestStateFindingsFailing_StaleSeniorMutationYield is BasePerpTest {

    address seniorLp = address(0x44441);
    address juniorLp = address(0x55551);
    address trader = address(0x66661);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H1_StaleSeniorMutationMustNotDestroyAccruedYield() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 52_000e6, "Setup should impair senior before stale recapitalization");

        _fundTrader(trader, 50_000e6);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8);

        uint256 staleStart = block.timestamp;
        uint256 staleMutationTime = staleStart + 30 days;
        vm.warp(staleMutationTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 freshTime = staleMutationTime + 2 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 minimumPreservedYield = (52_000e6 * 800 * uint256(30 days)) / (10_000 * uint256(365 days));
        assertGe(
            pool.unpaidSeniorYield(),
            minimumPreservedYield,
            "Stale senior recapitalization should preserve the pre-mutation senior yield interval"
        );
    }

}
