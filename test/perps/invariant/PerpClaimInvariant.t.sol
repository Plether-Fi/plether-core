// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ClaimEngineViewTypes} from "../../../src/perps/interfaces/ClaimEngineViewTypes.sol";
import {CashPriorityLib} from "../../../src/perps/libraries/CashPriorityLib.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpClaimInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.createTraderClaim.selector;
        selectors[4] = handler.claimTraderClaim.selector;
        selectors[5] = handler.setVaultAssets.selector;
        selectors[6] = handler.fundVault.selector;
        selectors[7] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ClaimStatusMatchesEngineAndVaultLiquidity() public view {
        uint256 totalTraderClaimBalanceUsdc;
        uint256 vaultAssets = vault.totalAssets();
        uint256 protocolFeesUsdc = engine.accumulatedFeesUsdc();
        uint256 totalTraderClaimBalanceUsdc_ = clearinghouse.totalTraderClaimBalanceUsdc();
        uint256 totalKeeperClaimBalanceUsdc = clearinghouse.totalKeeperClaimBalanceUsdc();
        uint256 handlerKeeperCreditUsdc = clearinghouse.keeperClaimBalanceUsdc(address(handler));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ClaimEngineViewTypes.ClaimStatus memory status = _claimStatus(account, address(handler));
            uint256 traderClaimBalanceUsdc = clearinghouse.traderClaimBalanceUsdc(account);
            uint256 keeperClaimBalanceUsdc = handlerKeeperCreditUsdc;
            uint256 otherTraderClaimUsdc = totalTraderClaimBalanceUsdc_ > traderClaimBalanceUsdc
                ? totalTraderClaimBalanceUsdc_ - traderClaimBalanceUsdc
                : 0;
            uint256 expectedTraderClaimableNow = CashPriorityLib.availableCashForClaimService(
                vaultAssets,
                protocolFeesUsdc,
                totalTraderClaimBalanceUsdc_,
                totalKeeperClaimBalanceUsdc,
                traderClaimBalanceUsdc
            );
            uint256 expectedKeeperClaimableNow = CashPriorityLib.availableCashForClaimService(
                vaultAssets, protocolFeesUsdc, otherTraderClaimUsdc, keeperClaimBalanceUsdc, keeperClaimBalanceUsdc
            );

            assertEq(
                status.traderClaimBalanceUsdc, traderClaimBalanceUsdc, "trader claim balance status amount mismatch"
            );
            assertEq(
                status.traderClaimServiceableNow,
                traderClaimBalanceUsdc > 0 && expectedTraderClaimableNow > 0,
                "trader claim balanceability mismatch"
            );
            assertEq(
                status.keeperClaimServiceableNow,
                keeperClaimBalanceUsdc > 0 && expectedKeeperClaimableNow > 0,
                "keeper claim balance claimability mismatch"
            );

            totalTraderClaimBalanceUsdc += traderClaimBalanceUsdc;
        }

        assertEq(
            totalTraderClaimBalanceUsdc,
            clearinghouse.totalTraderClaimBalanceUsdc(),
            "Total trader claim balance mismatch"
        );
    }

    function invariant_GhostTraderClaimsRemainFullyModelDerived() public view {
        uint256 ghostTotalTraderClaimUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 ghostTraderClaimUsdc = handler.traderClaimSnapshot(account);
            uint256 liveTraderClaimUsdc = clearinghouse.traderClaimBalanceUsdc(account);

            assertEq(ghostTraderClaimUsdc, liveTraderClaimUsdc, "Ghost trader claim balance must match engine state");
            ghostTotalTraderClaimUsdc += ghostTraderClaimUsdc;
        }

        assertEq(
            handler.totalTraderClaimSnapshot(),
            ghostTotalTraderClaimUsdc,
            "Ghost trader claim balance total must match tracked account sum"
        );
        assertEq(
            clearinghouse.totalTraderClaimBalanceUsdc(),
            ghostTotalTraderClaimUsdc,
            "Engine trader claim balance total mismatch"
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

            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc;
            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.traderClaimBalanceUsdc > 0,
                "Close preview must choose immediate or trader claim balance"
            );
            uint256 freeCashForFreshPayouts =
                CashPriorityLib.reserveFreshPayouts(
                vault.totalAssets(),
                engine.accumulatedFeesUsdc(),
                clearinghouse.totalTraderClaimBalanceUsdc(),
                clearinghouse.totalKeeperClaimBalanceUsdc()
            )
            .freeCashUsdc;
            if (freeCashForFreshPayouts >= totalPayoutUsdc) {
                assertEq(
                    preview.traderClaimBalanceUsdc, 0, "Close preview must not create a claim when vault is liquid"
                );
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must create a claim when vault is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
            uint256 freshTraderClaimUsdc = preview.traderClaimBalanceUsdc > preview.existingTraderClaimRemainingUsdc
                ? preview.traderClaimBalanceUsdc - preview.existingTraderClaimRemainingUsdc
                : 0;
            uint256 totalFreshPayoutUsdc = preview.immediatePayoutUsdc + freshTraderClaimUsdc;

            if (totalFreshPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                freshTraderClaimUsdc > 0,
                "Fresh liquidation payout must choose immediate or claim settlement"
            );
            if (vault.totalAssets() >= totalFreshPayoutUsdc) {
                assertEq(
                    freshTraderClaimUsdc,
                    0,
                    "Liquidation preview must not create a claim for the fresh payout when vault liquidity is sufficient"
                );
            } else {
                assertEq(
                    preview.immediatePayoutUsdc,
                    0,
                    "Liquidation preview must record the fresh payout as a claim when vault is illiquid"
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
