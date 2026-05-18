// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {IHousePool} from "../../src/perps/interfaces/IHousePool.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

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
