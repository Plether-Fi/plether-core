// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#lp-capital-carry

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract PendingDepositLifecycleCarryTest is BasePerpTest {

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_CarryCheckpointsChargeMaximumProfitAcrossPriceSwing() public {
        address checkpointed = address(0xCA11);
        address lazy = address(0x1A2E);
        uint256 size = 100_000e18;
        uint256 margin = 10_000e6;

        _fundTrader(checkpointed, margin + 300e6);
        _fundTrader(lazy, margin + 300e6);
        _open(checkpointed, CfdTypes.Side.LONG, size, margin, 1e8);
        _open(lazy, CfdTypes.Side.LONG, size, margin, 1e8);

        // Cheatcode time reads prevent via-IR from reusing a timestamp across the two warps.
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(vm.getBlockTimestamp()));

        uint256 expectedFirst = _expectedIndexedCarryAssets(checkpointed);
        uint256 poolBeforeCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedFirstCarry = pool.totalAssets() - poolBeforeCheckpoint;
        assertGt(checkpointedFirstCarry, 0, "first interval should accrue carry");
        assertEq(checkpointedFirstCarry, expectedFirst);

        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(50_000_000, uint64(vm.getBlockTimestamp()));

        uint256 expectedSecond = _expectedIndexedCarryAssets(checkpointed);
        uint256 poolBeforeSecondCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedSecondCarry = pool.totalAssets() - poolBeforeSecondCheckpoint;

        assertGt(checkpointedSecondCarry, 0, "second interval should accrue carry");
        assertEq(checkpointedSecondCarry, expectedSecond);
        uint256 expectedLazy = _expectedIndexedCarryAssets(lazy);
        uint256 poolBeforeLazyCheckpoint = pool.totalAssets();
        _fundTrader(lazy, 100e6);
        uint256 lazyCarry = pool.totalAssets() - poolBeforeLazyCheckpoint;

        assertEq(lazyCarry, expectedLazy);
        assertApproxEqAbs(
            checkpointedFirstCarry + checkpointedSecondCarry,
            lazyCarry,
            1,
            "Collection timing cannot change the exposure or flat rate; only per-checkpoint rounding may differ"
        );
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_AddingPositionMarginPreservesFullMaxProfitCarryBasis() public {
        address account = address(0xB0A);
        uint256 size = 100_000e18;
        uint256 margin = 10_000e6;

        _fundTrader(account, margin + 20_000e6);
        _open(account, CfdTypes.Side.LONG, size, margin, 1e8);
        uint256 maxProfitBefore = _positionMaxProfitAssets(account);

        vm.warp(block.timestamp + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        assertEq(engine.lastMarkTime(), uint64(block.timestamp), "test mark should be fresh");
        uint256 poolBefore = pool.totalAssets();
        vm.prank(account);
        engine.addMargin(account, 10_000e6);
        uint256 realizedCarry = pool.totalAssets() - poolBefore;

        assertGt(realizedCarry, 0, "maximum-profit exposure should accrue before the margin increase");
        assertEq(
            _positionMaxProfitAssets(account),
            maxProfitBefore,
            "adding margin and collecting carry must not change the full maximum-profit basis"
        );
    }

}

contract SyntheticCarryCacheSettlementTest is BasePerpTest {

    using stdStorage for StdStorage;

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_CloseClearsUnsettledCarryAfterSettlement() public {
        address trader = address(0xA1101);
        address account = trader;

        _fundTrader(trader, 100_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 50_000e6, 1e8);

        stdstore.target(address(engine)).sig("unsettledCarryAssets(address)").with_key(account)
            .checked_write(uint256(10e6));

        _close(account, CfdTypes.Side.LONG, 100_000e18, 1e8);

        assertEq(engine.unsettledCarryAssets(account), 0, "Close should clear cached unsettled carry");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_LiquidationClearsUnsettledCarryAfterSettlement() public {
        address trader = address(0xA1102);
        address keeper = address(0xA1103);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 8000e6);

        stdstore.target(address(engine)).sig("unsettledCarryAssets(address)").with_key(account)
            .checked_write(uint256(1e6));

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        _ensureLaterOracleTime();
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertEq(engine.unsettledCarryAssets(account), 0, "Liquidation should clear cached unsettled carry");
    }

}

contract CarryCollectionTimingTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_MarkRefreshPreservesSameTimeCarrySettlement() public {
        address account = alice;
        _fundTrader(alice, 150_000e6);
        _open(account, CfdTypes.Side.LONG, 200_000e18, 100_120e6, 1e8);

        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(120_000_000, uint64(vm.getBlockTimestamp()));
        _close(account, CfdTypes.Side.LONG, 200_000e18, 120_000_000);
        uint256 markThenTradeBalance = clearinghouse.balanceAssets(account);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 days);
        _close(account, CfdTypes.Side.LONG, 200_000e18, 120_000_000);
        uint256 tradeOnlyBalance = clearinghouse.balanceAssets(account);

        assertEq(tradeOnlyBalance, markThenTradeBalance, "Carry realization should not depend on update-vs-trade path");
    }

}

contract CarryAndMarginCheckpointCarryTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_FullCloseMustZeroFundedSideMargin() public {
        address longTrader = address(0x1111);
        address shortTrader = address(0x2222);
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        _fundTrader(longTrader, 100_000 * 1e6);
        _fundTrader(shortTrader, 600_000 * 1e6);
        // This regression targets post-close side margin, so fund the independent admission headroom first.
        _fundJunior(address(this), 1000 * 1e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 1_000_000 * 1e18, 100_000 * 1e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 365 days);
        _close(longAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 1e8);

        assertEq(_sideTotalMargin(CfdTypes.Side.LONG), 0, "Full close should remove all long position margin");
    }

}

contract HistoricalCarryCheckpointTest is BasePerpTest {

    address trader = address(0xCA22A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_CarryCheckpointCannotForgiveHistoricalExposureTime() public {
        _fundTrader(trader, 150_000e6);
        _open(trader, CfdTypes.Side.LONG, 200_000e18, 100_000e6, 1e8);

        uint256 balanceBeforeCheckpoint = clearinghouse.balanceAssets(trader);
        uint256 elapsed = 30 days;
        uint256 entryMaxProfitAssets = 200_000e6;
        uint256 minimumHistoricalCarryAssets =
            (entryMaxProfitAssets * 500 * elapsed) / (CfdMath.SECONDS_PER_YEAR * 10_000);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(0.5e8, uint64(vm.getBlockTimestamp()));

        settlementToken.mint(trader, 1);
        vm.startPrank(trader);
        settlementToken.approve(address(clearinghouse), 1);
        clearinghouse.deposit(trader, 1);
        vm.stopPrank();

        uint256 balanceAfterCheckpoint = clearinghouse.balanceAssets(trader);
        assertApproxEqAbs(
            balanceAfterCheckpoint,
            balanceBeforeCheckpoint + 1 - minimumHistoricalCarryAssets,
            1,
            "A favorable price cannot reprice the full entry maximum-profit exposure"
        );
    }

}

/// @notice Known-value integration checks for flat annual maximum-profit carry.
contract FlatMaximumProfitCarryTest is BasePerpTest {

    address private constant LONG_TRADER = address(0xF1A71);
    address private constant SHORT_TRADER = address(0xF1A72);
    uint256 private constant PRICE = 80_000_000;

    function _checkpointFlatCarry(
        address account
    ) private returns (uint256 collected) {
        uint256 beforeCash = pool.accountedAssets();
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(account);
        return pool.accountedAssets() - beforeCash;
    }

    function test_FullyAndOverMarginedPositionsPayFivePercentOnBothSides() public {
        _fundTrader(LONG_TRADER, 120_000e6);
        _fundTrader(SHORT_TRADER, 170_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, 150_000e6, PRICE);
        assertGt(clearinghouse.pnlPledgeAssets(LONG_TRADER), 80_000e6);
        assertGt(clearinghouse.pnlPledgeAssets(SHORT_TRADER), 120_000e6);
        assertEq(_positionMaxProfitAssets(LONG_TRADER), 80_000e6);
        assertEq(_positionMaxProfitAssets(SHORT_TRADER), 120_000e6);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(_checkpointFlatCarry(LONG_TRADER), 4000e6, "$80k maximum profit costs $4k per year");
        assertEq(_checkpointFlatCarry(SHORT_TRADER), 6000e6, "$120k maximum profit costs $6k per year");
        assertEq(_positionMaxProfitAssets(LONG_TRADER), 80_000e6, "margin-funded carry cannot grow its own basis");
        assertEq(_positionMaxProfitAssets(SHORT_TRADER), 120_000e6);
        assertEq(_checkpointFlatCarry(LONG_TRADER), 0, "same-time collection cannot charge twice");
    }

    function test_ZeroAndDifferentPoolDepthsDoNotChangeAnnualCarry() public {
        _fundTrader(LONG_TRADER, 100_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 50_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();
        for (uint256 scenario; scenario < 3; ++scenario) {
            uint256 snapshot = vm.snapshotState();
            uint256 initialCash = pool.rawAssets();
            uint256 drain = scenario == 0 ? 0 : scenario == 1 ? initialCash / 2 : initialCash;
            if (drain > 0) {
                vm.prank(address(pool));
                settlementToken.transfer(address(0xDEAD), drain);
            }
            if (scenario == 2) {
                assertEq(pool.totalAssets(), 0, "the final scenario has no pool depth");
            }
            vm.warp(started + 365 days);
            assertEq(_checkpointFlatCarry(LONG_TRADER), 4000e6, "only position exposure and elapsed time set carry");
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_OtherPositionsOpeningAndClosingDoNotRepriceExistingCarry() public {
        _fundTrader(LONG_TRADER, 120_000e6);
        _fundTrader(SHORT_TRADER, 170_000e6);
        address anotherLong = address(0xF1A73);
        _fundTrader(anotherLong, 120_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();
        vm.warp(started + 365 days / 2);
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, 150_000e6, PRICE);
        _open(anotherLong, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        _close(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, PRICE);
        _close(anotherLong, CfdTypes.Side.LONG, 100_000e18, PRICE);
        vm.warp(started + 365 days);
        assertEq(
            _checkpointFlatCarry(LONG_TRADER), 4000e6, "other traders cannot discount or raise this position's rent"
        );
    }

    function test_GlobalIndexIsSharedAndLateOppositeOpenPaysOnlyItsHoldingTime() public {
        _fundTrader(LONG_TRADER, 120_000e6);
        _fundTrader(SHORT_TRADER, 170_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();

        vm.warp(started + 365 days / 2);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), 0.025e18, "the only clock has accrued one half-year");
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, 150_000e6, PRICE);
        (, uint256 shortStartIndex,) = engine.positionCarryState(SHORT_TRADER);
        assertEq(shortStartIndex, 0.025e18, "a late opposite-side open captures the existing global index");

        vm.warp(started + 365 days);
        assertEq(_checkpointFlatCarry(LONG_TRADER), 4000e6, "the original long pays for its full year");
        assertEq(_checkpointFlatCarry(SHORT_TRADER), 3000e6, "the new short pays only for its half-year");
        assertEq(engine.carryIndex(), 0.05e18);
    }

    function test_EmptyMarketReopenDoesNotInheritIdleTime() public {
        _fundTrader(LONG_TRADER, 120_000e6);
        _fundTrader(SHORT_TRADER, 170_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();
        vm.warp(started + 365 days / 2);
        uint256 poolBefore = pool.accountedAssets();
        _close(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, PRICE);
        assertEq(pool.accountedAssets() - poolBefore, 2000e6);
        assertEq(_sideState(CfdTypes.Side.LONG).maxProfitAssets, 0);
        assertEq(_sideState(CfdTypes.Side.SHORT).maxProfitAssets, 0);
        assertEq(engine.carryIndex(), 0.025e18);

        vm.warp(started + 3 * 365 days / 2);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), 0.025e18, "an empty market does not grow its carry index");
        assertEq(engine.carryTimestamp(), vm.getBlockTimestamp(), "the idle checkpoint closes the old interval");
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, 150_000e6, PRICE);
        (, uint256 reopenedAtIndex,) = engine.positionCarryState(SHORT_TRADER);
        assertEq(reopenedAtIndex, 0.025e18);

        vm.warp(started + 2 * 365 days);
        assertEq(_checkpointFlatCarry(SHORT_TRADER), 3000e6, "the reopened market pays only its active half-year");
        assertEq(engine.carryIndex(), 0.05e18);
    }

    function test_GlobalRateChangeAppliesProspectivelyToBothSides() public {
        _fundTrader(LONG_TRADER, 120_000e6);
        _fundTrader(SHORT_TRADER, 170_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, 100_000e18, 150_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.baseCarryBps = 1000;
        engineAdmin.proposeRiskConfig(config);

        vm.warp(started + 365 days / 2);
        engineAdmin.finalizeRiskConfig();
        assertEq(engine.carryIndex(), 0.025e18, "governance checkpoints both sides' old rate once");
        vm.warp(started + 365 days);
        assertEq(_checkpointFlatCarry(LONG_TRADER), 6000e6, "$80k pays half a year each at five and ten percent");
        assertEq(_checkpointFlatCarry(SHORT_TRADER), 9000e6, "$120k uses the same prospective rate history");
        assertEq(engine.carryIndex(), 0.075e18);
    }

    function test_IncreaseAndPartialCloseApplyNewExposureOnlyToFutureTime() public {
        _fundTrader(LONG_TRADER, 150_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        uint256 started = vm.getBlockTimestamp();
        for (uint256 scenario; scenario < 2; ++scenario) {
            uint256 snapshot = vm.snapshotState();
            vm.warp(started + 365 days / 2);
            uint256 cashBefore = pool.accountedAssets();
            if (scenario == 0) {
                _open(LONG_TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, PRICE);
                assertEq(_positionMaxProfitAssets(LONG_TRADER), 160_000e6);
            } else {
                _close(LONG_TRADER, CfdTypes.Side.LONG, 50_000e18, PRICE);
                assertEq(_positionMaxProfitAssets(LONG_TRADER), 40_000e6);
            }
            // At unchanged price and zero VPI, only historical carry reaches pool cash here.
            assertEq(pool.accountedAssets() - cashBefore, 2000e6, "the first half-year uses the original $80k exposure");
            vm.warp(started + 365 days);
            assertEq(_checkpointFlatCarry(LONG_TRADER), scenario == 0 ? 4000e6 : 1000e6);
            assertTrue(vm.revertToState(snapshot));
        }
    }

}
