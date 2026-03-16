// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpDeferredPayoutInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.cancelCloseOrder.selector;
        selectors[5] = handler.executeNextOrderBatch.selector;
        selectors[6] = handler.createDeferredTraderPayout.selector;
        selectors[7] = handler.claimDeferredPayout.selector;
        selectors[8] = handler.setVaultAssets.selector;
        selectors[9] = handler.fundVault.selector;
        selectors[10] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_DeferredPayoutStatusMatchesEngineAndVaultLiquidity() public view {
        uint256 vaultAssetsUsdc = vault.totalAssets();
        uint256 totalDeferredPayoutUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.DeferredPayoutStatus memory status = engine.getDeferredPayoutStatus(accountId, address(handler));
            uint256 deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            assertEq(status.deferredTraderPayoutUsdc, deferredPayoutUsdc, "Deferred payout status amount mismatch");
            assertEq(
                status.traderPayoutClaimableNow,
                deferredPayoutUsdc > 0 && vaultAssetsUsdc >= deferredPayoutUsdc,
                "Deferred payout claimability mismatch"
            );

            totalDeferredPayoutUsdc += deferredPayoutUsdc;
        }

        assertEq(totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc(), "Total deferred payout mismatch");
    }

    function invariant_FullClosePreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, size, oraclePrice, vaultDepthUsdc);
            if (!preview.valid) {
                continue;
            }

            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;
            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(preview.immediatePayoutUsdc == 0, preview.deferredPayoutUsdc > 0, "Close preview must choose immediate or deferred payout");
            if (vault.totalAssets() >= totalPayoutUsdc) {
                assertEq(preview.deferredPayoutUsdc, 0, "Close preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must fully defer when vault is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, oraclePrice, vaultDepthUsdc);
            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;

            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.deferredPayoutUsdc > 0,
                "Liquidation preview must choose immediate or deferred payout"
            );
            if (vault.totalAssets() >= totalPayoutUsdc) {
                assertEq(preview.deferredPayoutUsdc, 0, "Liquidation preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Liquidation preview must fully defer when vault is illiquid");
            }
        }
    }

    function _previewOraclePrice() internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        return price == 0 ? 1e8 : price;
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }
}
