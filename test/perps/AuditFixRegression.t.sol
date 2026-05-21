// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {IHousePool} from "../../src/perps/interfaces/IHousePool.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract AuditFixRegressionTest is BasePerpTest {

    function test_DepositPricingUsesDepositMtmInsteadOfConservativeMtmDiscount() public {
        uint256 revenueUsdc = 500_000e6;
        usdc.mint(address(pool), revenueUsdc);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            revenueUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        uint256 depositUsdc = 300_000e6;
        uint256 sharesBeforePhantomMtm = juniorVault.previewDeposit(depositUsdc);

        address bull = address(0xB011);
        address bear = address(0xBEA2);
        uint256 size = 400_000e18;
        _fundTrader(bull, 20_000e6);
        _fundTrader(bear, 20_000e6);
        _open(bull, CfdTypes.Side.BULL, size, 20_000e6, 1e8);
        _open(bear, CfdTypes.Side.BEAR, size, 20_000e6, 1e8);

        (uint256 depositSeniorAssets, uint256 depositJuniorAssets) = pool.getPendingDepositTrancheState();
        depositSeniorAssets;
        uint256 conservativeJuniorAssets = juniorVault.totalAssets();

        assertGt(depositJuniorAssets, conservativeJuniorAssets, "deposit NAV must ignore phantom conservative MTM");
        assertApproxEqAbs(
            juniorVault.previewDeposit(depositUsdc),
            sharesBeforePhantomMtm,
            2,
            "delta-neutral phantom MTM must not discount new deposits"
        );
    }

    function test_DepositPricingIgnoresOneSidedUnrealizedProfitAfterPriceMove() public {
        uint256 depositUsdc = 300_000e6;
        uint256 sharesBeforeMtm = juniorVault.previewDeposit(depositUsdc);

        address bull = address(0xB012);
        address bear = address(0xBEA3);
        uint256 size = 300_000e18;
        _fundTrader(bull, 20_000e6);
        _fundTrader(bear, 20_000e6);
        _open(bull, CfdTypes.Side.BULL, size, 20_000e6, 1e8);
        _open(bear, CfdTypes.Side.BEAR, size, 20_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(120_000_000, uint64(block.timestamp));

        (uint256 depositSeniorAssets, uint256 depositJuniorAssets) = pool.getPendingDepositTrancheState();
        depositSeniorAssets;
        uint256 conservativeJuniorAssets = juniorVault.totalAssets();

        assertGt(depositJuniorAssets, conservativeJuniorAssets, "deposit NAV must ignore unrealized trader PnL");
        assertApproxEqAbs(
            juniorVault.previewDeposit(depositUsdc),
            sharesBeforeMtm,
            2,
            "one-sided unrealized profit must not discount new deposits"
        );
    }

    function test_DepositPricingAllowsDiscountedSharesAfterRealJuniorLoss() public {
        uint256 depositUsdc = 100_000e6;
        uint256 sharesBeforeLoss = juniorVault.previewDeposit(depositUsdc);

        vm.prank(address(engine));
        pool.payOut(address(0xD15C0), 200_000e6);

        assertGt(
            juniorVault.previewDeposit(depositUsdc),
            sharesBeforeLoss,
            "real junior losses should mint at the impaired NAV, not a hard 1.0 floor"
        );
    }

    function test_OpenPositionsBlockImmediateJuniorDepositsBeforeLiquidation() public {
        address trader = address(0x7100);
        address attacker = address(0xA77A);
        uint256 attackerDepositUsdc = 100_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        assertEq(juniorVault.maxDeposit(attacker), 0, "live positions must close the immediate deposit window");

        usdc.mint(attacker, attackerDepositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), attackerDepositUsdc);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector, attacker, attackerDepositUsdc, uint256(0)
            )
        );
        juniorVault.deposit(attackerDepositUsdc, attacker);
        vm.stopPrank();
    }

    function test_PendingJuniorDepositFinalizesAtPostLiquidationNav() public {
        address trader = address(0x7101);
        address attacker = address(0xA77A2);
        address keeper = address(0xB0B0);
        uint256 attackerDepositUsdc = 100_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 immediateSharesBeforeLiquidation = juniorVault.previewDeposit(attackerDepositUsdc);

        usdc.mint(attacker, attackerDepositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), attackerDepositUsdc);
        uint256 epochId = juniorVault.requestDeposit(attackerDepositUsdc, attacker);
        vm.stopPrank();

        assertEq(juniorVault.balanceOf(attacker), 0, "pending deposits must not mint active shares");
        assertEq(
            juniorVault.pendingDepositAssets(attacker, epochId),
            attackerDepositUsdc,
            "pending assets should be assigned to the activation epoch"
        );

        uint256 poolDepthUsdc = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(trader, 150_000_000, poolDepthUsdc, uint64(block.timestamp), keeper);

        vm.warp(juniorVault.depositEpochStart(epochId));
        uint256 finalizedShares = juniorVault.finalizeDepositEpoch(epochId);

        assertLt(
            finalizedShares,
            immediateSharesBeforeLiquidation,
            "finalized shares should price in liquidation revenue realized during the pending period"
        );

        vm.prank(attacker);
        uint256 claimedShares = juniorVault.claimDepositShares(epochId);

        assertEq(claimedShares, finalizedShares, "single depositor should receive the finalized epoch shares");
        assertEq(juniorVault.balanceOf(attacker), claimedShares, "claimed shares should be self-custodied");
    }

    function test_PendingDepositCanCancelOnlyBeforeActivationEpoch() public {
        address attacker = address(0xCACE1);
        uint256 depositUsdc = 100_000e6;

        usdc.mint(attacker, depositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, attacker);
        juniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(attacker), depositUsdc, "pre-activation cancellation should refund assets");
        assertEq(juniorVault.pendingDepositAssets(attacker, epochId), 0, "cancelled request should clear pending state");

        usdc.mint(attacker, depositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), depositUsdc);
        epochId = juniorVault.requestDeposit(depositUsdc, attacker);
        vm.warp(juniorVault.depositEpochStart(epochId));
        vm.expectRevert();
        juniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();
    }

    function test_ActivePendingDepositCanCancelWhenSeniorImpairmentBlocksFinalization() public {
        address pendingLp = address(0xCAFE2);
        uint256 depositUsdc = 50_000e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        uint256 activationTime = juniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(activationTime));

        vm.prank(address(engine));
        pool.payOut(address(0xD15C0), 1_001_500e6);

        assertTrue(
            pool.isSeniorImpairedAfterPendingDepositReconcile(), "pending deposit finalization should be impaired"
        );
        vm.expectRevert(IHousePool.HousePool__SeniorImpaired.selector);
        juniorVault.finalizeDepositEpoch(epochId);

        vm.prank(pendingLp);
        uint256 refunded = juniorVault.cancelPendingDeposit(epochId);

        (uint256 epochAssets,,,, bool finalized) = juniorVault.depositEpochs(epochId);
        assertEq(refunded, depositUsdc, "active impaired cancellation should refund pending assets");
        assertEq(usdc.balanceOf(pendingLp), depositUsdc, "depositor should recover escrowed USDC");
        assertEq(juniorVault.pendingDepositAssets(pendingLp, epochId), 0, "pending balance should clear");
        assertEq(epochAssets, 0, "epoch aggregate assets should decrease");
        assertFalse(finalized, "epoch should remain unfinalized");
    }

    function test_PendingDepositClaimsAllocateAllFinalizedShares() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256 aliceDepositUsdc = 33_333e6;
        uint256 bobDepositUsdc = 66_667e6;

        usdc.mint(alice, aliceDepositUsdc);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), aliceDepositUsdc);
        uint256 epochId = juniorVault.requestDeposit(aliceDepositUsdc, alice);
        vm.stopPrank();

        usdc.mint(bob, bobDepositUsdc);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), bobDepositUsdc);
        assertEq(juniorVault.requestDeposit(bobDepositUsdc, bob), epochId, "same epoch should batch together");
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(epochId));
        uint256 finalizedShares = juniorVault.finalizeDepositEpoch(epochId);

        vm.prank(alice);
        uint256 aliceShares = juniorVault.claimDepositShares(epochId);
        vm.prank(bob);
        uint256 bobShares = juniorVault.claimDepositShares(epochId);

        (,, uint256 claimedAssets, uint256 claimedShares,) = juniorVault.depositEpochs(epochId);
        assertEq(aliceShares + bobShares, finalizedShares, "epoch claims should allocate every finalized share");
        assertEq(claimedAssets, aliceDepositUsdc + bobDepositUsdc, "epoch should mark all assets claimed");
        assertEq(claimedShares, finalizedShares, "epoch should mark all shares claimed");
    }

    function test_FinalizedPendingDepositSharesAreEscrowedBeforeClaim() public {
        address pendingLp = address(0xE5C20);
        uint256 depositUsdc = 100_000e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(epochId));
        uint256 incumbentMaxBefore = juniorVault.maxWithdraw(address(this));
        uint256 finalizedShares = juniorVault.finalizeDepositEpoch(epochId);

        assertEq(
            juniorVault.balanceOf(address(juniorVault)),
            finalizedShares,
            "finalized shares must be escrowed before user claim"
        );
        assertApproxEqAbs(
            juniorVault.maxWithdraw(address(this)),
            incumbentMaxBefore,
            2,
            "unclaimed finalized deposits must not boost incumbent withdrawal value"
        );

        vm.prank(pendingLp);
        juniorVault.claimDepositShares(epochId);

        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "claim should release escrowed shares");
        assertEq(juniorVault.balanceOf(pendingLp), finalizedShares, "claim should transfer escrowed shares");
    }

    function test_PendingSeniorDepositUsesSameDelayedActivationFlow() public {
        address trader = address(0x7102);
        address seniorLp = address(0x5E7102);
        uint256 depositUsdc = 25_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        assertEq(seniorVault.maxDeposit(seniorLp), 0, "live positions must close senior immediate deposits");
        assertGt(seniorVault.maxRequestDeposit(seniorLp), 0, "senior pending deposit requests should remain available");

        usdc.mint(seniorLp, depositUsdc);
        vm.startPrank(seniorLp);
        usdc.approve(address(seniorVault), depositUsdc);
        uint256 epochId = seniorVault.requestDeposit(depositUsdc, seniorLp);
        vm.stopPrank();

        uint256 activationTime = seniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(activationTime));
        uint256 finalizedShares = seniorVault.finalizeDepositEpoch(epochId);

        vm.prank(seniorLp);
        uint256 claimedShares = seniorVault.claimDepositShares(epochId);

        assertEq(claimedShares, finalizedShares, "single senior depositor should receive the finalized epoch shares");
        assertEq(seniorVault.balanceOf(seniorLp), claimedShares, "senior claimed shares should be self-custodied");
    }

    function test_OpenInterestBlocksImmediateDepositsEvenWhenMaxLiabilityIsZero() public {
        address trader = address(0x7101);
        address lp = address(0x1A11CE);

        _fundTrader(trader, 5000e6);
        _open(trader, CfdTypes.Side.BEAR, 10_000e18, 2000e6, CAP_PRICE);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(snapshot.maxLiabilityUsdc, 0, "BEAR opened at the cap has no bounded upside liability");
        assertTrue(snapshot.hasOpenPositions, "snapshot must still expose live open interest");
        assertEq(juniorVault.maxDeposit(lp), 0, "any live open interest must close the immediate deposit window");
        assertGt(juniorVault.maxRequestDeposit(lp), 0, "pending deposit requests should remain available");
    }

    function test_CarryIndexIsAccountCheckpointTimingInvariantAcrossPriceSwing() public {
        address checkpointed = address(0xCA11);
        address lazy = address(0x1A2E);
        uint256 size = 100_000e18;
        uint256 margin = 10_000e6;

        _fundTrader(checkpointed, margin + 300e6);
        _fundTrader(lazy, margin + 300e6);
        _open(checkpointed, CfdTypes.Side.BULL, size, margin, 1e8);
        _open(lazy, CfdTypes.Side.BULL, size, margin, 1e8);

        vm.warp(block.timestamp + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        uint256 poolBeforeCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedFirstCarry = pool.totalAssets() - poolBeforeCheckpoint;
        assertGt(checkpointedFirstCarry, 0, "first interval should accrue carry");

        vm.warp(block.timestamp + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(50_000_000, uint64(block.timestamp));

        uint256 poolBeforeSecondCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedSecondCarry = pool.totalAssets() - poolBeforeSecondCheckpoint;

        uint256 poolBeforeLazyCheckpoint = pool.totalAssets();
        _fundTrader(lazy, 100e6);
        uint256 lazyCarry = pool.totalAssets() - poolBeforeLazyCheckpoint;

        assertApproxEqAbs(
            lazyCarry,
            checkpointedFirstCarry + checkpointedSecondCarry,
            2,
            "one late checkpoint should match two earlier checkpoints"
        );
    }

    function test_AddingPositionMarginUpdatesBorrowBaseOnlyAfterOldCarryAccrues() public {
        address account = address(0xB0A);
        uint256 size = 100_000e18;
        uint256 margin = 10_000e6;

        _fundTrader(account, margin + 20_000e6);
        _open(account, CfdTypes.Side.BULL, size, margin, 1e8);
        uint256 borrowBaseBefore = _positionBorrowBaseUsdc(account);

        vm.warp(block.timestamp + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        assertEq(engine.lastMarkTime(), uint64(block.timestamp), "test mark should be fresh");
        uint256 poolBefore = pool.totalAssets();
        vm.prank(account);
        engine.addMargin(account, 10_000e6);
        uint256 realizedCarry = pool.totalAssets() - poolBefore;

        assertGt(realizedCarry, 0, "old borrow base should accrue before the margin increase");
        assertEq(
            _positionBorrowBaseUsdc(account),
            borrowBaseBefore - 10_000e6,
            "added position margin should reduce future borrow base"
        );
    }

    function test_UnderwaterFullCloseFreeFundedBountyCanCommitAndPaysKeeperOnFailure() public {
        address account = address(0xA11CE);
        address keeper = address(0xB0B);
        uint256 size = 100_000e18;

        _fundTrader(account, 2000e6);
        _open(account, CfdTypes.Side.BULL, size, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        _fundTrader(account, router.closeOrderExecutionBountyUsdc());
        uint256 accountBalanceBeforeCommit = clearinghouse.balanceUsdc(account);
        uint256 bountyUsdc = router.closeOrderExecutionBountyUsdc();

        vm.prank(account);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 100_000_000, true);

        bytes[] memory priceData = _mockPythUpdateData(150_000_000);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        assertEq(clearinghouse.balanceUsdc(keeper), bountyUsdc, "failed underwater full close should pay keeper");
        assertApproxEqAbs(
            clearinghouse.balanceUsdc(account),
            accountBalanceBeforeCommit - bountyUsdc,
            1000,
            "failed underwater full close should consume the free-funded bounty"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            0,
            "reserved bounty bucket should be released"
        );
    }

}

contract AuditFixRegressionConservativePendingDepositImpairmentTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_ActivePendingDepositCanCancelWhenConservativeMtmImpairsSenior() public {
        address pendingLp = address(0xCAFE3);
        address trader = address(0xBEA4);
        uint256 depositUsdc = 50e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        _fundTrader(trader, 100e6);
        _open(trader, CfdTypes.Side.BEAR, 1600e18, 50e6, 1e8);

        uint256 activationTime = juniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(CAP_PRICE, uint64(activationTime));

        (uint256 depositSeniorAssets,) = pool.getPendingDepositTrancheState();
        assertGe(
            depositSeniorAssets,
            pool.seniorHighWaterMark(),
            "deposit-neutral view should not see the conservative MTM impairment"
        );
        assertTrue(
            pool.isSeniorImpairedAfterPendingDepositReconcile(),
            "active cancellation gate must match conservative finalization accounting"
        );

        vm.expectRevert(IHousePool.HousePool__SeniorImpaired.selector);
        juniorVault.finalizeDepositEpoch(epochId);

        vm.prank(pendingLp);
        uint256 refunded = juniorVault.cancelPendingDeposit(epochId);

        assertEq(refunded, depositUsdc, "active cancellation should refund escrowed assets");
        assertEq(usdc.balanceOf(pendingLp), depositUsdc, "depositor should recover escrowed USDC");
        assertEq(juniorVault.pendingDepositAssets(pendingLp, epochId), 0, "pending balance should clear");
    }

}
