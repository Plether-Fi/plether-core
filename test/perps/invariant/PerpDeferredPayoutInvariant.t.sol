// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {DeferredEngineViewTypes} from "../../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {CashPriorityLib} from "../../../src/perps/libraries/CashPriorityLib.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpDeferredPayoutInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.createDeferredTraderPayout.selector;
        selectors[4] = handler.claimDeferredPayout.selector;
        selectors[5] = handler.setVaultAssets.selector;
        selectors[6] = handler.fundVault.selector;
        selectors[7] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_DeferredPayoutStatusMatchesEngineAndVaultLiquidity() public view {
        uint256 totalDeferredPayoutUsdc;
        bool anyLiquidity = vault.totalAssets() > 0;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            DeferredEngineViewTypes.DeferredPayoutStatus memory status =
                _deferredPayoutStatus(accountId, address(handler));
            uint256 deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
            uint256 deferredClearerBountyUsdc = engine.deferredClearerBountyUsdc(address(handler));

            assertEq(status.deferredTraderPayoutUsdc, deferredPayoutUsdc, "Deferred payout status amount mismatch");
            assertEq(
                status.traderPayoutClaimableNow,
                deferredPayoutUsdc > 0 && anyLiquidity,
                "Deferred payout claimability mismatch"
            );
            assertEq(
                status.liquidationBountyClaimableNow,
                deferredClearerBountyUsdc > 0 && anyLiquidity,
                "Deferred clearer bounty claimability mismatch"
            );

            totalDeferredPayoutUsdc += deferredPayoutUsdc;
        }

        assertEq(totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc(), "Total deferred payout mismatch");
    }

    function invariant_GhostDeferredTraderPayoutsRemainFullyModelDerived() public view {
        uint256 ghostTotalDeferredPayoutUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostDeferredPayoutUsdc = handler.deferredTraderPayoutSnapshot(accountId);
            uint256 liveDeferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            assertEq(
                ghostDeferredPayoutUsdc, liveDeferredPayoutUsdc, "Ghost deferred trader payout must match engine state"
            );
            ghostTotalDeferredPayoutUsdc += ghostDeferredPayoutUsdc;
        }

        assertEq(
            handler.totalDeferredTraderPayoutSnapshot(),
            ghostTotalDeferredPayoutUsdc,
            "Ghost deferred payout total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredPayoutUsdc(), ghostTotalDeferredPayoutUsdc, "Engine deferred payout total mismatch"
        );
    }

    function invariant_FullClosePreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, size, oraclePrice);
            if (!preview.valid) {
                continue;
            }

            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;
            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.deferredPayoutUsdc > 0,
                "Close preview must choose immediate or deferred payout"
            );
            uint256 freeCashForFreshPayouts =
                CashPriorityLib.reserveFreshPayouts(
                vault.totalAssets(),
                engine.accumulatedFeesUsdc(),
                engine.totalDeferredPayoutUsdc(),
                engine.totalDeferredClearerBountyUsdc()
            )
            .freeCashUsdc;
            if (freeCashForFreshPayouts >= totalPayoutUsdc) {
                assertEq(preview.deferredPayoutUsdc, 0, "Close preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must fully defer when vault is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, oraclePrice);
            uint256 freshDeferredPayoutUsdc = preview.deferredPayoutUsdc > preview.existingDeferredRemainingUsdc
                ? preview.deferredPayoutUsdc - preview.existingDeferredRemainingUsdc
                : 0;
            uint256 totalFreshPayoutUsdc = preview.immediatePayoutUsdc + freshDeferredPayoutUsdc;

            if (totalFreshPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                freshDeferredPayoutUsdc > 0,
                "Fresh liquidation payout must choose immediate or deferred settlement"
            );
            if (vault.totalAssets() >= totalFreshPayoutUsdc) {
                assertEq(
                    freshDeferredPayoutUsdc,
                    0,
                    "Liquidation preview must not defer the fresh payout when vault liquidity is sufficient"
                );
            } else {
                assertEq(
                    preview.immediatePayoutUsdc,
                    0,
                    "Liquidation preview must fully defer the fresh payout when vault is illiquid"
                );
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
