// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

contract AuditRemainingCoverageFindingsFailing_ReservationShielding is BasePerpTest {

    address trader = address(0xC10A);

    function test_C1_FullCloseMustConsumeQueuedCommittedMarginBeforeWaivingActionCharge() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint64 queuedOrderId = router.nextCommitId();
        uint256 committedMarginUsdc = _freeSettlementUsdc(account) - 200_000;
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, committedMarginUsdc, type(uint256).max, false);

        uint256 committedBefore = router.getAccountReservations(account).committedMarginUsdc;
        assertEq(_freeSettlementUsdc(account), 0, "Setup must shelter all non-bounty free settlement in the queue");
        vm.warp(block.timestamp + 365 days);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1e8);
        assertTrue(preview.valid, "Full close should collect terminal carry from queued committed margin");
        assertEq(preview.realizedPnlUsdc, 0, "Setup must isolate action charges from price PnL");
        assertEq(preview.badDebtUsdc, 0, "Action-charge collection must never create protocol debt");

        _close(account, CfdTypes.Side.BULL, 100_000e18, 1e8);

        assertLt(
            router.getAccountReservations(account).committedMarginUsdc,
            committedBefore,
            "Full close should consume queued committed margin before waiving terminal carry"
        );
        assertEq(_executionBountyReserve(queuedOrderId), 200_000, "Queued execution bounty should remain reserved");
        assertEq(
            router.pendingOrderCounts(account),
            1,
            "Queued successor order itself should remain pending after the live position closes"
        );
    }

    function test_H1_LiquidationMustConsumeQueuedCommittedMarginBeforeWaivingActionCharge() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint64 queuedOrderId = router.nextCommitId();
        uint256 committedMarginUsdc = _freeSettlementUsdc(account) - 200_000;
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, committedMarginUsdc, type(uint256).max, false);

        uint256 committedBefore = router.getAccountReservations(account).committedMarginUsdc;
        assertEq(_freeSettlementUsdc(account), 0, "Setup must shelter all non-bounty free settlement in the queue");
        vm.warp(block.timestamp + 365 days);
        uint256 depth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1e8);
        assertTrue(preview.liquidatable, "Accrued carry should make the position liquidatable");
        assertEq(preview.pnlUsdc, 0, "Setup must isolate liquidation action charges from price PnL");
        assertEq(preview.badDebtUsdc, 0, "Liquidation action-charge collection must never create protocol debt");

        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, depth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still clear the live insolvent position");
        assertEq(_executionBountyReserve(queuedOrderId), 200_000, "Queued execution bounty should remain reserved");
        assertLt(
            router.getAccountReservations(account).committedMarginUsdc,
            committedBefore,
            "Liquidation should consume queued committed margin before waiving terminal carry"
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
            bountyBps: 1000,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_H2_PositiveEquityLiquidationBountyUsesExplicitSubsidy() public {
        address trader = address(0xA201);
        address account = trader;

        _fundTrader(trader, 100e6);
        _open(account, CfdTypes.Side.BULL, CfdTypes.SIZE_QUANTUM, 12e6, 1e8);

        uint256 freeSettlementUsdc = _freeSettlementUsdc(account);
        vm.prank(trader);
        clearinghouse.withdraw(account, freeSettlementUsdc);

        vm.warp(1_709_971_200);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);
        assertTrue(preview.liquidatable, "FAD maintenance must make the positive-equity fixture liquidatable");

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Execution must match the dedicated-reserve preview");
        assertEq(
            bounty,
            (liquidationReserveBefore * _riskParams().keeperShareBps) / 10_000,
            "Keeper must receive its configured share of the dedicated liquidation reserve"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_ForfeitedOrderBountyFees is BasePerpTest {

    address trader = address(0xA202);
    address counterparty = address(0xA203);
    address keeper = address(0xA204);

    function test_L1_LiquidationForfeitedOrderBountyMustAccrueProtocolFees() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 100_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);

        uint256 forfeitedBounty = _executionBountyReserve(1);
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(196_000_000));

        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            forfeitedBounty,
            "Forfeited queued order bounties should accrue to protocol fees"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_DustQueueEconomics is BasePerpTest {

    address trader = address(0xD057);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.minBountyUsdc = 100_000;
    }

    function test_H3_DustOrdersMustReserveMinimumKeeperReserve() public {
        _fundTrader(trader, 3e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100e18, 2e6, 0, false);

        address account = trader;
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(
            reservation.executionBountyUsdc,
            10_000,
            "Dust orders should reservation the configured minimum execution bounty"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_TrancheCooldownDocs is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_M1_FivePercentThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 5000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 5000e6);
        uint256 requestId = juniorVault.requestDeposit(5000e6, attacker);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.settleLpEpoch();

        vm.startPrank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 5000e6, alice, attacker);
        vm.stopPrank();
    }

}

contract AuditRemainingCoverageFindingsFailing_CloseLiquidityAndFees is BasePerpTest {

    address trader = address(0xC105);
    address keeper = address(0xBEEF);

    function test_H4_ProfitableCloseMustNotBeDroppedWhenPoolLacksImmediateCash() public {
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 10_000e6);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "A profitable close should complete even when profit payout becomes a trader claim");
    }

    function test_M2_CloseCommitRequiresPrefundedKeeperBounty() public {
        address account = trader;
        _fundTrader(trader, 2001e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        assertEq(
            router.nextCommitId(), 2, "Close commits should still succeed when the trader prefunds the keeper bounty"
        );
        assertEq(
            _executionBountyReserve(1), 200_000, "Close commits should reservation the configured flat clearer bounty"
        );
    }

    function test_H5_CloseKeeperRewardMustCreditFromReservedMarginDespiteVaultCashShortage() public {
        address account = trader;
        address keeperAccount = keeper;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccount);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Close should still succeed even when execution bounty cash is unavailable");
        assertEq(
            clearinghouse.balanceUsdc(keeperAccount) - keeperSettlementBefore,
            200_000,
            "Illiquid close execution should still pay the keeper from clearinghouse-reserved bounty value"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_TerminalLiveness is BasePerpTest {

    address trader = address(0x7100);
    address spammer = address(0x7101);
    address keeper = address(0x7102);

    function test_H6_LiquidationKeeperRewardMustCreditFromTraderMarginDespiteVaultCashShortage() public {
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("pool illiquid"));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still succeed even when bounty cash is unavailable");
        assertGt(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            0,
            "Liquidation bounty should credit keeper settlement instead of reverting"
        );
    }

    function test_M3_TerminalCloseMustRemainExecutableUnderBoundedForeignQueue() public {
        address account = trader;
        _fundTrader(trader, 20_000e6);
        _fundTrader(spammer, 250_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BEAR, 10_000e18, 1000e6, 2e8, false);
        }

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        uint64 closeOrderId = router.nextExecuteId();
        router.executeOrder(closeOrderId, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Terminal close should succeed even with the bounded foreign queued orders");
        assertEq(router.nextExecuteId(), closeOrderId + 1, "Queue head should advance after terminal close");
    }

}
