// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#lp-capital-carry

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract PendingDepositLifecycleCarryTest is BasePerpTest {

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_CarryCheckpointsChargeIndexedBorrowBaseAcrossPriceSwing() public {
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

        uint256 expectedFirst = _expectedIndexedCarryUsdc(checkpointed);
        uint256 poolBeforeCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedFirstCarry = pool.totalAssets() - poolBeforeCheckpoint;
        assertGt(checkpointedFirstCarry, 0, "first interval should accrue carry");
        assertEq(checkpointedFirstCarry, expectedFirst);

        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(address(router));
        engine.updateMarkPrice(50_000_000, uint64(vm.getBlockTimestamp()));

        uint256 expectedSecond = _expectedIndexedCarryUsdc(checkpointed);
        uint256 poolBeforeSecondCheckpoint = pool.totalAssets();
        _fundTrader(checkpointed, 100e6);
        uint256 checkpointedSecondCarry = pool.totalAssets() - poolBeforeSecondCheckpoint;

        assertGt(checkpointedSecondCarry, 0, "second interval should accrue carry");
        assertEq(checkpointedSecondCarry, expectedSecond);
        uint256 expectedLazy = _expectedIndexedCarryUsdc(lazy);
        uint256 poolBeforeLazyCheckpoint = pool.totalAssets();
        _fundTrader(lazy, 100e6);
        uint256 lazyCarry = pool.totalAssets() - poolBeforeLazyCheckpoint;

        assertEq(lazyCarry, expectedLazy);
        assertGt(
            checkpointedFirstCarry + checkpointedSecondCarry,
            lazyCarry,
            "Earlier margin collection increases the later borrow base; previously assessed carry is never recomputed"
        );
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_AddingPositionMarginUpdatesBorrowBaseOnlyAfterOldCarryAccrues() public {
        address account = address(0xB0A);
        uint256 size = 100_000e18;
        uint256 margin = 10_000e6;

        _fundTrader(account, margin + 20_000e6);
        _open(account, CfdTypes.Side.LONG, size, margin, 1e8);
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
            borrowBaseBefore + realizedCarry - 10_000e6,
            "added position margin should reduce future borrow base"
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

        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(account)
            .checked_write(uint256(10e6));

        _close(account, CfdTypes.Side.LONG, 100_000e18, 1e8);

        assertEq(engine.unsettledCarryUsdc(account), 0, "Close should clear cached unsettled carry");
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

        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(account)
            .checked_write(uint256(1e6));

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertEq(engine.unsettledCarryUsdc(account), 0, "Liquidation should clear cached unsettled carry");
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
            minBountyUsdc: 5 * 1e6,
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
        engine.updateMarkPrice(120_000_000, uint64(block.timestamp));
        _close(account, CfdTypes.Side.LONG, 200_000e18, 120_000_000);
        uint256 markThenTradeBalance = clearinghouse.balanceUsdc(account);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 days);
        _close(account, CfdTypes.Side.LONG, 200_000e18, 120_000_000);
        uint256 tradeOnlyBalance = clearinghouse.balanceUsdc(account);

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
            minBountyUsdc: 5 * 1e6,
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
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_CarryCheckpointCannotForgiveHistoricalLpBackedTime() public {
        _fundTrader(trader, 150_000e6);
        _open(trader, CfdTypes.Side.LONG, 200_000e18, 100_000e6, 1e8);

        uint256 balanceBeforeCheckpoint = clearinghouse.balanceUsdc(trader);
        uint256 elapsed = 30 days;
        uint256 entryPriceLpBackedNotionalUsdc = 9000e6;
        uint256 minimumHistoricalCarryUsdc =
            (entryPriceLpBackedNotionalUsdc * 500 * elapsed) / (CfdMath.SECONDS_PER_YEAR * 10_000);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(0.5e8, uint64(block.timestamp));

        usdc.mint(trader, 1);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 1);
        clearinghouse.deposit(trader, 1);
        vm.stopPrank();

        uint256 balanceAfterCheckpoint = clearinghouse.balanceUsdc(trader);
        assertLe(
            balanceAfterCheckpoint,
            balanceBeforeCheckpoint + 1 - minimumHistoricalCarryUsdc,
            "A favorable checkpoint price must not erase carry owed for historical LP-backed exposure"
        );
    }

}
