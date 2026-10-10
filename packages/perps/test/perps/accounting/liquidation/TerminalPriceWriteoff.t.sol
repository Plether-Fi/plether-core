// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract TerminalEconomicStateWriteoffTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms.
    function test_DiagnosticPriceWriteoffShouldNotBeDoubleCounted() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.LONG, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(loserAccount, 1e8);
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(loserAccount).terminalPriceCollectibleCapUsdc;
        assertGt(priceLossUsdc, collectibleCapUsdc, "Setup must contain an uncollectible terminal price tail");
        assertEq(preview.badDebtUsdc, 0, "V2 price tails are diagnostic writeoffs, not protocol debt");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        assertEq(
            _poolMtmAdjustment(),
            50_000e6,
            "Exact terminal NAV should retain only the surviving winner liability after the loser's writeoff"
        );
    }

}

contract ReachableLiquidationWriteoffTest is BasePerpTest {

    address trader = address(0xA11CE);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms.
    function test_LiquidationConsumesReachableBalanceWithoutArtificialBadDebt() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 8000e6);

        uint256 liquidationPrice = 101_800_000;
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        assertTrue(preview.liquidatable, "Setup must remain below maintenance margin");
        assertLt(preview.pnlUsdc, 0, "Setup must realize a trader price loss");
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc = engineAccountLens.getAccountLedgerSnapshot(account).terminalPriceCollectibleCapUsdc;
        assertLe(priceLossUsdc, collectibleCapUsdc, "Setup price loss must remain fully collectible");
        assertEq(preview.badDebtUsdc, 0, "A collectible price loss must not produce a debt diagnostic");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(account, liquidationPrice, depth, uint64(block.timestamp), address(this));

        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0, "Liquidation should consume reachable price collateral and clear the position");
        assertEq(clearinghouse.pnlPledgeUsdc(account), 0, "Terminal liquidation must release the PnL pledge bucket");
    }

}

contract TerminalPriceTailAccountingTest is BasePerpTest {

    address winner = address(0xAAA1);
    address loser = address(0xBBB1);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms.
    function test_UncollectiblePriceTailIsWrittenOffWithoutMutableDebtState() public {
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.LONG, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(loserAccount, 1e8);
        assertLt(preview.pnlUsdc, 0, "Setup must realize a trader price loss");
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(loserAccount).terminalPriceCollectibleCapUsdc;
        assertGt(priceLossUsdc, collectibleCapUsdc, "Setup must contain an uncollectible terminal price tail");
        assertEq(preview.badDebtUsdc, 0, "V2 price tails are diagnostic writeoffs, not protocol debt");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        (uint256 remainingSize,,,,,,) = engine.positions(loserAccount);
        assertEq(remainingSize, 0, "Diagnostic writeoff must not block terminal liquidation");

        (bool debtGetterExists,) = address(engine).staticcall(abi.encodeWithSignature("accumulatedBadDebtUsdc()"));
        assertFalse(debtGetterExists, "V2 must not expose mutable accumulated-debt state");
        (bool debtClearExists,) = address(engine).call(abi.encodeWithSignature("clearBadDebt(uint256)", priceLossUsdc));
        assertFalse(debtClearExists, "V2 must not expose the retired debt-clearing selector");
    }

}

contract AccountPriceCollateralWriteoffTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms.
    function test_PriceWriteoffShouldNotBeDoubleCountedInExactTerminalNav() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.LONG, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(loserAccount, 1e8);
        assertLt(preview.pnlUsdc, 0, "Setup must realize a trader price loss");
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(loserAccount).terminalPriceCollectibleCapUsdc;
        assertGt(priceLossUsdc, collectibleCapUsdc, "Setup must contain a diagnostic price-loss writeoff");
        assertEq(preview.badDebtUsdc, 0, "Written-off price tails must not become protocol debt");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        assertEq(
            _poolMtmAdjustment(),
            50_000e6,
            "Exact NAV must include only the surviving winner's marked gain, not the written-off price tail"
        );
    }

}

contract ReservedSettlementBehaviorWriteoffTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#exact-terminal-price-pnl-terms.
    function test_ExactMtmCapsLossesAtAccountPriceCollateral() public {
        _fundTrader(traderA, 200_000 * 1e6);
        _fundTrader(traderB, 1000 * 1e6);

        address aAccount = traderA;
        address bAccount = traderB;

        // A enters LONG at 1.5e8 → profits when price drops to 1e8 (+$50K)
        // B enters LONG at 0.5e8 → loses when price rises to 1e8 (-$50K, but only $1K margin)
        _open(aAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 100_000 * 1e6, 1.5e8);
        _open(bAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 1000 * 1e6, 0.5e8);

        // Move mark to 1e8 — both positions still open (no liquidation).
        // A is winning $50K, B is losing $50K but has only $1K margin.
        // The pool has a live winner on the same side as an undercollateralized loser.
        // Exact terminal NAV nets only the loser's account-local collectible price collateral
        // against the winner liability. The uncollectible tail is a diagnostic writeoff.
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 loserCollectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(bAccount).terminalPriceCollectibleCapUsdc;
        assertEq(loserCollectibleCapUsdc, 930e6, "Fixture should leave 930 USDC of exact price collateral");

        uint256 mtm = _poolMtmAdjustment();
        assertEq(
            mtm,
            50_000e6 - loserCollectibleCapUsdc,
            "Exact MtM should net only the loser's collectible cap against the winner liability"
        );
    }

}
