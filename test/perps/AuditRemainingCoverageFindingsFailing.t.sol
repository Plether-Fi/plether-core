// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditRemainingCoverageFindingsFailing_EscrowShielding is BasePerpTest {

    address trader = address(0xC10A);

    function test_C1_FullCloseMustConsumeQueuedCommittedMarginBeforeBadDebt() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900e6, type(uint256).max, false);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 103_000_000);

        assertLt(
            clearinghouse.lockedMarginUsdc(accountId),
            7900e6,
            "Full close should consume queued committed margin before socializing shortfall"
        );
        assertEq(_executionBountyReserve(1), 1e6, "Queued execution bounty should remain in router custody");
        assertEq(
            engine.accumulatedBadDebtUsdc(),
            0,
            "Full close should not realize bad debt while queued committed margin remains"
        );
        assertEq(
            router.pendingOrderCounts(accountId),
            1,
            "Queued successor order itself should remain pending after the live position closes"
        );
    }

    function test_H1_LiquidationMustConsumeQueuedCommittedMarginBeforeBadDebt() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900e6, type(uint256).max, false);

        uint256 depth = pool.totalAssets();
        vm.startPrank(address(router));
        engine.liquidatePosition(accountId, 110_000_000, depth, uint64(block.timestamp));
        vm.stopPrank();

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Liquidation should still clear the live insolvent position");
        assertEq(_executionBountyReserve(1), 1e6, "Queued execution bounty should remain in router custody");
        assertLt(
            clearinghouse.lockedMarginUsdc(accountId),
            7900e6,
            "Liquidation should consume queued committed margin before bad debt"
        );
        assertLt(
            engine.accumulatedBadDebtUsdc(),
            7900e6,
            "Liquidation bad debt should be limited to the true residual after queued committed margin is consumed"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_LiquidationBounty is BasePerpTest {

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

    function test_H2_PositiveEquityLiquidationBountyMustCapAtRemainingEquity() public {
        address trader = address(0xA201);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 100e6);
        _open(accountId, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 94e6);

        vm.startPrank(address(router));
        vm.warp(1_709_971_200);
        uint256 bounty = engine.liquidatePosition(accountId, 101_000_000, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(bounty, 4_960_000, "Keeper bounty should not exceed the trader's remaining positive equity");
    }

}

contract AuditRemainingCoverageFindingsFailing_ForfeitedOrderBountyFees is BasePerpTest {

    address trader = address(0xA202);
    address counterparty = address(0xA203);
    address keeper = address(0xA204);

    function test_L1_LiquidationForfeitedOrderBountyMustAccrueProtocolFees() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        bytes32 counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 100_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);

        uint256 forfeitedBounty = _executionBountyReserve(1);
        uint256 feesBefore = engine.accumulatedFeesUsdc();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(196_000_000));

        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            forfeitedBounty,
            "Forfeited queued order bounties should accrue to protocol fees"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_DustQueueEconomics is BasePerpTest {

    address trader = address(0xD057);

    function test_H3_DustOrdersMustEscrowMinimumKeeperReserve() public {
        _fundTrader(trader, 1e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, false);

        bytes32 accountId = bytes32(uint256(uint160(trader)));
        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(escrow.executionBountyUsdc, 50_000, "Dust orders should escrow a nonzero minimum execution bounty");
    }

}

contract AuditRemainingCoverageFindingsFailing_TrancheCooldownDocs is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_M1_FivePercentThirdPartyTopUpMustResetExistingHolderCooldown() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 5000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 5000e6);
        juniorVault.deposit(5000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 11 minutes);
        vm.expectRevert();
        vm.prank(alice);
        juniorVault.withdraw(105_000e6, alice, alice);
    }

}

contract AuditRemainingCoverageFindingsFailing_CloseLiquidityAndFees is BasePerpTest {

    address trader = address(0xC105);
    address keeper = address(0xBEEF);

    function test_H4_ProfitableCloseMustNotBeDroppedWhenVaultLacksImmediateCash() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 10_000e6);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "A profitable close should complete even when profit payout must be deferred");
    }

    function test_M2_CloseCommitRequiresPrefundedKeeperBounty() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2001e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        assertEq(
            router.nextCommitId(), 2, "Close commits should still succeed when the trader prefunds the keeper bounty"
        );
        assertEq(_executionBountyReserve(1), 1e6, "Close commits should escrow the flat clearer bounty");
    }

    function test_H5_CloseKeeperRewardMustDeferInsteadOfRevertingOnCashShortage() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Close should still succeed even when execution bounty cash is unavailable");
        assertEq(
            engine.deferredClearerBountyUsdc(keeper),
            0,
            "Illiquid close execution should not touch deferred vault-funded clearer claims"
        );
        assertEq(
            usdc.balanceOf(keeper) - keeperUsdcBefore,
            1e6,
            "Illiquid close execution should still pay the keeper from router escrow"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_TerminalLiveness is BasePerpTest {

    address trader = address(0x7100);
    address spammer = address(0x7101);
    address keeper = address(0x7102);

    function test_H6_LiquidationKeeperRewardMustDeferInsteadOfRevertingOnCashShortage() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("vault illiquid"));

        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Liquidation should still succeed even when bounty cash is unavailable");
        assertGt(engine.deferredClearerBountyUsdc(keeper), 0, "Liquidation bounty should defer instead of reverting");
    }

    function test_M3_TerminalCloseMustRemainExecutableUnderBoundedForeignQueue() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 20_000e6);
        _fundTrader(spammer, 250_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BEAR, 10_000e18, 1000e6, 2e8, false);
        }

        bytes[] memory empty = new bytes[](0);
        vm.roll(block.number + 1);
        uint64 closeOrderId = router.nextExecuteId();
        router.executeOrder(closeOrderId, empty);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Terminal close should succeed even with the bounded foreign queued orders");
        assertEq(router.nextExecuteId(), closeOrderId + 1, "Queue head should advance after terminal close");
    }

}
