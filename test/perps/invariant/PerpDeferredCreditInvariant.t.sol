// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {DeferredEngineViewTypes} from "../../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {CashPriorityLib} from "../../../src/perps/libraries/CashPriorityLib.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpDeferredCreditInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.createDeferredTraderCredit.selector;
        selectors[4] = handler.claimDeferredTraderCredit.selector;
        selectors[5] = handler.setVaultAssets.selector;
        selectors[6] = handler.fundVault.selector;
        selectors[7] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_DeferredCreditStatusMatchesEngineAndVaultLiquidity() public view {
        uint256 totalDeferredTraderCreditUsdc;
        uint256 vaultAssets = vault.totalAssets();
        uint256 protocolFeesUsdc = engine.accumulatedFeesUsdc();
        uint256 totalDeferredTraderCreditUsdc_ = engine.totalDeferredTraderCreditUsdc();
        uint256 totalDeferredKeeperCreditUsdc = engine.totalDeferredKeeperCreditUsdc();
        uint256 handlerKeeperCreditUsdc = engine.deferredKeeperCreditUsdc(address(handler));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            DeferredEngineViewTypes.DeferredCreditStatus memory status =
                _deferredCreditStatus(account, address(handler));
            uint256 deferredTraderCreditUsdc = engine.deferredTraderCreditUsdc(account);
            uint256 deferredKeeperCreditUsdc = handlerKeeperCreditUsdc;
            uint256 otherDeferredTraderCreditUsdc = totalDeferredTraderCreditUsdc_ > deferredTraderCreditUsdc
                ? totalDeferredTraderCreditUsdc_ - deferredTraderCreditUsdc
                : 0;
            uint256 expectedTraderClaimableNow = CashPriorityLib.availableCashForDeferredBeneficiaryClaim(
                vaultAssets,
                protocolFeesUsdc,
                totalDeferredTraderCreditUsdc_,
                totalDeferredKeeperCreditUsdc,
                deferredTraderCreditUsdc
            );
            uint256 expectedKeeperClaimableNow = CashPriorityLib.availableCashForDeferredBeneficiaryClaim(
                vaultAssets,
                protocolFeesUsdc,
                otherDeferredTraderCreditUsdc,
                deferredKeeperCreditUsdc,
                deferredKeeperCreditUsdc
            );

            assertEq(
                status.deferredTraderCreditUsdc, deferredTraderCreditUsdc, "Deferred payout status amount mismatch"
            );
            assertEq(
                status.traderPayoutClaimableNow,
                deferredTraderCreditUsdc > 0 && expectedTraderClaimableNow > 0,
                "Deferred payout claimability mismatch"
            );
            assertEq(
                status.keeperCreditClaimableNow,
                deferredKeeperCreditUsdc > 0 && expectedKeeperClaimableNow > 0,
                "Deferred keeper credit claimability mismatch"
            );

            totalDeferredTraderCreditUsdc += deferredTraderCreditUsdc;
        }

        assertEq(
            totalDeferredTraderCreditUsdc, engine.totalDeferredTraderCreditUsdc(), "Total deferred payout mismatch"
        );
    }

    function invariant_GhostDeferredTraderCreditsRemainFullyModelDerived() public view {
        uint256 ghostTotalDeferredTraderCreditUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 ghostDeferredTraderCreditUsdc = handler.deferredTraderCreditSnapshot(account);
            uint256 liveDeferredTraderCreditUsdc = engine.deferredTraderCreditUsdc(account);

            assertEq(
                ghostDeferredTraderCreditUsdc,
                liveDeferredTraderCreditUsdc,
                "Ghost deferred trader credit must match engine state"
            );
            ghostTotalDeferredTraderCreditUsdc += ghostDeferredTraderCreditUsdc;
        }

        assertEq(
            handler.totalDeferredTraderCreditSnapshot(),
            ghostTotalDeferredTraderCreditUsdc,
            "Ghost deferred payout total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredTraderCreditUsdc(),
            ghostTotalDeferredTraderCreditUsdc,
            "Engine deferred payout total mismatch"
        );
    }

    function invariant_FullClosePreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, size, oraclePrice);
            if (!preview.valid) {
                continue;
            }

            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredTraderCreditUsdc;
            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.deferredTraderCreditUsdc > 0,
                "Close preview must choose immediate or deferred payout"
            );
            uint256 freeCashForFreshPayouts =
                CashPriorityLib.reserveFreshPayouts(
                vault.totalAssets(),
                engine.accumulatedFeesUsdc(),
                engine.totalDeferredTraderCreditUsdc(),
                engine.totalDeferredKeeperCreditUsdc()
            )
            .freeCashUsdc;
            if (freeCashForFreshPayouts >= totalPayoutUsdc) {
                assertEq(preview.deferredTraderCreditUsdc, 0, "Close preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must fully defer when vault is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
            uint256 freshDeferredTraderCreditUsdc = preview.deferredTraderCreditUsdc
                > preview.existingDeferredRemainingUsdc
                ? preview.deferredTraderCreditUsdc - preview.existingDeferredRemainingUsdc
                : 0;
            uint256 totalFreshPayoutUsdc = preview.immediatePayoutUsdc + freshDeferredTraderCreditUsdc;

            if (totalFreshPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                freshDeferredTraderCreditUsdc > 0,
                "Fresh liquidation payout must choose immediate or deferred settlement"
            );
            if (vault.totalAssets() >= totalFreshPayoutUsdc) {
                assertEq(
                    freshDeferredTraderCreditUsdc,
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

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

}
