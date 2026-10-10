// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterCommitmentTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_WithdrawalFirewall() public {
        _startRecordingLogs();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(_sideMaxProfit(CfdTypes.Side.LONG), 50_000 * 1e6, "Max liability = $50k for 50k LONG at $1.00");

        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertEq(fees, 20_000_000, "Protocol should still retain the full 4 bps execution fee");
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            200_000,
            "Keeper should receive the 0.20 USDC capped reward as clearinghouse credit"
        );
        uint256 maxLiability = _maxLiability();
        uint256 settlementBuffer =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps());
        uint256 expectedReserved = maxLiability + engine.totalTraderClaimBalanceUsdc() + settlementBuffer;
        uint256 expectedFree = pool.totalAssets() > expectedReserved ? pool.totalAssets() - expectedReserved : 0;
        assertEq(freeUsdc, expectedFree, "Free USDC should exclude liabilities, claims, and settlement headroom");

        (,, uint256 maxSeniorWithdrawUsdc, uint256 maxJuniorWithdrawUsdc) = pool.getPendingTrancheState();
        uint256 bobMaxWithdraw = _maxRequestableJuniorAssets(bob);
        assertLe(maxSeniorWithdrawUsdc, freeUsdc, "senior request capacity must remain cash-backed");
        assertEq(
            maxJuniorWithdrawUsdc,
            freeUsdc,
            "without a senior redemption backlog, junior request capacity may use the full free-cash budget"
        );
        assertEq(
            bobMaxWithdraw,
            maxJuniorWithdrawUsdc,
            "junior LP should only withdraw the junior tranche share of free USDC"
        );
    }

    function test_CommitOrder_OpenRejectsNonLotSize() public {
        _startRecordingLogs();
        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        router.commitOrder(CfdTypes.Side.LONG, 99e18, 2e6, 1e8, false);
    }

    function test_CommitOrder_AlignedOpenStillRejectsBelowMinimumNotional() public {
        _startRecordingLogs();
        vm.prank(address(router));
        engine.updateMarkPrice(50_000_000, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, 11));
        router.commitOrder(CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM, 2e6, 1e8, false);
    }

    function test_ZeroSizeCommit_Reverts() public {
        _startRecordingLogs();
        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ZeroSize.selector);
        router.commitOrder(CfdTypes.Side.LONG, 0, 500 * 1e6, 1e8, false);
    }

    function test_NonLotPartialCloseCommit_RevertsBeforeQueueMutation() public {
        _startRecordingLogs();
        _fundTrader(alice, 2000e6);
        _open(alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        router.commitOrder(CfdTypes.Side.LONG, 1, 0, 0, true);

        assertEq(router.pendingOrderCounts(alice), 0, "Rejected non-lot close should not enter the FIFO queue");
        assertEq(router.nextCommitId(), 1, "Rejected non-lot close should not consume an order id");
    }

    function test_DustFullResidualCloseCommit_Allowed() public {
        _startRecordingLogs();
        uint256 minCloseSize = 1000e18;

        _fundTrader(alice, 2000e6);
        _open(alice, CfdTypes.Side.LONG, minCloseSize + CfdTypes.SIZE_QUANTUM, 1000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, minCloseSize, 0, 0, true);
        router.commitOrder(CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM, 0, 0, true);
        vm.stopPrank();

        assertEq(router.pendingOrderCounts(alice), 2, "Both meaningful partial and full-residual closes should queue");
        assertEq(
            router.pendingCloseSize(alice),
            minCloseSize + CfdTypes.SIZE_QUANTUM,
            "Queued closes should consume the full residual"
        );
        assertEq(router.nextCommitId(), 3, "Both close orders should receive ids");
    }

    function test_CloseCommit_StaleFallbackDoesNotRevertWhenFreeSettlementExists() public {
        _startRecordingLogs();
        address trader = address(0x3342);
        address account = trader;
        usdc.mint(trader, 251_500_000);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 251_500_000);
        clearinghouse.deposit(account, 251_500_000);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        uint256 freeSettlementBefore = clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc;
        assertEq(
            freeSettlementBefore,
            1_300_000,
            "Setup should leave the larger partial free settlement before the stale close commit"
        );

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        uint256 marginBefore = clearinghouse.pnlPledgeUsdc(account);
        uint256 expectedCarry = _expectedIndexedCarryUsdc(account);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        assertEq(clearinghouse.pnlPledgeUsdc(account), marginBefore - expectedCarry);
        assertEq(_executionBountyReserve(2), 200_000, "Stale close commit should still reservation the full bounty");
        assertEq(
            clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc,
            1_100_000,
            "Stale close fallback should realize indexed carry before reserving from free settlement"
        );
    }

    function test_CloseCommit_FreshCarryCheckpointUsesPositionMargin() public {
        _startRecordingLogs();
        address trader = address(0x3343);
        address account = trader;
        usdc.mint(trader, 252_000_000);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 252_000_000);
        clearinghouse.deposit(account, 252_000_000);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        uint256 freeSettlementBefore = clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc;
        (, uint256 marginBefore,,,,,) = engine.positions(account);
        assertEq(
            freeSettlementBefore,
            1_800_000,
            "Setup should leave the larger free-settlement buffer under the lower open bounty cap"
        );

        vm.warp(block.timestamp + 12 hours);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = _expectedIndexedCarryUsdc(account);
        uint256 reservedSettlementBefore = clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc;

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        uint256 marginConsumed = marginBefore - marginAfter;
        assertEq(_executionBountyReserve(2), 200_000, "Fresh carry checkpoint should still reservation the full bounty");
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc - reservedSettlementBefore,
            200_000,
            "Close commit should reserve exactly 0.20 USDC of bounty value"
        );
        assertApproxEqAbs(
            clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc,
            freeSettlementBefore - 200_000,
            32,
            "Carry-aware reservation should only consume the reduced close-order bounty from post-carry free settlement"
        );
        assertEq(marginConsumed, expectedCarry, "Carry consumes margin while bounty alone consumes free settlement");
    }

}
