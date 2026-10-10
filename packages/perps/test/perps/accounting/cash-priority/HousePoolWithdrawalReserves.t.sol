// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolWithdrawalReservesTest is HousePoolTestBase {

    using stdStorage for StdStorage;

    // ==========================================
    // WITHDRAWAL PRIORITY
    // ==========================================

    function test_WithdrawalPriority() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        _open(carol, CfdTypes.Side.LONG, 800_000 * 1e18, 40_000 * 1e6, 1e8);

        _finishAsyncCooldown(seniorVault, alice);
        _finishAsyncCooldown(juniorVault, bob);
        uint256 seniorRequest = _requestAsyncRedeem(seniorVault, alice, seniorVault.balanceOf(alice));
        uint256 juniorRequest = _requestAsyncRedeem(juniorVault, bob, juniorVault.balanceOf(bob));
        assertEq(seniorRequest, juniorRequest, "same-hour exits should share the synchronized epoch");

        _settleAsyncRequest(seniorRequest, true);

        assertGt(seniorVault.claimableRedeemRequest(seniorRequest, alice), 0, "senior exit receives first liquidity");
        assertEq(
            juniorVault.claimableRedeemRequest(juniorRequest, bob),
            0,
            "junior exit waits while the senior epoch remains backlogged"
        );
    }

    function test_DormantSeniorDoesNotReserveJuniorWithdrawalLiquidity() public {
        _fundSenior(alice, 200_000 * 1e6);
        _fundJunior(bob, 200_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        _open(carol, CfdTypes.Side.LONG, 250_000 * 1e18, 25_000 * 1e6, 1e8);

        uint256 seniorMax = pool.getMaxSeniorWithdraw();
        assertGt(seniorMax, 0, "Senior can withdraw");
        assertGt(pool.getMaxJuniorWithdraw(), 0, "dormant senior capacity must not reserve cash from junior exits");
    }

    function test_JuniorMaxWithdraw_MatchesReconcileFirstWithdraw() public {
        address carolAccount = carol;

        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        _open(carolAccount, CfdTypes.Side.LONG, 200_000 * 1e18, 20_000 * 1e6, 1e8);
        _close(carolAccount, CfdTypes.Side.LONG, 200_000 * 1e18, 0.5e8);

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 requestedShares = juniorVault.maxRequestRedeem(bob);
        uint256 sharesBefore = juniorVault.balanceOf(bob);
        uint256 requestId = _requestAsyncRedeem(juniorVault, bob, requestedShares);
        _settleAsyncRequest(requestId, true);
        uint256 quotedAssets = juniorVault.maxWithdraw(bob);

        assertLt(quotedAssets, 300_000 * 1e6, "reconciled losses should reduce junior withdraw capacity");
        assertGt(quotedAssets, 0, "settlement should fund part of the junior exit");

        vm.prank(bob);
        juniorVault.withdraw(quotedAssets, bob, bob);

        assertEq(usdc.balanceOf(bob), quotedAssets, "maxWithdraw quote should remain executable after reconcile");
        assertLt(juniorVault.balanceOf(bob), sharesBefore, "withdraw should burn shares using the quoted max");
    }

    function test_GetFreeUSDC_DoesNotReserveTreasuryFees() public {
        _fundJunior(bob, 500_000 * 1e6);

        address trader = address(0x444);
        _fundTrader(trader, 50_000 * 1e6);

        _open(trader, CfdTypes.Side.LONG, 100_000 * 1e18, 5000 * 1e6, 1e8);

        // 100k LONG at $1.00: protocol accrues the full $40 execution fee.
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertEq(fees, 40_000_000, "Protocol fees should remain separate from reserved execution bounty reservation");

        uint256 freeUSDC = pool.getFreeUSDC();
        uint256 vaultBal = pool.totalAssets();
        uint256 maxLiability = _maxLiability();
        uint256 settlementBuffer =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps());
        uint256 expectedReserved = maxLiability + settlementBuffer;

        assertEq(
            freeUSDC,
            vaultBal - expectedReserved,
            "Free USDC should reserve directional liability and its settlement buffer, but not treasury fees"
        );
    }

    function test_MinWithdrawal_BlocksDustBeforeCouponCheckpoint() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        uint256 checkpointBefore = pool.lastSeniorCouponCheckpointTime();

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        vm.expectRevert(TrancheVault.TrancheVault__WithdrawalTooSmall.selector);
        seniorVault.requestRedeem(0, alice, alice);
        vm.expectRevert(TrancheVault.TrancheVault__WithdrawalTooSmall.selector);
        seniorVault.requestRedeem(1, alice, alice);
        vm.stopPrank();

        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            checkpointBefore,
            "Dust withdrawals must fail before forcing coupon checkpointing"
        );
    }

    function test_MinWithdrawal_AllowsFullDustExit() public {
        uint256 minimum = pool.minTrancheDepositUsdc();
        _fundJunior(alice, minimum);
        _fundJunior(bob, minimum);

        vm.prank(address(engine));
        pool.payOut(address(0xBEEF), minimum + 2);

        vm.warp(block.timestamp + 1 hours);

        uint256 aliceRequestId = _requestAsyncRedeem(juniorVault, alice, juniorVault.balanceOf(alice));
        uint256 bobRequestId = _requestAsyncRedeem(juniorVault, bob, juniorVault.balanceOf(bob));
        assertEq(aliceRequestId, bobRequestId, "same-hour exits should share an epoch");
        _settleAsyncRequest(aliceRequestId, true);

        uint256 aliceWithdrawable = juniorVault.maxWithdraw(alice);
        assertGt(aliceWithdrawable, 0, "Setup should leave Alice withdrawable dust");
        assertLt(aliceWithdrawable, minimum, "Setup should leave Alice below the ordinary flow minimum");
        vm.prank(alice);
        uint256 aliceSharesBurned = juniorVault.withdraw(aliceWithdrawable, alice, alice);
        assertEq(juniorVault.balanceOf(alice), 0, "Full dust withdraw should clear the user position");
        assertEq(usdc.balanceOf(alice), aliceWithdrawable, "Alice should receive the full dust value");
        assertGt(aliceSharesBurned, 0, "Withdraw should burn shares");

        uint256 bobShares = juniorVault.maxRedeem(bob);
        uint256 bobAssets = juniorVault.maxWithdraw(bob);
        assertGt(bobAssets, 0, "Setup should leave Bob redeemable dust");
        assertLt(bobAssets, minimum, "Setup should leave Bob below the ordinary flow minimum");
        vm.prank(bob);
        uint256 redeemedAssets = juniorVault.redeem(bobShares, bob, bob);
        assertEq(juniorVault.balanceOf(bob), 0, "Full dust redeem should let Bob exit");
        assertEq(redeemedAssets, bobAssets, "Redeem should pay the previewed dust value");
    }

    function test_SeniorHWM_ProportionalOnWithdraw() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _finishAsyncCooldown(seniorVault, alice);
        uint256 requestShares = seniorVault.estimateWithdrawShares(250_000 * 1e6);
        uint256 requestId = _requestAsyncRedeem(seniorVault, alice, requestShares);
        _settleAsyncRequest(requestId, true);
        uint256 assetsPaid = seniorVault.maxWithdraw(alice);
        uint256 projectedSeniorBeforeWithdraw = pool.seniorPrincipal() + assetsPaid;
        _claimAsyncRedeem(seniorVault, requestId, alice);

        uint256 expectedSenior = projectedSeniorBeforeWithdraw - assetsPaid;
        assertEq(pool.seniorPrincipal(), expectedSenior);
        assertEq(pool.seniorHighWaterMark(), expectedSenior, "HWM scales proportionally on withdraw");
    }

    function test_GetFreeUSDC_OnlySettlementBufferSupplementalReserveInCarryModel() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        _fundJunior(bob, 1_000_000 * 1e6);

        address trader1 = address(0x444);
        _fundTrader(trader1, 100_000 * 1e6);
        _open(trader1, CfdTypes.Side.LONG, 400_000 * 1e18, 40_000 * 1e6, 1e8);

        address trader2 = address(0x555);
        _fundTrader(trader2, 100_000 * 1e6);
        _open(trader2, CfdTypes.Side.SHORT, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 20 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        uint256 maxLiability = _maxLiability();
        uint256 supplementalReserve =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).supplementalReservedUsdc;
        assertEq(
            supplementalReserve,
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps()),
            "Carry mode should add no supplemental reserve beyond the settlement buffer"
        );

        uint256 freeUSDC = pool.getFreeUSDC();
        assertGt(freeUSDC, 0, "getFreeUSDC should remain positive in the carry model");
    }

    function test_Reconcile_KeepsSettlementBufferOutOfNav() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        _fundJunior(bob, 1_000_000 * 1e6);
        address trader1 = address(0x444);
        _fundTrader(trader1, 100_000 * 1e6);
        _open(trader1, CfdTypes.Side.LONG, 400_000 * 1e18, 40_000 * 1e6, 1e8);

        address trader2 = address(0x555);
        _fundTrader(trader2, 100_000 * 1e6);
        _open(trader2, CfdTypes.Side.SHORT, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 20 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        uint256 maxLiability = _maxLiability();
        uint256 supplementalReserve =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).supplementalReservedUsdc;
        assertEq(
            supplementalReserve,
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps()),
            "Carry mode should add no supplemental reserve beyond the settlement buffer"
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool cash must cover LP claims + fees + conservative unrealized liabilities
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 juniorAfter = pool.juniorPrincipal();
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 reserved = fees;
        assertGe(poolBalance, juniorAfter + reserved, "Pool cash must cover LP claims + reserved obligations");
    }

}

