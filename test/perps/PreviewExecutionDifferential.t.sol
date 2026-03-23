// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract PreviewExecutionDifferentialTest is BasePerpTest {

    address internal constant KEEPER = address(0xC0FFEE);

    function testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault(
        uint256 closePriceFuzz
    ) public {
        address trader = address(0xC100);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);

        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 100_000e18, closePrice);
        vm.assume(preview.valid);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint256 deferredBefore = engine.deferredPayoutUsdc(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, preview.remainingSize, "Close preview remaining size should match live execution");
        assertEq(marginAfter, preview.remainingMargin, "Close preview remaining margin should match live execution");
        assertEq(
            clearinghouse.balanceUsdc(accountId) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Close preview immediate payout should match live settlement delta"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Close preview deferred payout should match live deferred payout delta"
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 closePrice = bound(closePriceFuzz, 60_000_000, 95_000_000);

        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 100_000e18, closePrice);
        vm.assume(preview.valid);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint256 deferredBefore = engine.deferredPayoutUsdc(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(closePrice);

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, preview.remainingSize, "Illiquid close preview remaining size should match live execution");
        assertEq(
            marginAfter, preview.remainingMargin, "Illiquid close preview remaining margin should match live execution"
        );
        assertEq(
            clearinghouse.balanceUsdc(accountId) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Illiquid close preview immediate payout should match live settlement delta"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Illiquid close preview deferred payout should match live deferred payout delta"
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

    function test_PreviewClose_PartialCloseMatchesLiveExecution_AfterPositiveFundingAccrual() public {
        address bullTrader = address(0xC103);
        address bearTrader = address(0xC104);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundJunior(address(0xC105), 1_000_000e6);
        _fundTrader(bullTrader, 80_000e6);
        _fundTrader(bearTrader, 80_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 30_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);

        CfdEngine.ClosePreview memory preview = engine.previewClose(bearId, 50_000e18, 1e8);
        assertTrue(preview.valid, "Positive-funding partial close preview should remain valid");

        uint256 deferredBefore = engine.deferredPayoutUsdc(bearId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(bearId, CfdTypes.Side.BEAR, 50_000e18, 1e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(bearId);
        assertEq(sizeAfter, preview.remainingSize, "Partial close preview remaining size should match live execution");
        assertEq(
            marginAfter, preview.remainingMargin, "Partial close preview remaining margin should match live execution"
        );
        assertEq(
            engine.deferredPayoutUsdc(bearId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Partial close preview deferred payout should match live deferred payout delta"
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundJunior(address(0xC107), 1_000_000e6);
        _fundTrader(trader, 8000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 50_000e18, 110_000_000);
        assertTrue(preview.valid, "Partial close preview should remain valid without queued margin support");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 900e6, type(uint256).max, false);

        uint256 committedBefore = router.committedMargins(2);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.1e8));

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, preview.remainingSize, "Queued-margin partial close size should match preview");
        assertEq(marginAfter, preview.remainingMargin, "Queued-margin partial close margin should match preview");
        assertEq(
            router.committedMargins(2), committedBefore, "Queued open-order committed margin must remain untouched"
        );
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        address trader = address(0xC102);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);

        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 traderWalletBefore = usdc.balanceOf(trader);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        uint256 deferredClearerBefore = engine.deferredClearerBountyUsdc(KEEPER);
        uint256 deferredBefore = engine.deferredPayoutUsdc(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Liquidation should fully clear the position");
        assertEq(
            (usdc.balanceOf(KEEPER) - keeperWalletBefore)
                + (engine.deferredClearerBountyUsdc(KEEPER) - deferredClearerBefore),
            preview.keeperBountyUsdc,
            "Liquidation preview keeper bounty should match live execution or deferred bounty"
        );
        assertEq(
            usdc.balanceOf(trader) - traderWalletBefore,
            preview.immediatePayoutUsdc,
            "Liquidation preview immediate payout should match live wallet delta"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Liquidation preview deferred payout should match live deferred payout delta"
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
            preview.immediatePayoutUsdc + preview.deferredPayoutUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy deferred claim exists"
        );
        assertEq(
            preview.existingDeferredConsumedUsdc, 0, "Fresh liquidation path should not consume legacy deferred payout"
        );
        assertEq(
            preview.existingDeferredRemainingUsdc, 0, "Fresh liquidation path should not leave legacy deferred payout"
        );
    }

    function testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault(
        uint256 liquidationPriceFuzz
    ) public {
        address trader = address(0xC103);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 101_000_000, 120_000_000);

        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, liquidationPrice);
        vm.assume(preview.liquidatable);

        uint256 traderWalletBefore = usdc.balanceOf(trader);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        uint256 deferredClearerBefore = engine.deferredClearerBountyUsdc(KEEPER);
        uint256 deferredBefore = engine.deferredPayoutUsdc(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Illiquid liquidation should fully clear the position");
        assertEq(
            (usdc.balanceOf(KEEPER) - keeperWalletBefore)
                + (engine.deferredClearerBountyUsdc(KEEPER) - deferredClearerBefore),
            preview.keeperBountyUsdc,
            "Illiquid liquidation preview keeper bounty should match live execution or deferred bounty"
        );
        assertEq(
            usdc.balanceOf(trader) - traderWalletBefore,
            preview.immediatePayoutUsdc,
            "Illiquid liquidation preview immediate payout should match live wallet delta"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Illiquid liquidation preview deferred payout should match live deferred payout delta"
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
            preview.immediatePayoutUsdc + preview.deferredPayoutUsdc,
            "Explicit fresh liquidation payout should equal total trader payout when no legacy deferred claim exists"
        );
        assertEq(
            preview.existingDeferredConsumedUsdc,
            0,
            "Fresh illiquid liquidation path should not consume legacy deferred payout"
        );
        assertEq(
            preview.existingDeferredRemainingUsdc,
            0,
            "Fresh illiquid liquidation path should not leave legacy deferred payout"
        );
    }

    function test_PreviewLiquidation_MatchesLiveExecution_WithQueuedExecutionEscrowOutsideReachability() public {
        address trader = address(0xC104);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 liquidationPrice = 102_500_000;

        _fundTrader(trader, 350e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, liquidationPrice);
        ICfdEngine.AccountLedgerSnapshot memory snapshotBefore = engine.getAccountLedgerSnapshot(accountId);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        uint256 deferredClearerBefore = engine.deferredClearerBountyUsdc(KEEPER);
        uint256 deferredBefore = engine.deferredPayoutUsdc(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(liquidationPrice);

        vm.prank(KEEPER);
        router.executeLiquidation(accountId, priceData);

        assertEq(
            preview.reachableCollateralUsdc,
            snapshotBefore.terminalReachableUsdc,
            "Liquidation preview must exclude router execution escrow from reachable collateral"
        );
        assertEq(
            (usdc.balanceOf(KEEPER) - keeperWalletBefore)
                + (engine.deferredClearerBountyUsdc(KEEPER) - deferredClearerBefore),
            preview.keeperBountyUsdc,
            "Queued-escrow liquidation preview keeper bounty should match live outcome"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId) - deferredBefore,
            preview.deferredPayoutUsdc,
            "Queued-escrow liquidation preview deferred payout should match live outcome"
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
