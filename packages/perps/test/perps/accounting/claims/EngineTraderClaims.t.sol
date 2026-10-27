// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ClaimEngineViewTypes} from "@plether/perps/interfaces/ClaimEngineViewTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineTraderClaimsTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_ProfitableClose_RecordsTraderClaimWhenPoolIlliquid() public {
        address account = address(0xD301);
        _fundTrader(address(0xD301), 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 clearinghouseBefore = clearinghouse.balanceAssets(account);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Profitable close should still destroy the position");
        assertGt(engine.traderClaimBalanceAssets(account), 0, "Unpaid profit should be recorded as trader claim");
        assertEq(
            clearinghouse.balanceAssets(account),
            clearinghouseBefore,
            "Illiquid profitable close should not immediately credit clearinghouse cash"
        );
    }

    function test_SettleTraderClaim_CreditsClearinghouseWhenLiquidityReturns() public {
        address trader = address(0xD302);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceAssets(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim");

        settlementToken.mint(address(pool), traderClaim);
        uint256 clearinghouseBefore = clearinghouse.balanceAssets(account);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceAssets(account), 0, "Claim should clear trader claim state");
        assertEq(
            clearinghouse.balanceAssets(account),
            clearinghouseBefore + traderClaim,
            "Claim should credit the clearinghouse balance"
        );
    }

    function test_SettleTraderClaim_NoOpenPositionCheckpointsCarryBeforePoolPayout() public {
        address trader = address(0xD30A11CE);
        address claimant = address(0xD30B0B);

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);

        uint256 claimAssets = 1000e6;
        stdstore.target(address(engine)).sig("traderClaimBalanceAssets(address)").with_key(claimant)
            .checked_write(claimAssets);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(claimAssets);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedCarryIndex = _currentSideCarryIndex(CfdTypes.Side.LONG);
        uint256 poolAssetsBefore = pool.totalAssets();

        vm.prank(claimant);
        engine.settleTraderClaim(claimant);

        uint256 sideIndex = uint256(CfdTypes.Side.LONG);
        assertEq(
            engine.sideCarryIndex(sideIndex),
            expectedCarryIndex,
            "Claim payout should checkpoint carry with the pre-payout net denominator"
        );
        assertEq(engine.sideCarryTimestamp(sideIndex), block.timestamp, "Claim payout should advance carry timestamp");
        assertEq(
            pool.totalAssets(), poolAssetsBefore - claimAssets, "Setup should reduce pool assets after claim service"
        );
    }

    function test_SettleTraderClaim_RealizesCarryBeforeCreditingSettlement() public {
        address trader = address(0xD30B);
        address account = trader;
        _fundTrader(trader, 20_000e6);

        _open(account, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);
        _seedAuthenticatedTraderClaim(account, 5000e6);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        settlementToken.mint(address(pool), 5000e6);
        uint256 expectedCarry = _expectedIndexedCarry(account);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(
            clearinghouse.balanceAssets(account),
            settlementBefore + 5000e6 - expectedCarry,
            "Trader claim settlement should realize carry before crediting settlement"
        );
        assertEq(
            pool.rawAssets(),
            poolRawBefore + expectedCarry - 5000e6,
            "Claim should net payout against realized carry cash flow"
        );
        assertEq(
            pool.accountedAssets(),
            poolAccountedBefore + expectedCarry - 5000e6,
            "Claim should keep accounted assets aligned with net physical cash after carry realization"
        );
    }

    function test_SettleTraderClaim_UsesIndexedCarryCheckpointWhenMarkIsStale() public {
        address trader = address(0xD30C);
        address account = trader;
        _fundTrader(trader, 20_000e6);

        _open(account, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);
        _seedAuthenticatedTraderClaim(account, 5000e6);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        settlementToken.mint(address(pool), 5000e6);
        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceAssets(account), 0, "Claim should clear trader claim state");
        assertEq(
            clearinghouse.balanceAssets(account),
            settlementBefore + 5000e6 - expectedCarry,
            "Stale trader claim settlement should checkpoint indexed carry before crediting settlement"
        );
        assertEq(
            _lastCarryTimestamp(account),
            block.timestamp,
            "Stale trader claim settlement should advance the carry clock after checkpointing carry"
        );
        assertEq(
            engine.unsettledCarryAssets(account),
            0,
            "Stale trader claim settlement should not leave carry unpaid once the claim-funded settlement can satisfy it"
        );
    }

    function test_TraderClaimConsistency_PreservesOtherReservedCash() public {
        address trader = address(0xD30D1);
        address account = trader;
        uint256 traderClaim = 5000e6;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        _seedAuthenticatedTraderClaim(account, traderClaim);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        settlementToken.mint(address(pool), traderClaim);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            afterSnapshot.protocolTreasuryBalanceAssets,
            beforeSnapshot.protocolTreasuryBalanceAssets,
            "Trader trader claim must not consume treasury fee balance"
        );
        assertEq(
            afterSnapshot.totalTraderClaimBalanceAssets, 0, "Claim should extinguish the trader trader claim liability"
        );
        assertEq(
            beforeSnapshot.withdrawalReservedAssets - afterSnapshot.withdrawalReservedAssets,
            traderClaim,
            "Withdrawal reserve should drop only by the trader claim amount that was actually claimed"
        );
    }

    function test_SettleTraderClaim_RevertsForNonOwner() public {
        address trader = address(0xD307);
        address relayer = address(0xD308);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceAssets(account);
        settlementToken.mint(address(pool), traderClaim);

        vm.prank(relayer);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotAccountOwner.selector);
        engine.settleTraderClaim(account);
    }

    function test_SettleTraderClaim_RevertsUntilTraderClaimLiabilitiesAreFullyCovered() public {
        address trader = address(0xD306);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceAssets(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim");

        uint256 partialLiquidity = traderClaim / 2;
        settlementToken.mint(address(pool), partialLiquidity);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(
            engine.traderClaimBalanceAssets(account),
            traderClaim,
            "Trader claimant should remain fully queued until aggregate trader claim liabilities are fully covered"
        );
    }

    function test_SettleTraderClaim_RevertsDuringAggregateShortfallEvenForLargestClaimant() public {
        address trader = address(0xD309);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceAssets(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim balance");

        vm.startPrank(address(pool));
        settlementToken.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        uint256 partialLiquidity = traderClaim / 2;
        settlementToken.mint(address(pool), partialLiquidity);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceAssets(account), traderClaim, "Head trader claim should remain fully queued");
    }

    function test_SettleTraderClaim_RevertsWithoutLiquidityOrPayout() public {
        address trader = address(0xD303);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTraderClaim.selector);
        engine.settleTraderClaim(account);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        settlementToken.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        engine.settleTraderClaim(account);
    }

    function test_GetPositionView_DoesNotCountTraderClaimAsPhysicalCollateral() public {
        address trader = address(0xAB1101);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.SHORT, 10_000e18, 5000e6, 1e8);

        uint256 closeExecutionFeeAssets = _engineExecutionFeeAssets(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - closeExecutionFeeAssets - 1);

        _close(account, CfdTypes.Side.SHORT, 5000e18, 120_000_000);
        assertGt(engine.traderClaimBalanceAssets(account), 0, "Setup must create a trader claim balance");

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertEq(
            viewData.marginAssets, positionMargin, "Public position view should still expose locked position margin"
        );
        assertEq(
            viewData.exists,
            true,
            "Trader claim balance should not hide the remaining open position from the public lens"
        );
    }

    function test_GetProtocolAccountingView_ReflectsTraderClaimLiabilities() public {
        address trader = address(0xAB12);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        uint256 settlementBufferAssets = SolvencyAccountingLib.settlementBufferTargetAssets(
            viewData.maxLiabilityAssets, engine.settlementBufferBps()
        );
        uint256 expectedWithdrawalReservedAssets =
            viewData.maxLiabilityAssets + viewData.totalTraderClaimBalanceAssets + settlementBufferAssets;
        uint256 expectedFreeAssets = viewData.poolAssets > expectedWithdrawalReservedAssets
            ? viewData.poolAssets - expectedWithdrawalReservedAssets
            : 0;
        assertEq(viewData.poolAssets, pool.totalAssets());
        assertEq(viewData.withdrawalReservedAssets, expectedWithdrawalReservedAssets);
        assertEq(viewData.freeAssets, expectedFreeAssets);
        assertEq(viewData.protocolTreasuryBalanceAssets, clearinghouse.balanceAssets(engine.protocolTreasury()));
        assertEq(viewData.totalTraderClaimBalanceAssets, engine.totalTraderClaimBalanceAssets());
        assertEq(viewData.degradedMode, engine.degradedMode());
        assertEq(viewData.hasLiveLiability, (_maxLiability() > 0));
    }

    function test_Close_ConsumesTraderClaimBeforeWritingOffTerminalPriceLoss() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address longAccount = address(uint160(0xD231));
        address shortAccount = address(uint160(0xD232));
        _fundTrader(longAccount, 5000e6);
        _fundTrader(shortAccount, 5000e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesAssets =
            _engineExecutionFeeAssets(5000e18, 120_000_000) + _engineExecutionFeeAssets(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - setupCloseFeesAssets - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceAssets(shortAccount);
        assertGt(traderClaimBefore, 0, "Setup must create trader claim while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceAssets(shortAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceAssets(address)").with_key(shortAccount)
            .checked_write(reducedSettlement);

        ICfdEngineTypes.ClosePreview memory preview =
            engineLens.simulateClose(shortAccount, 5000e18, 80_000_000, poolDepth);
        assertGt(
            preview.existingTraderClaimConsumedAssets,
            0,
            "Close preview should net the same-account trader claim before writing off terminal price loss"
        );
        assertLt(
            preview.existingTraderClaimRemainingAssets,
            traderClaimBefore,
            "Close preview should show less trader claim remaining after loss absorption"
        );

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(shortAccount);
        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 80_000_000, poolDepth, refreshTime);

        CloseParityObserved memory observed = _observeCloseParity(shortAccount, beforeSnapshot);

        assertEq(
            engine.traderClaimBalanceAssets(shortAccount),
            observed.traderClaimBalanceAssets,
            "Live close should leave the same trader claim remainder observed in settlement state"
        );
        assertEq(
            preview.existingTraderClaimConsumedAssets,
            traderClaimBefore - preview.existingTraderClaimRemainingAssets,
            "Preview should expose the exact trader claim consumed before socializing bad debt"
        );
    }

    function test_Close_ConsumesTraderClaimBalancesWithoutQueueOrdering() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address longAccount = address(uint160(0xD241));
        address shortAccount = address(uint160(0xD242));
        _fundTrader(longAccount, 5000e6);
        _fundTrader(shortAccount, 5000e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesAssets =
            (_engineExecutionFeeAssets(5000e18, 120_000_000) * 2) + _engineExecutionFeeAssets(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - setupCloseFeesAssets - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceAssets(shortAccount);
        assertGt(traderClaimBefore, 0, "Short account should accrue trader claim balance");

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 2500e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimAfterAccrual = engine.traderClaimBalanceAssets(shortAccount);
        assertGe(
            traderClaimAfterAccrual, traderClaimBefore, "Additional trader claim should coalesce into the same balance"
        );

        uint256 reducedSettlement = clearinghouse.balanceAssets(shortAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceAssets(address)").with_key(shortAccount)
            .checked_write(reducedSettlement);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 2500e18, 80_000_000, poolDepth, refreshTime);
        assertLe(
            engine.traderClaimBalanceAssets(shortAccount),
            traderClaimAfterAccrual,
            "Consuming trader claim balance should only reduce the tracked balance"
        );
    }

    function test_TraderClaim_CoalescesPerAccountWithoutQueuePosition() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address longAccount = address(uint160(0xD261));
        address shortAccount = address(uint160(0xD262));
        address laterAccount = address(uint160(0xD263));
        _fundTrader(longAccount, 5000e6);
        _fundTrader(shortAccount, 5000e6);
        _fundTrader(laterAccount, 5000e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);
        _open(laterAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesAssets =
            (_engineExecutionFeeAssets(5000e18, 120_000_000) * 2) + _engineExecutionFeeAssets(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - setupCloseFeesAssets - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 shortClaimBefore = engine.traderClaimBalanceAssets(shortAccount);
        assertGt(shortClaimBefore, 0, "Initial trader claim should create a tracked balance for shortAccount");

        _closeAt(laterAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 laterClaim = engine.traderClaimBalanceAssets(laterAccount);
        assertGt(laterClaim, 0, "Later claimant should also accrue a trader claim balance");

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 2500e18, 120_000_000, poolDepth, refreshTime);
        uint256 shortClaimAfter = engine.traderClaimBalanceAssets(shortAccount);

        assertGe(shortClaimAfter, shortClaimBefore, "Coalescing should not move the account behind later claimants");
    }

    function test_Close_WaivesExecutionFeeShortfallWithoutConsumingExistingTraderClaim() public {
        _closeWithExistingClaim(false);
    }

    function test_Close_ReleasedReservePaysExecutionFeeWithoutConsumingExistingTraderClaim() public {
        _closeWithExistingClaim(true);
    }

    function _closeWithExistingClaim(
        bool retainLiquidationReserve
    ) private {
        uint256 poolDepth = 1_000_000 * 1e6;
        address shortAccount = address(uint160(0xD252));
        {
            address longAccount = address(uint160(0xD251));
            _fundTrader(longAccount, 5000e6);
            _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        }
        _fundTrader(shortAccount, 5000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        {
            uint256 firstCloseExecutionFeeAssets = _engineExecutionFeeAssets(5000e18, 120_000_000);
            uint256 poolAssets = pool.totalAssets();
            vm.prank(address(pool));
            settlementToken.transfer(address(0xDEAD), poolAssets - firstCloseExecutionFeeAssets - 1);
        }

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceAssets(shortAccount);
        assertGt(
            traderClaimBefore, 1e6, "Setup must create an existing trader claim large enough to cover the fee shortfall"
        );

        _removePnlPledgeAndSyncTerminalCurve(shortAccount);
        if (!retainLiquidationReserve) {
            // Exhaust the physical reserve too; a claim alone must never pay action charges.
            uint256 reserve = clearinghouse.liquidationReserveAssets(shortAccount);
            vm.startPrank(address(engine));
            clearinghouse.releaseLiquidationReserve(shortAccount, reserve);
            clearinghouse.consumeActionCharge(shortAccount, reserve, 0, 0, address(pool), address(0), 0);
            vm.stopPrank();
        }
        uint256 expectedFee = retainLiquidationReserve ? _engineExecutionFeeAssets(5000e18, 1e8) : 0;

        ICfdEngineTypes.ClosePreview memory preview = engineLens.simulateClose(shortAccount, 5000e18, 1e8, poolDepth);

        assertTrue(preview.valid, "Terminal action fee shortfall should be waived rather than blocking close");
        assertEq(preview.realizedPnlAssets, 0, "Setup must isolate action fees from price PnL");
        assertEq(preview.executionFeeAssets, expectedFee, "Only released physical reserve may recover the fee");
        assertEq(
            preview.existingTraderClaimConsumedAssets, 0, "Action fees must not consume same-account trader claims"
        );
        assertEq(
            preview.existingTraderClaimRemainingAssets,
            traderClaimBefore,
            "Price-neutral close should preserve the entire existing trader claim"
        );

        uint256 feesBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _processUnderfundedFeeClose(shortAccount, poolDepth, refreshTime);

        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            feesBefore + expectedFee,
            "Treasury fees should come only from released reserve, never trader claims"
        );
        assertEq(
            engine.traderClaimBalanceAssets(shortAccount),
            traderClaimBefore,
            "Live action-fee waiver must leave the existing trader claim untouched"
        );
        assertEq(
            terminalNavBook.curveHashOf(shortAccount), bytes32(0), "Terminal close must delete the exact NAV curve"
        );
    }

    function test_GetTraderClaimStatus_ReflectsServiceability() public {
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        settlementToken.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        ClaimEngineViewTypes.TraderClaimStatus memory statusBefore = _traderClaimStatus(account, address(this));
        assertGt(statusBefore.traderClaimBalanceAssets, 0);
        assertFalse(statusBefore.traderClaimServiceableNow);

        settlementToken.mint(address(pool), statusBefore.traderClaimBalanceAssets);

        ClaimEngineViewTypes.TraderClaimStatus memory statusAfter = _traderClaimStatus(account, address(this));
        assertTrue(statusAfter.traderClaimServiceableNow);
    }

    function test_GetTraderClaimStatus_ExposesServiceabilityWithoutHeadOrdering() public {
        address trader = address(0xAB16);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceAssets(account);
        settlementToken.mint(address(pool), traderClaim);

        ClaimEngineViewTypes.TraderClaimStatus memory status = _traderClaimStatus(account, address(0xAB17));
        assertTrue(status.traderClaimServiceableNow, "Trader claim should be serviceable under partial liquidity");
    }

}
