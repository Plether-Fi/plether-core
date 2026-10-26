// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "../handlers/PerpAccountingHandler.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

contract PerpPreviewInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 9,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(settlementToken, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.warpForward.selector;
        selectors[7] = handler.syncMarkNow.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _assertInvariant_ProtocolAccountingViewMatchesCoreState() internal view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory accountingView =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(accountingView.degradedMode, engine.degradedMode(), "Protocol accounting view degraded flag mismatch");
        assertEq(
            accountingView.totalTraderClaimBalanceAssets,
            engine.totalTraderClaimBalanceAssets(),
            "Protocol accounting view trader claim balance mismatch"
        );
        assertEq(
            accountingView.protocolTreasuryBalanceAssets,
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            "Protocol accounting view treasury balance mismatch"
        );
    }

    function _assertInvariant_EmptyPositionsPreviewAsInactive() internal view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(account);
            if (size != 0) {
                continue;
            }

            ICfdEngineTypes.LiquidationPreview memory liquidationPreview =
                engineLens.previewLiquidation(account, oraclePrice);
            assertFalse(liquidationPreview.liquidatable, "Empty positions must not preview as liquidatable");
            assertEq(
                liquidationPreview.reachableCollateralAssets, 0, "Empty positions must not expose reachable collateral"
            );
            assertFalse(liquidationPreview.triggersDegradedMode, "Empty positions must not trigger degraded mode");

            ICfdEngineTypes.ClosePreview memory closePreview = engineLens.previewClose(account, 1, oraclePrice);
            assertFalse(closePreview.valid, "Empty positions must not preview as valid closes");
            assertEq(
                uint8(closePreview.invalidReason),
                uint8(CfdTypes.CloseInvalidReason.NoPosition),
                "Empty position close preview should return NoPosition"
            );
            assertFalse(
                closePreview.triggersDegradedMode, "Empty position close preview must not trigger degraded mode"
            );
        }
    }

    function _assertInvariant_LiquidationPreviewReachableCollateralMatchesClearinghouse() internal view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            ICfdEngineTypes.LiquidationPreview memory liquidationPreview =
                engineLens.previewLiquidation(account, oraclePrice);
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            uint256 priceRiskCollateralAssets = snapshot.activePositionMarginAssets + snapshot.traderClaimBalanceAssets;
            assertEq(
                liquidationPreview.reachableCollateralAssets,
                priceRiskCollateralAssets - _marginCarryConsumption(account, snapshot.activePositionMarginAssets)
                    + clearinghouse.vpiRebateReserveAssets(account),
                "Liquidation preview must use post-carry pledge, same-account claim, and the dedicated VPI reserve"
            );
            assertLe(
                snapshot.terminalPriceCollectibleCapAssets,
                priceRiskCollateralAssets,
                "Endpoint-clipped collectible cap must not exceed pledge plus same-account claims"
            );
        }
    }

    function _assertInvariant_LiquidationPreviewExcludesReservedExecutionBounty() internal view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            if (!snapshot.hasPosition || snapshot.executionBountyReserveAssets == 0) {
                continue;
            }

            ICfdEngineTypes.LiquidationPreview memory liquidationPreview =
                engineLens.previewLiquidation(account, oraclePrice);
            uint256 priceRiskCollateralAssets = snapshot.activePositionMarginAssets + snapshot.traderClaimBalanceAssets;
            assertEq(
                liquidationPreview.reachableCollateralAssets,
                priceRiskCollateralAssets - _marginCarryConsumption(account, snapshot.activePositionMarginAssets)
                    + clearinghouse.vpiRebateReserveAssets(account),
                "Liquidation preview must remain isolated to pledge, same-account claim, and VPI reserve"
            );
            assertEq(
                snapshot.liquidationReachableSettlementAssets,
                snapshot.settlementBalanceAssets - snapshot.executionBountyReserveAssets,
                "Account liquidation custody must exclude the reserved execution bounty"
            );
        }
    }

    function _marginCarryConsumption(
        address account,
        uint256 marginAssets
    ) internal view returns (uint256) {
        (,,,, CfdTypes.Side side,,) = engine.positions(account);
        (uint256 borrowBaseAssets, uint256 startIndex,) = engine.positionCarryState(account);
        (,,,,, uint256 baseCarryBps,,,,) = engine.riskParams();
        uint256 endIndex = PositionRiskAccountingLib.computeCurrentCarryIndex(
            engine.sideCarryIndex(uint256(side)),
            engine.sideCarryTimestamp(uint256(side)),
            block.timestamp,
            engine.sideBorrowBaseAssets(uint256(side)),
            housePool.totalAssets(),
            baseCarryBps
        );
        uint256 pendingCarryAssets = engine.unsettledCarryAssets(account)
            + PositionRiskAccountingLib.computeIndexedCarryAssets(borrowBaseAssets, endIndex - startIndex);
        return pendingCarryAssets < marginAssets ? pendingCarryAssets : marginAssets;
    }

    function _assertInvariant_PreviewLiquidation_EqualsSimulateLiquidationAtCanonicalDepth() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 canonicalDepth = housePool.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
            ICfdEngineTypes.LiquidationPreview memory simulation =
                engineLens.simulateLiquidation(account, oraclePrice, canonicalDepth);

            _assertLiquidationPreviewEquals(preview, simulation);
        }
    }

    function _assertInvariant_FullClosePreviewStaysConsistentWithCurrentDegradedMode() internal view {
        bool alreadyDegraded = engine.degradedMode();
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            ICfdEngineTypes.ClosePreview memory closePreview = engineLens.previewClose(account, size, oraclePrice);
            assertTrue(closePreview.valid, "Full close preview should stay valid for open positions");

            if (alreadyDegraded) {
                assertFalse(closePreview.triggersDegradedMode, "Close preview must not re-trigger degraded mode");
            }
        }
    }

    function _assertInvariant_TransitionFlagsOnlyAppearBeforeDegradedMode() internal view {
        bool alreadyDegraded = engine.degradedMode();
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ICfdEngineTypes.LiquidationPreview memory liquidationPreview =
                engineLens.previewLiquidation(account, oraclePrice);
            if (liquidationPreview.triggersDegradedMode) {
                assertFalse(alreadyDegraded, "Liquidation preview trigger flag must be transition-only");
            }

            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            ICfdEngineTypes.ClosePreview memory closePreview = engineLens.previewClose(account, size, oraclePrice);
            if (closePreview.triggersDegradedMode) {
                assertFalse(alreadyDegraded, "Close preview trigger flag must be transition-only");
            }
        }
    }

    function _assertInvariant_PostOpDegradedFlagMatchesPreviewBalances() internal view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            ICfdEngineTypes.LiquidationPreview memory liquidationPreview =
                engineLens.previewLiquidation(account, oraclePrice);
            assertEq(
                liquidationPreview.postOpDegradedMode,
                liquidationPreview.effectiveAssetsAfterAssets < liquidationPreview.maxLiabilityAfterAssets,
                "Liquidation preview post-op degraded flag mismatch"
            );

            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            ICfdEngineTypes.ClosePreview memory closePreview = engineLens.previewClose(account, size, oraclePrice);
            assertEq(
                closePreview.postOpDegradedMode,
                closePreview.effectiveAssetsAfterAssets < closePreview.maxLiabilityAfterAssets,
                "Close preview post-op degraded flag mismatch"
            );
        }
    }

    function _assertInvariant_LastOpenCommitAttemptRespectsPreviewCommitSemantics() internal view {
        PerpAccountingHandler.OpenCommitAttempt memory attempt = handler.lastOpenCommitAttemptSnapshot();
        if (!attempt.active) {
            return;
        }

        // The Engine preview sees only the live position; an earlier queued close can clear an opposing side.
        bool liveOpposingMayCloseFirst =
            attempt.revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING);

        if (attempt.commitSucceeded) {
            assertTrue(
                !attempt.prefilterActive
                    || attempt.failureCategory != CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable
                    || liveOpposingMayCloseFirst,
                "Committed opens must not bypass a predictable commit-time rejection"
            );
        }

        if (
            attempt.routerOpenAllowed && attempt.prefilterActive
                && attempt.failureCategory == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable
                && !liveOpposingMayCloseFirst
        ) {
            assertFalse(
                attempt.commitSucceeded,
                "Predictably invalid opens must not bypass the router commit-time prefilter when router-local gates are open"
            );
        }
    }

    function _assertInvariant_LastWithdrawAttemptMatchesGuardParity() internal view {
        PerpAccountingHandler.WithdrawParityAttempt memory attempt = handler.lastWithdrawParityAttemptSnapshot();
        if (!attempt.active) {
            return;
        }

        if (attempt.withdrawPasses) {
            assertTrue(
                attempt.checkWithdrawPasses,
                "Successful withdraws must only happen when checkWithdraw also passes under randomized carry/time evolution"
            );
        }
        if (!attempt.checkWithdrawPasses) {
            assertFalse(attempt.withdrawPasses, "Guard-blocked withdraws must not succeed live");
            assertEq(
                attempt.withdrawSelector,
                attempt.checkWithdrawSelector,
                "Withdraw revert selector must match checkWithdraw when the guard blocks"
            );
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

    function _assertLiquidationPreviewEquals(
        ICfdEngineTypes.LiquidationPreview memory actual,
        ICfdEngineTypes.LiquidationPreview memory expected
    ) internal pure {
        assertEq(actual.liquidatable, expected.liquidatable, "Liquidatable flag should match canonical simulation");
        assertEq(actual.oraclePrice, expected.oraclePrice, "Liquidation oracle price should match");
        assertEq(actual.equityAssets, expected.equityAssets, "Liquidation equity should match");
        assertEq(actual.pnlAssets, expected.pnlAssets, "Liquidation pnl should match");
        assertEq(
            actual.reachableCollateralAssets, expected.reachableCollateralAssets, "Reachable collateral should match"
        );
        assertEq(actual.liquidationChargeAssets, expected.liquidationChargeAssets, "Liquidation charge should match");
        assertEq(actual.keeperBountyAssets, expected.keeperBountyAssets, "Keeper bounty should match");
        assertEq(
            actual.protocolLiquidationFeeAssets,
            expected.protocolLiquidationFeeAssets,
            "Protocol liquidation fee should match"
        );
        assertEq(actual.lpLiquidationFeeAssets, expected.lpLiquidationFeeAssets, "LP liquidation fee should match");
        assertEq(actual.seizedCollateralAssets, expected.seizedCollateralAssets, "Seized collateral should match");
        assertEq(actual.settlementRetainedAssets, expected.settlementRetainedAssets, "Settlement retained should match");
        assertEq(actual.freshTraderPayoutAssets, expected.freshTraderPayoutAssets, "Fresh trader payout should match");
        assertEq(
            actual.existingTraderClaimConsumedAssets,
            expected.existingTraderClaimConsumedAssets,
            "Trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingAssets,
            expected.existingTraderClaimRemainingAssets,
            "Trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutAssets, expected.immediatePayoutAssets, "Immediate payout should match");
        assertEq(actual.traderClaimBalanceAssets, expected.traderClaimBalanceAssets, "Trader claim should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Post-op degraded mode should match");
        assertEq(
            actual.effectiveAssetsAfterAssets, expected.effectiveAssetsAfterAssets, "Effective assets should match"
        );
        assertEq(actual.maxLiabilityAfterAssets, expected.maxLiabilityAfterAssets, "Max liability should match");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_AccountAndLiquidationViewsMatchCanonicalState() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_ProtocolAccountingViewMatchesCoreState();
        _assertInvariant_EmptyPositionsPreviewAsInactive();
        _assertInvariant_LiquidationPreviewReachableCollateralMatchesClearinghouse();
        _assertInvariant_LiquidationPreviewExcludesReservedExecutionBounty();
        _assertInvariant_PreviewLiquidation_EqualsSimulateLiquidationAtCanonicalDepth();
        _assertInvariant_FullClosePreviewStaysConsistentWithCurrentDegradedMode();
        _assertInvariant_TransitionFlagsOnlyAppearBeforeDegradedMode();
        _assertInvariant_PostOpDegradedFlagMatchesPreviewBalances();
        _assertInvariant_LastOpenCommitAttemptRespectsPreviewCommitSemantics();
        _assertInvariant_LastWithdrawAttemptMatchesGuardParity();
    }

}
