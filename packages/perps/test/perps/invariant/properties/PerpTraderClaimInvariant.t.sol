// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "../handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";

contract PerpTraderClaimInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    error ClaimSettlementOutcomeMismatch(address account);
    error ClaimSettlementCashMismatch(address account);

    struct ClaimCashSnapshot {
        uint256 claim;
        uint256 totalClaims;
        uint256 poolCash;
        uint256 clearinghouseCash;
        uint256 settlement;
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(settlementToken, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);
        // Every campaign begins with two actual deferred claims, so aggregate liquidity differs from own-claim cash.
        handler.createTraderClaim(0);
        handler.restoreSolvencyAndClearDegradedMode();
        handler.setPoolAssets(1_000_000_000e6);
        handler.createTraderClaim(1);
        assertGt(engine.traderClaimBalanceAssets(handler.actorAt(0)), 0, "First seed claim must execute");
        assertGt(engine.traderClaimBalanceAssets(handler.actorAt(1)), 0, "Second seed claim must execute");

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

    /// @dev Probe the real settlement transaction, then restore the campaign state. Flat accounts isolate the cash
    ///      gate from live-position carry collection. PerpIndependentClaimInvariant covers live claim routing at
    ///      fixed time; EngineTraderClaims covers accrued-carry settlement. No legacy status struct or production
    ///      payout helper supplies the answer.
    function _assertInvariant_FlatClaimsSettleOnlyWhenAllClaimsAreFunded() internal {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address account = handler.actorAt(i);
            (uint256 size,,,,,,) = engine.positions(account);
            if (size != 0) {
                continue;
            }
            _checkFlatClaimSettlement(account);
        }
    }

    function _checkFlatClaimSettlement(
        address account
    ) internal {
        ClaimCashSnapshot memory before = ClaimCashSnapshot({
            claim: engine.traderClaimBalanceAssets(account),
            totalClaims: engine.totalTraderClaimBalanceAssets(),
            poolCash: settlementToken.balanceOf(address(housePool)),
            clearinghouseCash: settlementToken.balanceOf(address(clearinghouse)),
            settlement: clearinghouse.balanceAssets(account)
        });
        bool shouldSettle = before.claim > 0 && before.poolCash >= before.totalClaims;
        uint256 snapshot = vm.snapshotState();
        vm.prank(account);
        (bool settled, bytes memory reason) = address(engine).call(abi.encodeCall(engine.settleTraderClaim, (account)));
        bool outcomeMatches = settled == shouldSettle;
        bool cashMatches;
        if (settled && shouldSettle) {
            cashMatches = engine.traderClaimBalanceAssets(account) == 0
                && engine.totalTraderClaimBalanceAssets() == before.totalClaims - before.claim
                && clearinghouse.balanceAssets(account) == before.settlement + before.claim
                && settlementToken.balanceOf(address(clearinghouse)) == before.clearinghouseCash + before.claim
                && settlementToken.balanceOf(address(housePool)) == before.poolCash - before.claim;
        } else if (!settled) {
            bytes4 expectedError = before.claim == 0
                ? ICfdEngineTypes.CfdEngine__NoTraderClaim.selector
                : ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector;
            outcomeMatches = outcomeMatches && keccak256(reason) == keccak256(abi.encodeWithSelector(expectedError));
            cashMatches = engine.traderClaimBalanceAssets(account) == before.claim
                && engine.totalTraderClaimBalanceAssets() == before.totalClaims
                && clearinghouse.balanceAssets(account) == before.settlement
                && settlementToken.balanceOf(address(clearinghouse)) == before.clearinghouseCash
                && settlementToken.balanceOf(address(housePool)) == before.poolCash;
        }
        // Restore even a faulty successful transaction before reporting failure; expectations stay in memory.
        assertTrue(vm.revertToStateAndDelete(snapshot), "Claim probe must restore the campaign");
        if (!outcomeMatches) {
            revert ClaimSettlementOutcomeMismatch(account);
        }
        if (!cashMatches) {
            revert ClaimSettlementCashMismatch(account);
        }
    }

    function test_ClaimSettlementProbeCoversAggregateLiquidityBoundariesWithoutChangingState() public {
        address account = handler.actorAt(0);
        uint256 claim = engine.traderClaimBalanceAssets(account);
        uint256 total = engine.totalTraderClaimBalanceAssets();
        assertGt(total, claim, "Own-claim liquidity must differ from aggregate liquidity");
        uint256[5] memory cashLevels = [uint256(0), claim, total - 1, total, total + 1];
        for (uint256 i; i < cashLevels.length; ++i) {
            handler.setPoolAssets(cashLevels[i]);
            _assertAllInvariants();
            assertEq(settlementToken.balanceOf(address(housePool)), cashLevels[i], "Probe must restore pool custody");
            assertEq(engine.traderClaimBalanceAssets(account), claim, "Probe must restore account claim");
            assertEq(engine.totalTraderClaimBalanceAssets(), total, "Probe must restore aggregate claims");
        }
    }

    function test_ClaimInvariantDetectsSuccessDuringAggregateShortfall() public {
        address account = handler.actorAt(0);
        handler.setPoolAssets(engine.traderClaimBalanceAssets(account));
        vm.mockCall(address(engine), abi.encodeCall(engine.settleTraderClaim, (account)), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(ClaimSettlementOutcomeMismatch.selector, account));
        this.invariant_ObservedClaimsAndLiquidityGatingReconcile();
        vm.clearMockedCalls();
        _assertAllInvariants();
    }

    function test_ClaimInvariantDetectsRejectionDespiteFullFunding() public {
        address account = handler.actorAt(0);
        handler.setPoolAssets(engine.totalTraderClaimBalanceAssets());
        vm.mockCallRevert(
            address(engine),
            abi.encodeCall(engine.settleTraderClaim, (account)),
            abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector)
        );
        vm.expectRevert(abi.encodeWithSelector(ClaimSettlementOutcomeMismatch.selector, account));
        this.invariant_ObservedClaimsAndLiquidityGatingReconcile();
        vm.clearMockedCalls();
        _assertAllInvariants();
    }

    function test_ClaimInvariantDetectsSuccessfulNoOpSettlement() public {
        address account = handler.actorAt(0);
        handler.setPoolAssets(engine.totalTraderClaimBalanceAssets());
        vm.mockCall(address(engine), abi.encodeCall(engine.settleTraderClaim, (account)), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(ClaimSettlementCashMismatch.selector, account));
        this.invariant_ObservedClaimsAndLiquidityGatingReconcile();
        vm.clearMockedCalls();
        _assertAllInvariants();
    }

    function _assertInvariant_ObservedClaimsReconcileAcrossTrackedAccounts() internal view {
        uint256 observedTotalTraderClaimAssets;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            uint256 observedTraderClaimAssets = handler.traderClaimSnapshot(account);
            uint256 liveTraderClaimAssets = engine.traderClaimBalanceAssets(account);

            assertEq(
                observedTraderClaimAssets,
                liveTraderClaimAssets,
                "Observed trader claim balance must match engine state"
            );
            observedTotalTraderClaimAssets += observedTraderClaimAssets;
        }

        assertEq(
            handler.totalTraderClaimSnapshot(),
            observedTotalTraderClaimAssets,
            "Observed trader claim total must match tracked account sum"
        );
        assertEq(
            engine.totalTraderClaimBalanceAssets(), observedTotalTraderClaimAssets, "Engine trader claim total mismatch"
        );
    }

    function _assertInvariant_FullClosePreviewUsesAllOrNothingHousePoolLiquidityGating() internal view {
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

            uint256 freshTraderClaimAssets = preview.traderClaimBalanceAssets
                > preview.existingTraderClaimRemainingAssets
                ? preview.traderClaimBalanceAssets - preview.existingTraderClaimRemainingAssets
                : 0;
            uint256 totalFreshPayoutAssets = preview.immediatePayoutAssets + freshTraderClaimAssets;
            if (totalFreshPayoutAssets == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutAssets == 0,
                freshTraderClaimAssets > 0,
                "Close preview must choose immediate or trader claim"
            );
            assertEq(
                totalFreshPayoutAssets,
                preview.freshTraderPayoutAssets,
                "Close preview fresh payout split must reconcile"
            );
            uint256 freeCashForFreshPayouts =
                CashPriorityLib.reserveFreshPayouts(housePool.totalAssets(), engine.totalTraderClaimBalanceAssets())
            .freeCashAssets;
            if (freeCashForFreshPayouts >= totalFreshPayoutAssets) {
                assertEq(freshTraderClaimAssets, 0, "Close preview must not defer when HousePool is liquid");
            } else {
                assertEq(preview.immediatePayoutAssets, 0, "Close preview must fully defer when HousePool is illiquid");
            }
        }
    }

    function _assertInvariant_LiquidationPreviewUsesAllOrNothingHousePoolLiquidityGating() internal view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
            uint256 freshTraderClaimAssets = preview.traderClaimBalanceAssets
                > preview.existingTraderClaimRemainingAssets
                ? preview.traderClaimBalanceAssets - preview.existingTraderClaimRemainingAssets
                : 0;
            uint256 totalFreshPayoutAssets = preview.immediatePayoutAssets + freshTraderClaimAssets;

            if (totalFreshPayoutAssets == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutAssets == 0,
                freshTraderClaimAssets > 0,
                "Fresh liquidation payout must choose immediate settlement or trader claim balance"
            );
            if (housePool.totalAssets() >= totalFreshPayoutAssets) {
                assertEq(
                    freshTraderClaimAssets,
                    0,
                    "Liquidation preview must not defer the fresh payout when HousePool liquidity is sufficient"
                );
            } else {
                assertEq(
                    preview.immediatePayoutAssets,
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

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_ObservedClaimsAndLiquidityGatingReconcile() public {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal {
        _assertInvariant_FlatClaimsSettleOnlyWhenAllClaimsAreFunded();
        _assertInvariant_ObservedClaimsReconcileAcrossTrackedAccounts();
        _assertInvariant_FullClosePreviewUsesAllOrNothingHousePoolLiquidityGating();
        _assertInvariant_LiquidationPreviewUsesAllOrNothingHousePoolLiquidityGating();
    }

}
