// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ClaimEngineViewTypes} from "../../../src/perps/interfaces/ClaimEngineViewTypes.sol";
import {ICfdEngineTypes} from "../../../src/perps/interfaces/ICfdEngineTypes.sol";
import {CashPriorityLib} from "../../../src/perps/libraries/CashPriorityLib.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpTraderClaimInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.createTraderClaim.selector;
        selectors[4] = handler.settleTraderClaim.selector;
        selectors[5] = handler.setPoolAssets.selector;
        selectors[6] = handler.fundHousePool.selector;
        selectors[7] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_TraderClaimStatusMatchesEngineAndHousePoolLiquidity() public view {
        uint256 totalTraderClaimBalanceUsdc;
        uint256 poolAssets = housePool.totalAssets();
        uint256 totalTraderClaimBalanceUsdc_ = engine.totalTraderClaimBalanceUsdc();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ClaimEngineViewTypes.TraderClaimStatus memory status = _traderClaimStatus(account, address(handler));
            uint256 traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
            uint256 expectedTraderClaimServiceableNow = CashPriorityLib.availableCashForClaimService(
                poolAssets, totalTraderClaimBalanceUsdc_, traderClaimBalanceUsdc
            );

            assertEq(status.traderClaimBalanceUsdc, traderClaimBalanceUsdc, "Trader claim status amount mismatch");
            assertEq(
                status.traderClaimServiceableNow,
                traderClaimBalanceUsdc > 0 && expectedTraderClaimServiceableNow > 0,
                "Trader claim serviceability mismatch"
            );

            totalTraderClaimBalanceUsdc += traderClaimBalanceUsdc;
        }

        assertEq(totalTraderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc(), "Total trader claim mismatch");
    }

    function invariant_GhostTraderClaimsRemainFullyModelDerived() public view {
        uint256 ghostTotalTraderClaimUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 ghostTraderClaimUsdc = handler.traderClaimSnapshot(account);
            uint256 liveTraderClaimUsdc = engine.traderClaimBalanceUsdc(account);

            assertEq(ghostTraderClaimUsdc, liveTraderClaimUsdc, "Ghost trader claim balance must match engine state");
            ghostTotalTraderClaimUsdc += ghostTraderClaimUsdc;
        }

        assertEq(
            handler.totalTraderClaimSnapshot(),
            ghostTotalTraderClaimUsdc,
            "Ghost trader claim total must match tracked account sum"
        );
        assertEq(engine.totalTraderClaimBalanceUsdc(), ghostTotalTraderClaimUsdc, "Engine trader claim total mismatch");
    }

    function invariant_FullClosePreviewUsesAllOrNothingHousePoolLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, size, oraclePrice);
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
                "Close preview must choose immediate or trader claim"
            );
            uint256 freeCashForFreshPayouts =
                CashPriorityLib.reserveFreshPayouts(housePool.totalAssets(), engine.totalTraderClaimBalanceUsdc())
            .freeCashUsdc;
            if (freeCashForFreshPayouts >= totalPayoutUsdc) {
                assertEq(preview.traderClaimBalanceUsdc, 0, "Close preview must not defer when HousePool is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must fully defer when HousePool is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingHousePoolLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
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
                "Fresh liquidation payout must choose immediate settlement or trader claim balance"
            );
            if (housePool.totalAssets() >= totalFreshPayoutUsdc) {
                assertEq(
                    freshTraderClaimUsdc,
                    0,
                    "Liquidation preview must not defer the fresh payout when HousePool liquidity is sufficient"
                );
            } else {
                assertEq(
                    preview.immediatePayoutUsdc,
                    0,
                    "Liquidation preview must fully defer the fresh payout when HousePool is illiquid"
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
