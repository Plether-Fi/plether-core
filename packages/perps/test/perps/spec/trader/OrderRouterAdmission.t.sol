// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterAdmissionTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_CommitOrder_RevertsOnPredictableInsufficientInitialMargin() public {
        _startRecordingLogs();
        address eve = address(0xE111);
        _fundTrader(eve, 1000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(eve);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 100e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictableMustCloseOpposing() public {
        _startRecordingLogs();
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING)
            )
        );
        router.commitOrder(CfdTypes.Side.SHORT, 5000e18, 500e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictablePositionTooSmall() public {
        _startRecordingLogs();
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM, 5000e6, 1e8, false);
    }

    function test_CommitOrder_DoesNotUseStaleCachedMarkForPredictableOpenPrefilter() public {
        _startRecordingLogs();
        address eve = address(0xE112);
        address eveAccount = eve;
        _fundTrader(eve, 1000e6);

        vm.warp(block.timestamp + router.pletherOracle().orderExecutionStalenessLimit() + 1);

        vm.prank(eve);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 100e6, 1e8, false);

        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(eveAccount);
        assertEq(pending.length, 1, "Stale cached marks should skip commit-time predictable-open rejection");
        assertEq(pending[0].sizeDelta, 100_000e18, "Queued order should preserve the requested open intent");
    }

    /// @dev Bucket: spec. Source: ACCOUNTING_SPEC "Open projection" permits above-cap recovery only while the order
    ///      side remains lighter; crossing balance may reach the cap but must not rebuild an above-cap imbalance.
    function test_AboveCapSkewReduction_PreviewCommitAndExecutionSucceed() public {
        _startRecordingLogs();
        address longTrader = address(0xB011);
        address healingShortTrader = address(0xBEA1);
        address crossingShortTrader = address(0xBEA2);
        _fundTrader(longTrader, 50_000e6);
        _fundTrader(healingShortTrader, 20_000e6);
        _fundTrader(crossingShortTrader, 30_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 300_000e18, 30_000e6, 1e8);

        uint256 targetPoolAssetsUsdc = 700_000e6;
        uint256 poolAssetsBeforeDrainUsdc = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssetsBeforeDrainUsdc - targetPoolAssetsUsdc);

        uint256 poolAssetsUsdc = pool.totalAssets();
        uint256 maxSkewUsdc = (poolAssetsUsdc * 0.4e18) / 1e18;
        uint256 preSkewUsdc = 300_000e6;
        uint256 healingSize = 10_000e18;
        uint256 postHealingSkewUsdc = preSkewUsdc - 10_000e6;
        assertEq(poolAssetsUsdc, targetPoolAssetsUsdc, "Setup should establish the intended skew denominator");
        assertGt(preSkewUsdc, maxSkewUsdc, "Setup should begin above the configured skew cap");
        assertGt(postHealingSkewUsdc, maxSkewUsdc, "The healing order should remain above the skew cap");

        _assertAboveCapPreviewPolicy(healingShortTrader, crossingShortTrader, healingSize);

        vm.prank(healingShortTrader);
        router.commitOrder(CfdTypes.Side.SHORT, healingSize, 1000e6, 1e8, false);
        assertEq(router.pendingOrderCounts(healingShortTrader), 1, "Skew-reducing order should pass commit validation");

        vm.warp(block.timestamp + 6);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory updateData = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, updateData);

        (uint256 liveSize,,,, CfdTypes.Side liveSide,,) = engine.positions(healingShortTrader);
        assertEq(liveSize, healingSize, "Skew-reducing order should execute");
        assertEq(uint8(liveSide), uint8(CfdTypes.Side.SHORT), "Executed position should use the healing side");
        assertEq(
            _sideOpenInterest(CfdTypes.Side.LONG) - _sideOpenInterest(CfdTypes.Side.SHORT),
            postHealingSkewUsdc * 1e12,
            "Execution should leave the expected reduced open-interest skew"
        );
    }

    function test_CloseCommit_RevertsWhenPendingCloseSizeWouldExceedPosition() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _open(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8);

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 6000 * 1e18, 0, 0, true);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SizeExceedsQueued.selector);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 0, true);
        vm.stopPrank();

        assertEq(
            router.pendingCloseSize(aliceAccount),
            6000 * 1e18,
            "Only the first queued close should count toward pending close size"
        );
    }

    function test_CloseCommit_BehindPendingOpenIsRejected() public {
        _startRecordingLogs();
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);
        vm.stopPrank();

        assertEq(router.nextCommitId(), 2, "Rejected close intents should not queue against pending open exposure");
    }

    function test_TraderClaim_CloseBehindPendingOpenIsRejected() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 8000 * 1e6, 1e8, false);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 0, 0, true);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory priceData = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp + 6);
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, priceData);

        assertEq(
            router.nextExecuteId(),
            0,
            "Rejected close intent should not stall the FIFO queue and the remaining opens should drain cleanly"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            200_000,
            "Batch executor should only be paid for the single successful order that remains queued"
        );

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(
            reservation.pendingOrderCount, 0, "Queued orders should be fully consumed even when one close defers payout"
        );
    }

}

