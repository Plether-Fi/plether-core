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
            delta.keeperBountyUsdc, 0, "Zero reachable settlement should cap the direct margin-funded bounty at zero"
        );
        assertEq(
            delta.residualUsdc,
            18e6,
            "Exact price-risk equity should include the untouched claim and the positive price PnL"
        );
        assertEq(delta.settlementRetainedUsdc, 0, "No settlement should remain when none is reachable");
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            10e6,
            "Legacy trader claim should remain intact on positive residual"
        );
        assertEq(delta.freshTraderPayoutUsdc, 8e6, "Only physical residual should become a fresh trader payout");
        assertEq(
            delta.residualPlan.freshTraderPayoutUsdc, 8e6, "Residual plan should expose only the physical fresh payout"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual should not create bad debt");
    }

    function test_PlanLiquidation_ConsumesExistingTraderClaimBeforeWritingOffTerminalPriceLoss() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 99_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyUsdc, 0, "Zero physically reachable collateral should cap the bounty at zero");
        assertEq(delta.residualUsdc, -2e6, "Exact residual should net the same-account claim against price loss");
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            10e6,
            "Negative residual should consume legacy trader claim only as terminal shortfall netting"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc, 0, "No trader claim should survive a negative residual wipeout"
        );
        assertEq(delta.priceLossWrittenOffUsdc, 2e6, "Uncollectible terminal price loss should be diagnostic");
        assertEq(delta.badDebtUsdc, 0, "V2 must not recreate a protocol bad-debt ledger");
    }

    function test_LiquidationState_UsesFullReachableCollateralForUnderwaterChargeCap() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state =
            harness.build(10_000e18, 100_000_000, 125e6, -145e6, 100, 1e6, 900, 5000, 0, 1e20);

        assertLt(state.equityUsdc, 0, "Setup must make the account underwater");
        assertEq(state.reachableCollateralUsdc, 125e6, "Liquidation state should use full reachable collateral");
        assertGt(
            state.keeperBountyUsdc,
            5e6,
            "Keeper bounty should be allowed to exceed active position margin when more collateral is reachable"
        );
        assertLe(
            state.liquidationChargeUsdc,
            state.reachableCollateralUsdc,
            "Total liquidation charge should still cap at reachable collateral"
        );
        assertEq(
            state.keeperBountyUsdc,
            state.liquidationChargeUsdc / 2,
            "Keeper should receive only half of the capped charge"
        );
        assertEq(state.protocolLiquidationFeeUsdc, 0, "Protocol liquidation fee should default to zero");
        assertEq(
            state.lpLiquidationFeeUsdc,
            state.liquidationChargeUsdc - state.keeperBountyUsdc - state.protocolLiquidationFeeUsdc,
            "LPs should receive the other half of the capped charge"
        );
    }

    function test_LiquidationState_ShareRoundingRemainderBelongsToLps() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state = harness.build(0, 0, 9, 0, 100, 9, 10, 3333, 2222, 1);

        assertEq(state.liquidationChargeUsdc, 9, "Reachable minimum charge should be collected in full");
        assertEq(state.keeperBountyUsdc, 2, "Configured keeper share should round down");
        assertEq(state.protocolLiquidationFeeUsdc, 1, "Configured protocol share should round down");
        assertEq(state.lpLiquidationFeeUsdc, 6, "LP share should receive both rounding remainders");
        assertEq(
            state.liquidationChargeUsdc,
            state.keeperBountyUsdc + state.protocolLiquidationFeeUsdc + state.lpLiquidationFeeUsdc,
            "All three allocations should conserve the total charge"
        );
    }

    function testFuzz_PlanLiquidation_PositiveResidualPreservesTraderClaimAndUsesOnlyPhysicalReachability(
        uint256 pnlPledgeUsdc,
        uint256 traderClaimBalanceUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        pnlPledgeUsdc = bound(pnlPledgeUsdc, 0, 5e6);
        traderClaimBalanceUsdc = bound(traderClaimBalanceUsdc, 1, 5e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(pnlPledgeUsdc, traderClaimBalanceUsdc, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Bounded exact equity should remain below maintenance");
        assertGe(delta.residualUsdc, 0, "Positive-price fixture must have nonnegative exact residual");
        assertEq(
            delta.liquidationReachableCollateralUsdc,
            pnlPledgeUsdc + traderClaimBalanceUsdc,
            "Exact liquidation price reachability must include PnL pledge plus the same-account claim"
        );
        assertEq(
            delta.liquidationState.reachableCollateralUsdc, 0, "Keeper bounty state must use only physical reachability"
        );
        assertEq(
            delta.existingTraderClaimConsumedUsdc, 0, "Positive physical residual must not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            traderClaimBalanceUsdc,
            "Positive physical residual must preserve the full legacy trader claim"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual must not create bad debt");
    }

    function testFuzz_PlanLiquidation_NegativeResidualNetsTraderClaimExactlyOnce(
        uint256 pnlPledgeUsdc,
        uint256 traderClaimBalanceUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        pnlPledgeUsdc = bound(pnlPledgeUsdc, 0, 5e6);
        traderClaimBalanceUsdc = bound(traderClaimBalanceUsdc, 1, 5e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(pnlPledgeUsdc, traderClaimBalanceUsdc, 2000e18, 99_600_000, 99_000_000);

        uint256 priceLossUsdc = 12e6;
        uint256 expectedClaimConsumedUsdc = traderClaimBalanceUsdc;
        uint256 expectedPledgeConsumedUsdc = pnlPledgeUsdc;
        uint256 expectedWriteOffUsdc = priceLossUsdc - expectedClaimConsumedUsdc - expectedPledgeConsumedUsdc;

        assertTrue(delta.liquidatable, "Bounded negative exact equity should always be liquidatable");
        assertLt(delta.residualUsdc, 0, "Negative-price fixture must have a negative exact residual");
        assertEq(
            delta.liquidationReachableCollateralUsdc,
            pnlPledgeUsdc + traderClaimBalanceUsdc,
            "Exact liquidation price reachability must include PnL pledge plus the same-account claim"
        );
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            expectedClaimConsumedUsdc,
            "Negative exact price risk must net the same-account claim exactly once"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            0,
            "The bounded price loss must consume the complete same-account claim"
        );
        assertEq(delta.pricePnlPledgeConsumedUsdc, expectedPledgeConsumedUsdc);
        assertEq(delta.priceLossWrittenOffUsdc, expectedWriteOffUsdc);
        assertEq(delta.badDebtUsdc, 0, "A terminal price write-off must never create protocol debt");
    }

    function test_PlanLiquidation_FundedNegativeVpiCancelsInHealthAndIsRecovered() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, -7e6);

        assertTrue(withClawback.liquidatable, "Setup must remain liquidatable");
        assertEq(withClawback.riskState.equityUsdc, withoutClawback.riskState.equityUsdc);
        assertEq(
            withClawback.liquidationState.equityUsdc,
            withoutClawback.liquidationState.equityUsdc,
            "Dedicated backing and its matching liability must cancel exactly once"
        );
        assertEq(withClawback.vpiRebateReserveBeforeUsdc, 7e6);
        assertEq(withClawback.vpiRebateReserveConsumedUsdc, 7e6);
        assertEq(withClawback.vpiRebateReserveAfterUsdc, 0);
        assertEq(withClawback.badDebtUsdc, 0, "V2 liquidation waives uncollectible charges instead of creating debt");
        assertEq(
            withClawback.keeperBountyUsdc,
            withoutClawback.keeperBountyUsdc,
            "Underwater keeper cap should still be bounded by reachable collateral"
        );
    }

    function testFuzz_PlanLiquidation_FundedNegativeVpiCancelsExactlyOnce(
        uint256 reachableUsdc,
        uint256 rawLots,
        uint256 oraclePrice,
        uint256 clawbackUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        reachableUsdc = bound(reachableUsdc, 1, 25_000_000e6);
        uint256 size = bound(rawLots, 1, 10_000) * CfdTypes.SIZE_QUANTUM;
        oraclePrice = bound(oraclePrice, 1, 2e8);
        clawbackUsdc = bound(clawbackUsdc, 1, 50_000_000e6);

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(reachableUsdc, 0, size, 1e8, oraclePrice, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(reachableUsdc, 0, size, 1e8, oraclePrice, -int256(clawbackUsdc));

        assertEq(
            withClawback.riskState.equityUsdc,
            withoutClawback.riskState.equityUsdc,
            "Dedicated reserve must cancel the funded VPI liability in risk"
        );
        assertEq(withClawback.liquidatable, withoutClawback.liquidatable);
        if (!withClawback.liquidatable) {
            return;
        }

        assertEq(
            withClawback.liquidationState.equityUsdc,
            withoutClawback.liquidationState.equityUsdc,
            "Liquidation equity must preserve the same cancellation"
        );
        uint256 expectedWithheldUsdc =
            withClawback.priceGainUsdc < clawbackUsdc ? withClawback.priceGainUsdc : clawbackUsdc;
        assertEq(withClawback.vpiRebateReserveConsumedUsdc, clawbackUsdc - expectedWithheldUsdc);
        assertEq(withClawback.vpiRebateReserveAfterUsdc, 0);
        assertEq(withClawback.badDebtUsdc, 0);
    }

    function test_PlanLiquidation_FundedNegativeVpiDoesNotFlipLiquidatable() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, -7e6);

        assertEq(withClawback.liquidatable, withoutClawback.liquidatable);
        assertEq(
            withClawback.riskState.equityUsdc,
            withoutClawback.riskState.equityUsdc,
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
        assertEq(fullyFunded.pendingCarryUsdc, 50e6, "Fixture must checkpoint the funded carry exactly");
        assertTrue(oneAtomUncovered.liquidatable, "One uncovered carry atom must be independently delinquent");
        assertEq(oneAtomUncovered.pendingCarryUsdc, 250e6 + 1, "Fixture must preserve the one-atom boundary");
        assertEq(oneAtomUncovered.realizedCarryUsdc, 250e6, "Liquidation first collects all margin and free settlement");
        assertEq(oneAtomUncovered.actionChargeWaivedUsdc, 1, "Exactly the uncovered carry atom must be waived");
        assertEq(
            oneAtomUncovered.existingTraderClaimRemainingUsdc,
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

        uint256 firstCloseExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - firstCloseExecutionFeeUsdc - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(shortAccount);
        assertGt(traderClaimBefore, 0, "Setup must create trader claim while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(shortAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(shortAccount)
            .checked_write(reducedSettlement);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(shortAccount, 50_000_000);
        assertTrue(preview.liquidatable, "Setup must produce a liquidatable position even after trader claim credit");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(50_000_000));
        vm.prank(keeper);
        router.executeLiquidation(shortAccount, priceData);

        assertLt(
            engine.traderClaimBalanceUsdc(shortAccount),
            traderClaimBefore,
            "Liquidation should consume the same-account claim before writing off terminal price loss"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(shortAccount),
            preview.traderClaimBalanceUsdc,
            "Preview should match remaining trader claim after liquidation"
        );
        assertEq(preview.badDebtUsdc, 0, "V2 liquidation must not recreate protocol bad debt");
        assertEq(
            clearinghouse.balanceUsdc(shortAccount),
            preview.settlementRetainedUsdc + preview.immediatePayoutUsdc,
            "Live retained settlement and immediate payout must match the exact liquidation preview"
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
                minBountyUsdc: 1 * 1e6,
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

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(account);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — LONG loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(account, 1.1e8, poolDepth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(account);
        assertEq(
            freeEquityAfter,
            freeEquityBefore,
            "Terminal price loss must never consume generic free settlement outside the isolated PnL pledge"
        );

        uint256 poolBalanceAfter = usdc.balanceOf(address(pool));
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
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Pool should be insolvent");

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
                minBountyUsdc: 1 * 1e6,
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

        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);
        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);

        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableUsdc);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(
            preview.liquidationChargeUsdc,
            liquidationReserveBefore,
            "Total liquidation charge should be bounded by the dedicated entry-time reserve"
        );
        assertEq(bounty, preview.keeperBountyUsdc, "Live keeper credit should match the previewed half");
        assertEq(
            preview.keeperBountyUsdc + preview.protocolLiquidationFeeUsdc + preview.lpLiquidationFeeUsdc,
            liquidationReserveBefore,
            "Keeper, protocol, and LP shares should conserve the capped charge"
        );
    }

}
