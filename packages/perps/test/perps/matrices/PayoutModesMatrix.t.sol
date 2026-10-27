// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract PayoutModesMatrixTest is BasePerpTest {

    function test_CloseImmediatePayoutMode() public {
        address trader = address(0xA001);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertEq(preview.traderClaimBalanceAssets, 0, "Immediate close payout should not defer trader funds");
        assertEq(preview.immediatePayoutAssets, 19_968e6, "Price profit less the 4 bps close fee is paid immediately");
        assertEq(preview.payoutToPnlPledgeAssets, 0, "Full close leaves no position pledge");
        assertEq(preview.payoutToFreeSettlementAssets, 19_968e6);
        assertEq(preview.deferredPayoutAssets, 0);
        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        uint256 poolCashBefore = settlementToken.balanceOf(address(pool));
        uint256 custodyBefore = settlementToken.balanceOf(address(clearinghouse));
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        assertEq(clearinghouse.balanceAssets(account), settlementBefore + 19_968e6);
        assertEq(clearinghouse.balanceAssets(engine.protocolTreasury()), treasuryBefore + 32e6);
        assertEq(settlementToken.balanceOf(address(pool)), poolCashBefore - 20_000e6);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), custodyBefore + 20_000e6);
        assertEq(engine.traderClaimBalanceAssets(account), 0);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0);
    }

    function test_CloseTraderClaimMode() public {
        address trader = address(0xA002);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        settlementToken.burn(address(pool), pool.totalAssets());

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertEq(preview.immediatePayoutAssets, 0, "Illiquid close payout should not credit settlement immediately");
        assertEq(preview.traderClaimBalanceAssets, 19_968e6, "Price profit less the 4 bps close fee becomes a claim");
        assertEq(preview.payoutToPnlPledgeAssets, 0);
        assertEq(preview.payoutToFreeSettlementAssets, 0);
        assertEq(preview.deferredPayoutAssets, 19_968e6);
        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        uint256 custodyBefore = settlementToken.balanceOf(address(clearinghouse));
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        assertEq(clearinghouse.balanceAssets(account), settlementBefore);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), custodyBefore);
        assertEq(settlementToken.balanceOf(address(pool)), 0);
        assertEq(engine.traderClaimBalanceAssets(account), 19_968e6);
        assertEq(engine.totalTraderClaimBalanceAssets(), 19_968e6);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0);
    }

    function test_PartialClosePricePayoutStaysPledged() public {
        _assertPartialClosePayoutRouting(false);
    }

    function test_PartialCloseIlliquidPricePayoutBecomesClaim() public {
        _assertPartialClosePayoutRouting(true);
    }

    function _assertPartialClosePayoutRouting(
        bool illiquid
    ) private {
        address account = address(0xA006);
        _fundTrader(account, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        if (illiquid) {
            settlementToken.burn(address(pool), pool.totalAssets());
        }

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 80_000_000);
        _assertClosePreviewEquals(preview, engineLens.simulateClose(account, 50_000e18, 80_000_000, pool.totalAssets()));
        assertTrue(preview.valid);
        assertEq(preview.freshTraderPayoutAssets, 9984e6, "$10,000 profit less $16 fee");
        assertEq(preview.payoutToFreeSettlementAssets, 0, "Price profit on a partial close is not free cash");
        assertEq(preview.payoutToPnlPledgeAssets, illiquid ? 0 : 9984e6);
        assertEq(preview.deferredPayoutAssets, illiquid ? 9984e6 : 0);
        assertEq(preview.immediatePayoutAssets, preview.payoutToPnlPledgeAssets);
        assertEq(clearinghouse.liquidationReserveAssets(account), 100e6, "$100,000 notional at 10 bps");
        uint256 pledgeBefore = clearinghouse.pnlPledgeAssets(account);
        uint256 freeBefore = clearinghouse.getFreeBuyingPowerAssets(account);
        uint256 settlementBefore = clearinghouse.balanceAssets(account);

        _close(account, CfdTypes.Side.LONG, 50_000e18, 80_000_000);

        assertEq(clearinghouse.liquidationReserveAssets(account), 40e6, "$40,000 remaining notional at 10 bps");
        assertEq(clearinghouse.balanceAssets(account) - settlementBefore, preview.payoutToPnlPledgeAssets);
        assertEq(clearinghouse.pnlPledgeAssets(account), pledgeBefore / 2 + preview.payoutToPnlPledgeAssets);
        assertEq(
            clearinghouse.getFreeBuyingPowerAssets(account) - freeBefore,
            pledgeBefore / 2 + 60e6,
            "Only old collateral and $60 of liquidation reserve are freed; the new profit is not"
        );
        assertEq(engine.traderClaimBalanceAssets(account), preview.deferredPayoutAssets);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 50_000e18);
    }

    function test_PartialCloseSeparatesPledgedPriceProfitFromFreeRebate() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.1e18;
        _setRiskParams(params);
        address account = address(0xA007);
        _fundTrader(account, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 80_000_000);
        assertTrue(preview.valid);
        assertEq(preview.payoutToPnlPledgeAssets, 10_000e6, "Price gain is pledged with no positive action charge");
        assertGt(preview.payoutToFreeSettlementAssets, 0, "Net action rebate must be paid as free cash");
        assertEq(preview.deferredPayoutAssets, 0);
        assertEq(preview.immediatePayoutAssets, 10_000e6 + preview.payoutToFreeSettlementAssets);
        assertEq(clearinghouse.liquidationReserveAssets(account), 100e6, "$100,000 notional at 10 bps");
        uint256 pledgeBefore = clearinghouse.pnlPledgeAssets(account);
        uint256 freeBefore = clearinghouse.getFreeBuyingPowerAssets(account);
        uint256 settlementBefore = clearinghouse.balanceAssets(account);

        _close(account, CfdTypes.Side.LONG, 50_000e18, 80_000_000);

        assertEq(clearinghouse.liquidationReserveAssets(account), 40e6, "$40,000 remaining notional at 10 bps");
        assertEq(clearinghouse.balanceAssets(account) - settlementBefore, preview.immediatePayoutAssets);
        assertEq(clearinghouse.pnlPledgeAssets(account), pledgeBefore / 2 + 10_000e6);
        assertEq(
            clearinghouse.getFreeBuyingPowerAssets(account) - freeBefore,
            pledgeBefore / 2 + 60e6 + preview.payoutToFreeSettlementAssets,
            "Free balance receives the rebate, old collateral and $60 reserve release, but no price profit"
        );
    }

    function test_LiquidationImmediateKeeperCreditMode() public {
        address trader = address(0xA003);
        address account = trader;
        address keeper = address(0xA103);
        address keeperAccount = keeper;
        _fundTrader(trader, 900e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 70e6);

        uint256 keeperSettlementBefore = clearinghouse.balanceAssets(keeperAccount);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertGt(
            clearinghouse.balanceAssets(keeperAccount) - keeperSettlementBefore,
            0,
            "Liquid mode should credit keeper bounty immediately"
        );
    }

    function test_LiquidationPriceLossWriteoffMode() public {
        address trader = address(0xA005);
        address account = trader;
        _fundTrader(trader, 400e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 180_000_000);
        assertTrue(preview.liquidatable, "Deeply underwater position should be liquidatable");
        uint256 poolCashBefore = settlementToken.balanceOf(address(pool));
        uint256 custodyBefore = settlementToken.balanceOf(address(clearinghouse));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(180_000_000));
        _ensureLaterOracleTime();
        vm.prank(address(0xA105));
        router.executeLiquidation(account, priceData);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0, "Underwater liquidation must execute");
        assertEq(
            settlementToken.balanceOf(address(pool)) - poolCashBefore,
            custodyBefore - settlementToken.balanceOf(address(clearinghouse)),
            "Seized custody reaches pool"
        );
        assertEq(engine.traderClaimBalanceAssets(account), 0, "Price loss does not create a trader claim");
    }

}
