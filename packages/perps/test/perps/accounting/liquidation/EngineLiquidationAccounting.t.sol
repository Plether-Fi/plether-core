// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {LiquidationAccountingLib} from "@plether/perps/libraries/LiquidationAccountingLib.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {
    CfdEnginePlanLibHarness,
    CfdEngineTestBase,
    LiquidationAccountingLibHarness
} from "../../shared/CfdEngineTestBase.sol";

contract EngineLiquidationAccountingTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_PlanLiquidation_PositiveResidualAboveTraderClaimDoesNotUnderflow() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(
            delta.keeperBountyAssets, 0, "Zero reachable settlement should cap the direct margin-funded bounty at zero"
        );
        assertEq(
            delta.residualAssets,
            18e6,
            "Exact price-risk equity should include the untouched claim and the positive price PnL"
        );
        assertEq(delta.settlementRetainedAssets, 0, "No settlement should remain when none is reachable");
        assertEq(
            delta.existingTraderClaimConsumedAssets,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingAssets,
            10e6,
            "Legacy trader claim should remain intact on positive residual"
        );
        assertEq(delta.freshTraderPayoutAssets, 8e6, "Only physical residual should become a fresh trader payout");
    }

    function test_PlanLiquidation_ConsumesExistingTraderClaimBeforeWritingOffTerminalPriceLoss() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 99_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyAssets, 0, "Zero physically reachable collateral should cap the bounty at zero");
        assertEq(delta.residualAssets, -2e6, "Exact residual should net the same-account claim against price loss");
        assertEq(
            delta.existingTraderClaimConsumedAssets,
            10e6,
            "Negative residual should consume legacy trader claim only as terminal shortfall netting"
        );
        assertEq(
            delta.existingTraderClaimRemainingAssets, 0, "No trader claim should survive a negative residual wipeout"
        );
        assertEq(delta.priceLossWrittenOffAssets, 2e6, "Uncollectible terminal price loss should be diagnostic");
    }

    function test_LiquidationState_UsesFullReachableCollateralForUnderwaterChargeCap() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state =
            harness.build(10_000e18, 100_000_000, 125e6, -145e6, 100, 1e6, 900, 5000, 0, 1e20);

        assertLt(state.equityAssets, 0, "Setup must make the account underwater");
        assertEq(state.reachableCollateralAssets, 125e6, "Liquidation state should use full reachable collateral");
        assertGt(
            state.keeperBountyAssets,
            5e6,
            "Keeper bounty should be allowed to exceed active position margin when more collateral is reachable"
        );
        assertLe(
            state.liquidationChargeAssets,
            state.reachableCollateralAssets,
            "Total liquidation charge should still cap at reachable collateral"
        );
        assertEq(
            state.keeperBountyAssets,
            state.liquidationChargeAssets / 2,
            "Keeper should receive only half of the capped charge"
        );
        assertEq(state.protocolLiquidationFeeAssets, 0, "Protocol liquidation fee should default to zero");
        assertEq(
            state.lpLiquidationFeeAssets,
            state.liquidationChargeAssets - state.keeperBountyAssets - state.protocolLiquidationFeeAssets,
            "LPs should receive the other half of the capped charge"
        );
    }

    function test_LiquidationState_ShareRoundingRemainderBelongsToLps() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state = harness.build(0, 0, 9, 0, 100, 9, 10, 3333, 2222, 1);

        assertEq(state.liquidationChargeAssets, 9, "Reachable minimum charge should be collected in full");
        assertEq(state.keeperBountyAssets, 2, "Configured keeper share should round down");
        assertEq(state.protocolLiquidationFeeAssets, 1, "Configured protocol share should round down");
        assertEq(state.lpLiquidationFeeAssets, 6, "LP share should receive both rounding remainders");
        assertEq(
            state.liquidationChargeAssets,
            state.keeperBountyAssets + state.protocolLiquidationFeeAssets + state.lpLiquidationFeeAssets,
            "All three allocations should conserve the total charge"
        );
    }

    function testFuzz_PlanLiquidation_PositiveResidualPreservesTraderClaimAndUsesOnlyPhysicalReachability(
        uint256 pnlPledgeAssets,
        uint256 traderClaimBalanceAssets
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        pnlPledgeAssets = bound(pnlPledgeAssets, 0, 5e6);
        traderClaimBalanceAssets = bound(traderClaimBalanceAssets, 1, 5e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(pnlPledgeAssets, traderClaimBalanceAssets, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Bounded exact equity should remain below maintenance");
        assertGe(delta.residualAssets, 0, "Positive-price fixture must have nonnegative exact residual");
        assertEq(
            delta.liquidationReachableCollateralAssets,
            pnlPledgeAssets + traderClaimBalanceAssets,
            "Exact liquidation price reachability must include PnL pledge plus the same-account claim"
        );
        assertEq(
            delta.liquidationState.reachableCollateralAssets,
            0,
            "Keeper bounty state must use only physical reachability"
        );
        assertEq(
            delta.existingTraderClaimConsumedAssets,
            0,
            "Positive physical residual must not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingAssets,
            traderClaimBalanceAssets,
            "Positive physical residual must preserve the full legacy trader claim"
        );
    }

    function testFuzz_PlanLiquidation_NegativeResidualNetsTraderClaimExactlyOnce(
        uint256 pnlPledgeAssets,
        uint256 traderClaimBalanceAssets
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        pnlPledgeAssets = bound(pnlPledgeAssets, 0, 5e6);
        traderClaimBalanceAssets = bound(traderClaimBalanceAssets, 1, 5e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(pnlPledgeAssets, traderClaimBalanceAssets, 2000e18, 99_600_000, 99_000_000);

        uint256 priceLossAssets = 12e6;
        uint256 expectedClaimConsumedAssets = traderClaimBalanceAssets;
        uint256 expectedPledgeConsumedAssets = pnlPledgeAssets;
        uint256 expectedWriteOffAssets = priceLossAssets - expectedClaimConsumedAssets - expectedPledgeConsumedAssets;

        assertTrue(delta.liquidatable, "Bounded negative exact equity should always be liquidatable");
        assertLt(delta.residualAssets, 0, "Negative-price fixture must have a negative exact residual");
        assertEq(
            delta.liquidationReachableCollateralAssets,
            pnlPledgeAssets + traderClaimBalanceAssets,
            "Exact liquidation price reachability must include PnL pledge plus the same-account claim"
        );
        assertEq(
            delta.existingTraderClaimConsumedAssets,
            expectedClaimConsumedAssets,
            "Negative exact price risk must net the same-account claim exactly once"
        );
        assertEq(
            delta.existingTraderClaimRemainingAssets,
            0,
            "The bounded price loss must consume the complete same-account claim"
        );
        assertEq(delta.pricePnlPledgeConsumedAssets, expectedPledgeConsumedAssets);
        assertEq(delta.priceLossWrittenOffAssets, expectedWriteOffAssets);
    }

    function test_PlanLiquidation_FundedNegativeVpiCancelsInHealthAndIsRecovered() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, -7e6);

        assertTrue(withClawback.liquidatable, "Setup must remain liquidatable");
        assertEq(withClawback.riskState.equityAssets, withoutClawback.riskState.equityAssets);
        assertEq(
            withClawback.liquidationState.equityAssets,
            withoutClawback.liquidationState.equityAssets,
            "Dedicated backing and its matching liability must cancel exactly once"
        );
        assertEq(withClawback.vpiRebateReserveBeforeAssets, 7e6);
        assertEq(withClawback.vpiRebateReserveConsumedAssets, 7e6);
        assertEq(withClawback.vpiRebateReserveAfterAssets, 0);
        assertEq(
            withClawback.keeperBountyAssets,
            withoutClawback.keeperBountyAssets,
            "Underwater keeper cap should still be bounded by reachable collateral"
        );
    }

    function testFuzz_PlanLiquidation_FundedNegativeVpiCancelsExactlyOnce(
        uint256 reachableAssets,
        uint256 rawLots,
        uint256 oraclePrice,
        uint256 clawbackAssets
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        reachableAssets = bound(reachableAssets, 1, 25_000_000e6);
        uint256 size = bound(rawLots, 1, 10_000) * CfdTypes.SIZE_QUANTUM;
        oraclePrice = bound(oraclePrice, 1, 2e8);
        clawbackAssets = bound(clawbackAssets, 1, 50_000_000e6);

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(reachableAssets, 0, size, 1e8, oraclePrice, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(reachableAssets, 0, size, 1e8, oraclePrice, -int256(clawbackAssets));

        assertEq(
            withClawback.riskState.equityAssets,
            withoutClawback.riskState.equityAssets,
            "Dedicated reserve must cancel the funded VPI liability in risk"
        );
        assertEq(withClawback.liquidatable, withoutClawback.liquidatable);
        if (!withClawback.liquidatable) {
            return;
        }

        assertEq(
            withClawback.liquidationState.equityAssets,
            withoutClawback.liquidationState.equityAssets,
            "Liquidation equity must preserve the same cancellation"
        );
        uint256 expectedWithheldAssets =
            withClawback.priceGainAssets < clawbackAssets ? withClawback.priceGainAssets : clawbackAssets;
        assertEq(withClawback.vpiRebateReserveConsumedAssets, clawbackAssets - expectedWithheldAssets);
        assertEq(withClawback.vpiRebateReserveAfterAssets, 0);
    }

    function test_PlanLiquidation_FundedNegativeVpiDoesNotFlipLiquidatable() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, -7e6);

        assertEq(withClawback.liquidatable, withoutClawback.liquidatable);
        assertEq(
            withClawback.riskState.equityAssets,
            withoutClawback.riskState.equityAssets,
            "A fully funded VPI liability cannot independently change liquidation health"
        );
    }

    function test_PlanLiquidation_CarryDelinquencyIsStrictlyIsolatedFromPriceCollateral() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory fullyFunded =
            harness.planLiquidationWithUnsettledCarry(200e6, 50e6, 1000e6, 50e6, 10_000e18, 1e8, 1e8);
        CfdEnginePlanTypes.LiquidationDelta memory oneAtomUncovered =
            harness.planLiquidationWithUnsettledCarry(200e6, 50e6, 1000e6, 250e6 + 1, 10_000e18, 1e8, 1e8);

        assertFalse(fullyFunded.liquidatable, "Carry fully collectible from free settlement must not liquidate");
        assertEq(fullyFunded.pendingCarryAssets, 50e6, "Fixture must checkpoint the funded carry exactly");
        assertTrue(oneAtomUncovered.liquidatable, "One uncovered carry atom must be independently delinquent");
        assertEq(oneAtomUncovered.pendingCarryAssets, 250e6 + 1, "Fixture must preserve the one-atom boundary");
        assertEq(
            oneAtomUncovered.realizedCarryAssets, 250e6, "Liquidation first collects all margin and free settlement"
        );
        assertEq(oneAtomUncovered.actionChargeWaivedAssets, 1, "Exactly the uncovered carry atom must be waived");
        assertEq(
            oneAtomUncovered.existingTraderClaimRemainingAssets,
            1000e6,
            "A large same-account claim must not pay or conceal action carry"
        );
    }

    function test_Liquidation_ConsumesTraderClaimBeforeWritingOffTerminalPriceLoss() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address longAccount = address(uint160(0xD221));
        address shortAccount = address(uint160(0xD222));
        address keeper = address(0xD223);
        _fundTrader(longAccount, 5000e6);
        _fundTrader(shortAccount, 5000e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 firstCloseExecutionFeeAssets = _engineExecutionFeeAssets(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - firstCloseExecutionFeeAssets - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceAssets(shortAccount);
        assertGt(traderClaimBefore, 0, "Setup must create trader claim while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceAssets(shortAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceAssets(address)").with_key(shortAccount)
            .checked_write(reducedSettlement);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(shortAccount, 50_000_000);
        assertTrue(preview.liquidatable, "Setup must produce a liquidatable position even after trader claim credit");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(50_000_000));
        _ensureLaterOracleTime();
        vm.prank(keeper);
        router.executeLiquidation(shortAccount, priceData);

        assertLt(
            engine.traderClaimBalanceAssets(shortAccount),
            traderClaimBefore,
            "Liquidation should consume the same-account claim before writing off terminal price loss"
        );
        assertEq(
            engine.traderClaimBalanceAssets(shortAccount),
            preview.traderClaimBalanceAssets,
            "Preview should match remaining trader claim after liquidation"
        );
        assertEq(
            clearinghouse.balanceAssets(shortAccount),
            preview.settlementRetainedAssets,
            "Live settlement must match the preview total including any immediate payout"
        );
        assertEq(
            terminalNavBook.curveHashOf(shortAccount),
            bytes32(0),
            "Terminal liquidation must remove the authenticated account curve"
        );
    }

    function test_SetRiskParams_MakesPositionLiquidatable() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        address trader = account;
        _fundTrader(trader, 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(account, 2500 * 1e6);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, poolDepth, uint64(block.timestamp), address(this));

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 300,
                initMarginBps: ((300) * 15) / 10,
                fadMarginBps: 500,
                baseCarryBps: 500,
                minBountyAssets: 1 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(account, 1e8, poolDepth, uint64(block.timestamp), address(this));
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be wiped");
    }

    function test_LiquidationDoesNotSeizeGenericFreeEquityForPriceLoss() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        address trader = account;
        _fundTrader(trader, 50_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(account, 46_000 * 1e6);

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerAssets(account);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 poolBalanceBefore = settlementToken.balanceOf(address(pool));

        // Price rises to $1.10 — LONG loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(account, 1.1e8, poolDepth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerAssets(account);
        assertEq(
            freeEquityAfter,
            freeEquityBefore,
            "Terminal price loss must never consume generic free settlement outside the isolated PnL pledge"
        );

        uint256 poolBalanceAfter = settlementToken.balanceOf(address(pool));
        uint256 totalRecovered = poolBalanceAfter - poolBalanceBefore;
        assertTrue(totalRecovered > 0, "Pool should recover the isolated price pledge and LP charge allocation");
    }

    function test_LiquidationWorksWhenPoolInsolvent() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address aliceAccount = address(uint160(1));
        address bobAccount = address(uint160(2));
        address aliceTrader = aliceAccount;
        _fundTrader(aliceTrader, 50_000 * 1e6);
        _fundTrader(bobAccount, 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceOpen, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(aliceTrader);
        clearinghouse.withdraw(aliceAccount, 28_000 * 1e6);

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            account: bobAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bobOpen, 1e8, poolDepth, uint64(block.timestamp));

        // Drain pool to simulate insolvency (pool has ~$1M + fees, maxLiab = $200k)
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 810_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.LONG) > _sideMaxProfit(CfdTypes.Side.SHORT)
            ? _sideMaxProfit(CfdTypes.Side.LONG)
            : _sideMaxProfit(CfdTypes.Side.SHORT);
        assertTrue(settlementToken.balanceOf(address(pool)) < maxLiab, "Pool should be insolvent");

        // Price rises to $1.10 — LONG loses $20k, deeply underwater
        vm.prank(address(router));
        engine.liquidatePosition(aliceAccount, 1.1e8, poolDepth, uint64(block.timestamp), address(this));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(aliceSize, 0, "Liquidation must succeed during insolvency");
    }

    function test_Liquidate_EmptyPosition_Reverts() public {
        address account = address(uint160(1));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoPositionToLiquidate.selector);
        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, 1_000_000 * 1e6, uint64(block.timestamp), address(this));
    }

    function test_LiquidationCharge_UsesReachableCollateralSubsidyCap() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1234));
        address trader = account;
        _fundTrader(trader, 200 * 1e6);

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 10,
                initMarginBps: ((10) * 15) / 10,
                fadMarginBps: 10,
                baseCarryBps: 500,
                minBountyAssets: 1 * 1e6,
                bountyBps: 100,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 1000 * 1e18,
            marginDelta: 20 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveAssets(account);
        uint256 withdrawableAssets = engineAccountLens.getWithdrawableAssets(account);

        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableAssets);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(
            preview.liquidationChargeAssets,
            liquidationReserveBefore,
            "Total liquidation charge should be bounded by the dedicated entry-time reserve"
        );
        assertEq(bounty, preview.keeperBountyAssets, "Live keeper credit should match the previewed half");
        assertEq(
            preview.keeperBountyAssets + preview.protocolLiquidationFeeAssets + preview.lpLiquidationFeeAssets,
            liquidationReserveBefore,
            "Keeper, protocol, and LP shares should conserve the capped charge"
        );
    }

}
