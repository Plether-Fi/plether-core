// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract PreviewExecutionDifferentialTest is BasePerpTest {

    address internal constant KEEPER = address(0xC0FFEE);

    function testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution(
        uint256 initialMarginFuzz,
        uint256 marginDeltaFuzz,
        uint256 sizeDeltaFuzz,
        uint256 oraclePriceFuzz,
        uint256 carryDelayFuzz
    ) public {
        address trader = address(0xC108);
        address account = trader;
        uint256 initialMargin = bound(initialMarginFuzz, 5000e6, 25_000e6);
        uint256 sizeDelta = bound(sizeDeltaFuzz, 1000e18, 50_000e18);
        uint256 oraclePrice = bound(oraclePriceFuzz, 80_000_000, 120_000_000);
        uint256 carryDelay = bound(carryDelayFuzz, 0, 30 days);

        _fundTrader(trader, 60_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, initialMargin, 1e8);

        if (carryDelay > 0) {
            vm.warp(block.timestamp + carryDelay);
        }

        uint256 marginDelta = bound(marginDeltaFuzz, 0, _freeSettlementUsdc(account));
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: oraclePrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, oraclePrice, uint64(block.timestamp)
        );

        vm.assume(revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.OK));
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.None),
            "Valid preview open should not carry a failure category"
        );

        vm.startPrank(address(router));
        try engine.processOrderTyped(order, oraclePrice, pool.totalAssets(), uint64(block.timestamp)) {
            vm.stopPrank();
        } catch (bytes memory revertData) {
            vm.stopPrank();
            assertEq(
                _revertSelector(revertData),
                ICfdEngine.CfdEngine__TypedOrderFailure.selector,
                "Valid preview open unexpectedly hit an untyped revert"
            );
            fail("Valid preview open unexpectedly reverted on the live open path");
        }
    }

    function testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault(
        uint256 closePriceFuzz
    ) public {
        address trader = address(0xC100);
        address account = trader;
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);

        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        vm.assume(preview.valid);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Close preview remaining size should match live execution");
        assertEq(marginAfter, preview.remainingMargin, "Close preview remaining margin should match live execution");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc,
            "Close preview should match the live settlement-balance mutation"
        );
        assertEq(
            bucketsAfter.activePositionMarginUsdc,
            preview.remainingMargin,
            "Close preview remaining margin should match the live position-margin bucket"
        );
        assertEq(
            bucketsAfter.totalLockedMarginUsdc,
            preview.remainingMargin,
            "Full close should leave no locked margin beyond the surviving position margin"
        );
        assertEq(
            clearinghouse.balanceUsdc(account) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Close preview immediate payout should match live settlement delta"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Close preview trader claim balance should match live trader claim balance delta"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Close preview bad debt should match live bad debt delta"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Close preview degraded-mode flag should match live outcome"
        );
    }

    function testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault(
        uint256 closePriceFuzz
    ) public {
        address trader = address(0xC101);
        address account = trader;
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);

        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        vm.assume(preview.valid);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Illiquid close preview remaining size should match live execution");
        assertEq(
            marginAfter, preview.remainingMargin, "Illiquid close preview remaining margin should match live execution"
        );
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc + preview.immediatePayoutUsdc - preview.seizedCollateralUsdc,
            "Illiquid close preview should match the live settlement-balance mutation"
        );
        assertEq(
            bucketsAfter.activePositionMarginUsdc,
            preview.remainingMargin,
            "Illiquid close preview remaining margin should match the live position-margin bucket"
        );
        assertEq(
            bucketsAfter.totalLockedMarginUsdc,
            preview.remainingMargin,
            "Illiquid full close should leave no locked margin beyond the surviving position margin"
        );
        assertEq(
            clearinghouse.balanceUsdc(account) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Illiquid close preview immediate payout should match live settlement delta"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Illiquid close preview trader claim balance should match live trader claim balance delta"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Illiquid close preview bad debt should match live bad debt delta"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Illiquid close preview degraded-mode flag should match live outcome"
        );
    }

    function test_PreviewClose_PartialCloseMatchesLiveExecution_AfterPositiveCarryAccrual() public {
        address bullTrader = address(0xC103);
        address bearTrader = address(0xC104);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundJunior(address(0xC105), 1_000_000e6);
        _fundTrader(bullTrader, 80_000e6);
        _fundTrader(bearTrader, 80_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 30_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bearAccount, 50_000e18, 1e8);
        assertTrue(preview.valid, "Positive-funding partial close preview should remain valid");

        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(bearAccount);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(bearAccount, CfdTypes.Side.BEAR, 50_000e18, 1e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(bearAccount);
        assertEq(sizeAfter, preview.remainingSize, "Partial close preview remaining size should match live execution");
        assertEq(
            marginAfter, preview.remainingMargin, "Partial close preview remaining margin should match live execution"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(bearAccount) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Partial close preview trader claim balance should match live trader claim balance delta"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Partial close preview bad debt should match live bad debt delta"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Partial close preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.postOpDegradedMode,
            engine.degradedMode(),
            "Partial close preview post-op degraded flag should match live outcome"
        );
    }

    function test_PreviewClose_PartialCloseIgnoresQueuedCommittedMarginInLiveExecution() public {
        address trader = address(0xC106);
        address account = trader;

        _fundJunior(address(0xC107), 1_000_000e6);
        _fundTrader(trader, 8000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 110_000_000);
        assertTrue(preview.valid, "Partial close preview should remain valid without queued margin support");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 900e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(2);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.1e8));

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Queued-margin partial close size should match preview");
        assertEq(marginAfter, preview.remainingMargin, "Queued-margin partial close margin should match preview");
        assertEq(
            _remainingCommittedMargin(2), committedBefore, "Queued open-order committed margin must remain untouched"
        );
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        address trader = address(0xC102);
        address account = trader;
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);

        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 keeperClaimBalanceBefore = clearinghouse.keeperClaimBalanceUsdc(KEEPER);
        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Liquidation should fully clear the position");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc - preview.seizedCollateralUsdc + preview.immediatePayoutUsdc,
            "Liquidation preview should match the live settlement-balance mutation"
        );
        assertEq(bucketsAfter.activePositionMarginUsdc, 0, "Liquidation should clear the live position-margin bucket");
        assertEq(bucketsAfter.totalLockedMarginUsdc, 0, "Liquidation should clear all locked margin in the simple path");
        assertEq(
            (clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore)
                + (clearinghouse.keeperClaimBalanceUsdc(KEEPER) - keeperClaimBalanceBefore),
            preview.keeperBountyUsdc,
            "Liquidation preview keeper bounty should match live execution or keeper claim"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Liquidation preview trader claim balance should match live trader claim balance delta"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Liquidation preview bad debt should match live bad debt delta"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.freshTraderPayoutUsdc,
            preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy claim balance exists"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Fresh liquidation path should not consume legacy trader claim balance"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc,
            0,
            "Fresh liquidation path should not leave legacy trader claim balance"
        );
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        address trader = address(0xC103);
        address account = trader;
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);

        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 keeperClaimBalanceBefore = clearinghouse.keeperClaimBalanceUsdc(KEEPER);
        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        IMarginClearinghouse.AccountUsdcBuckets memory bucketsBefore = clearinghouse.getAccountUsdcBuckets(account);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        IMarginClearinghouse.AccountUsdcBuckets memory bucketsAfter = clearinghouse.getAccountUsdcBuckets(account);
        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Illiquid liquidation should fully clear the position");
        assertEq(
            bucketsAfter.settlementBalanceUsdc,
            bucketsBefore.settlementBalanceUsdc - preview.seizedCollateralUsdc + preview.immediatePayoutUsdc,
            "Illiquid liquidation preview should match the live settlement-balance mutation"
        );
        assertEq(bucketsAfter.activePositionMarginUsdc, 0, "Illiquid liquidation should clear the live position margin");
        assertEq(
            bucketsAfter.totalLockedMarginUsdc,
            0,
            "Illiquid liquidation should clear all locked margin in the simple path"
        );
        assertEq(
            (clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore)
                + (clearinghouse.keeperClaimBalanceUsdc(KEEPER) - keeperClaimBalanceBefore),
            preview.keeperBountyUsdc,
            "Illiquid liquidation preview keeper bounty should match live execution or keeper claim"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Illiquid liquidation preview trader claim balance should match live trader claim balance delta"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Illiquid liquidation preview bad debt should match live bad debt delta"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Illiquid liquidation preview degraded-mode flag should match live outcome"
        );
        assertEq(
            preview.freshTraderPayoutUsdc,
            preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy claim balance exists"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Fresh illiquid liquidation path should not consume legacy trader claim balance"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc,
            0,
            "Fresh illiquid liquidation path should not leave legacy trader claim balance"
        );
    }

    function test_PreviewLiquidation_MatchesLiveExecution_WithQueuedExecutionEscrowOutsideReachability() public {
        address trader = address(0xC104);
        address account = trader;
        uint256 liquidationPrice = 102_500_000;

        _fundTrader(trader, 260e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0, true);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 keeperClaimBalanceBefore = clearinghouse.keeperClaimBalanceUsdc(KEEPER);
        uint256 claimBefore = clearinghouse.traderClaimBalanceUsdc(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        assertEq(
            preview.reachableCollateralUsdc,
            snapshotBefore.terminalReachableUsdc,
            "Liquidation preview must exclude router execution escrow from reachable collateral"
        );
        assertEq(
            (clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore)
                + (clearinghouse.keeperClaimBalanceUsdc(KEEPER) - keeperClaimBalanceBefore),
            preview.keeperBountyUsdc,
            "Queued-escrow liquidation preview keeper bounty should match live outcome"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account) - claimBefore,
            preview.traderClaimBalanceUsdc,
            "Queued-escrow liquidation preview trader claim balance should match live outcome"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Queued-escrow liquidation preview bad debt should match live outcome"
        );
        assertEq(
            usdc.balanceOf(address(router)),
            0,
            "Queued execution escrow should be removed from the router on liquidation"
        );
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Queued-escrow liquidation preview degraded-mode flag should match live outcome"
        );
    }

}
