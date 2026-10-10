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
        assertEq(preview.traderClaimBalanceUsdc, 0, "Immediate close payout should not defer trader funds");
        assertEq(preview.immediatePayoutUsdc, 19_968e6, "Price profit less the 4 bps close fee is paid immediately");
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        assertEq(clearinghouse.balanceUsdc(account), settlementBefore + 19_968e6);
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), treasuryBefore + 32e6);
        assertEq(usdc.balanceOf(address(pool)), poolCashBefore - 20_000e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore + 20_000e6);
        assertEq(engine.traderClaimBalanceUsdc(account), 0);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0);
    }

    function test_CloseTraderClaimMode() public {
        address trader = address(0xA002);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        usdc.burn(address(pool), pool.totalAssets());

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid close payout should not credit settlement immediately");
        assertEq(preview.traderClaimBalanceUsdc, 19_968e6, "Price profit less the 4 bps close fee becomes a claim");
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        assertEq(clearinghouse.balanceUsdc(account), settlementBefore);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(engine.traderClaimBalanceUsdc(account), 19_968e6);
        assertEq(engine.totalTraderClaimBalanceUsdc(), 19_968e6);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0);
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

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccount);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertGt(
            clearinghouse.balanceUsdc(keeperAccount) - keeperSettlementBefore,
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
        assertEq(preview.badDebtUsdc, 0, "Uncollectible price loss is written off, not stored as protocol debt");
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(180_000_000));
        vm.prank(address(0xA105));
        router.executeLiquidation(account, priceData);
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0, "Underwater liquidation must execute");
        assertEq(
            usdc.balanceOf(address(pool)) - poolCashBefore,
            custodyBefore - usdc.balanceOf(address(clearinghouse)),
            "Seized custody reaches pool"
        );
        assertEq(engine.traderClaimBalanceUsdc(account), 0, "Price loss does not create a trader claim");
    }

}
