// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract PayoutModesMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_CloseImmediatePayoutMode() public {
        address trader = address(0xA001);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertEq(preview.traderClaimBalanceUsdc, 0, "Immediate close payout should not create a trader claim");
        assertGt(preview.immediatePayoutUsdc, 0, "Immediate close payout should credit settlement immediately");
    }

    function test_CloseTraderClaimMode() public {
        address trader = address(0xA002);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);
        usdc.burn(address(pool), pool.totalAssets());

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid close payout should not credit settlement immediately");
        assertGt(preview.traderClaimBalanceUsdc, 0, "Illiquid close payout should become a claim");
    }

    function test_LiquidationImmediateKeeperCreditMode() public {
        address trader = address(0xA003);
        address account = trader;
        address keeper = address(0xA103);
        address keeperAccount = keeper;
        _fundTrader(trader, 900e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

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
        assertEq(clearinghouse.keeperClaimBalanceUsdc(keeper), 0, "Liquid mode should not create a keeper claim");
    }

    function test_LiquidationBadDebtMode() public {
        address trader = address(0xA005);
        address account = trader;
        _fundTrader(trader, 400e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(account).checked_write(uint256(0));

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 180_000_000);
        assertGt(preview.badDebtUsdc, 0, "Deeply underwater liquidation should surface bad debt");
    }

}
