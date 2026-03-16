// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";

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

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 100_000e18, closePrice, pool.totalAssets());
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
        assertEq(preview.triggersDegradedMode, engine.degradedMode(), "Close preview degraded-mode flag should match live outcome");
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

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 100_000e18, closePrice, pool.totalAssets());
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
        assertEq(marginAfter, preview.remainingMargin, "Illiquid close preview remaining margin should match live execution");
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
        assertEq(preview.triggersDegradedMode, engine.degradedMode(), "Illiquid close preview degraded-mode flag should match live outcome");
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

        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, liquidationPrice, pool.totalAssets());
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
            (usdc.balanceOf(KEEPER) - keeperWalletBefore) + (engine.deferredClearerBountyUsdc(KEEPER) - deferredClearerBefore),
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
        assertEq(preview.triggersDegradedMode, engine.degradedMode(), "Liquidation preview degraded-mode flag should match live outcome");
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

        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, liquidationPrice, pool.totalAssets());
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
            (usdc.balanceOf(KEEPER) - keeperWalletBefore) + (engine.deferredClearerBountyUsdc(KEEPER) - deferredClearerBefore),
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
        assertEq(preview.triggersDegradedMode, engine.degradedMode(), "Illiquid liquidation preview degraded-mode flag should match live outcome");
    }
}
