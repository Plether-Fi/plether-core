// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {AtomicLpEpochSettlementTestFixture} from "../../shared/AtomicLpEpochSettlementFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

contract ScheduledMarketClosureTest is AtomicLpEpochSettlementTestFixture {

    uint64 internal constant DEC_24_CLOSE = 1_798_149_600; // 2026-12-24 22:00 UTC.
    uint64 internal constant DEC_31_CLOSE = 1_798_754_400; // 2026-12-31 22:00 UTC.
    uint64 internal constant CLOSURE_DURATION = 7 hours; // Reopens at 05:00 UTC the next day.
    uint256 internal constant PRE_CLOSE_PRICE = 100_000_000;
    uint256 internal constant REOPEN_PRICE = 99_000_000;
    uint256 internal constant POSITION_SIZE = 1000e18;
    uint256 internal constant WITHDRAWAL = 1e6;

    function test_December24Closure_PreservesExitsAndResumesLivePricesAtReopen() public {
        _assertClosureAndReopen(DEC_24_CLOSE);
    }

    function test_December31Closure_PreservesExitsAndResumesLivePricesAtReopen() public {
        _assertClosureAndReopen(DEC_31_CLOSE);
    }

    function _assertClosureAndReopen(
        uint256 closeTime
    ) internal {
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadRunwaySeconds = 30 minutes;
        config.marketClosures = new ICfdEngineAdminHost.MarketClosure[](2);
        config.marketClosures[0] = ICfdEngineAdminHost.MarketClosure(DEC_24_CLOSE, DEC_24_CLOSE + CLOSURE_DURATION);
        config.marketClosures[1] = ICfdEngineAdminHost.MarketClosure(DEC_31_CLOSE, DEC_31_CLOSE + CLOSURE_DURATION);
        _setCalendarConfig(config);

        vm.warp(closeTime - 4 hours);
        uint256 redeemShares = _seedJuniorLp(ALICE, 100_000e6) / 2;
        _openMarkSensitivePosition();

        vm.warp(closeTime - config.fadRunwaySeconds - 1);
        assertFalse(engine.isFadWindow(), "trading stays live until the scheduled runway");
        vm.warp(closeTime - config.fadRunwaySeconds);
        assertTrue(engine.isFadWindow(), "the configured runway starts before the closure");
        assertFalse(pletherOracle.isOracleFrozen(), "the runway still uses live prices");
        uint256 redeemId = _requestJuniorRedeem(ALICE, redeemShares);
        assertEq(pool.lpEpochStart(redeemId), closeTime, "request must mature at the start of the closure");

        vm.warp(closeTime - 1);
        assertFalse(pletherOracle.isOracleFrozen(), "the last second before closing still accepts fresh prices");
        router.updateMarkPrice(_encodedUpdateData(PRE_CLOSE_PRICE));

        vm.warp(closeTime);
        assertTrue(pletherOracle.isOracleFrozen(), "the freeze starts at the configured close");

        uint256 reopenTime = closeTime + CLOSURE_DURATION;
        vm.warp(reopenTime - 1);
        assertTrue(pletherOracle.isOracleFrozen(), "the freeze survives UTC midnight until reopening");
        uint256 beforeFrozenExits = vm.snapshotState();
        _assertFrozenExits(redeemId, redeemShares, closeTime - 1);
        assertTrue(vm.revertToState(beforeFrozenExits));

        vm.warp(reopenTime);
        assertFalse(pletherOracle.isOracleFrozen(), "fresh-price policy resumes at the configured reopen");
        assertTrue(engine.isFadWindow(), "the reopening lag keeps FAD without freezing the oracle");
        _assertLiveExits(redeemId, redeemShares, closeTime - 1, reopenTime);

        vm.warp(reopenTime + 15 minutes - 1);
        assertTrue(engine.isFadWindow(), "FAD applies through the last second of the reopening lag");
        vm.warp(reopenTime + 15 minutes);
        assertFalse(engine.isFadWindow(), "normal execution resumes at the end of the lag");
    }

    function _assertFrozenExits(
        uint256 redeemId,
        uint256 redeemShares,
        uint256 cachedMarkTime
    ) internal {
        _assertMarginWithdrawal();

        vm.prank(CAROL);
        IHousePool.LpEpochSettlementResult memory funded = pool.settleLpEpoch(0, 0);
        assertEq(funded.juniorFundedShares, redeemShares, "the matured redemption can settle on the cached mark");
        assertGt(funded.juniorFundedAssets, 0);
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), redeemShares);

        uint64 closeId = _commitPositionClose();
        _startRecordingLogs();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(closeId, new bytes[](0));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), closeId);
        assertEq(uint8(receipt.executionMode), uint8(OrderV3Types.ExecutionMode.Frozen));
        assertEq(receipt.executionPrice, PRE_CLOSE_PRICE);
        assertEq(engine.lastMarkTime(), cachedMarkTime, "frozen exits do not advance the cached mark");
    }

    function _assertLiveExits(
        uint256 redeemId,
        uint256 redeemShares,
        uint256 cachedMarkTime,
        uint256 reopenTime
    ) internal {
        vm.prank(TRADER);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdrawMargin(WITHDRAWAL);

        vm.prank(CAROL);
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(0, 0);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.settleLpEpoch(new bytes[](0));
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), redeemShares);
        assertEq(engine.lastMarkTime(), cachedMarkTime);

        router.settleLpEpoch(_encodedUpdateData(REOPEN_PRICE));
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), redeemShares);
        assertEq(engine.lastMarkPrice(), REOPEN_PRICE);
        assertEq(engine.lastMarkTime(), reopenTime);
        _assertMarginWithdrawal();

        uint64 closeId = _commitPositionClose();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(reopenTime + 1);
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder(closeId, _basketData(PRE_CLOSE_PRICE, 0, cachedMarkTime, cachedMarkTime));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));

        _startRecordingLogs();
        result = router.executeOrder(closeId, _encodedUpdateData(REOPEN_PRICE));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), closeId);
        assertEq(uint8(receipt.executionMode), uint8(OrderV3Types.ExecutionMode.Fad));
        assertEq(receipt.executionPrice, REOPEN_PRICE);
    }

    function _assertMarginWithdrawal() internal {
        uint256 beforeBalance = settlementToken.balanceOf(TRADER);
        vm.prank(TRADER);
        clearinghouse.withdrawMargin(WITHDRAWAL);
        assertEq(settlementToken.balanceOf(TRADER) - beforeBalance, WITHDRAWAL);
    }

    function _commitPositionClose() internal returns (uint64 closeId) {
        vm.prank(TRADER);
        return router.commitOrder(CfdTypes.Side.LONG, POSITION_SIZE, 0, 0, true);
    }

}
