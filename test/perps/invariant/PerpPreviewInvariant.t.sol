// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpPreviewInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.claimDeferredClearerBounty.selector;
        selectors[7] = handler.setRouterPayoutFailureMode.selector;
        selectors[8] = handler.warpForward.selector;
        selectors[9] = handler.syncMarkNow.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ProtocolAccountingViewMatchesCoreState() public view {
        CfdEngine.ProtocolAccountingView memory accountingView = engineProtocolLens.getProtocolAccountingView();

        assertEq(accountingView.degradedMode, engine.degradedMode(), "Protocol accounting view degraded flag mismatch");
        assertEq(
            accountingView.totalDeferredPayoutUsdc,
            engine.totalDeferredPayoutUsdc(),
            "Protocol accounting view deferred trader payout mismatch"
        );
        assertEq(
            accountingView.totalDeferredClearerBountyUsdc,
            engine.totalDeferredClearerBountyUsdc(),
            "Protocol accounting view deferred clearer bounty mismatch"
        );
        assertEq(
            accountingView.accumulatedFeesUsdc,
            engine.accumulatedFeesUsdc(),
            "Protocol accounting view accumulated fees mismatch"
        );
    }

    function invariant_EmptyPositionsPreviewAsInactive() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size != 0) {
                continue;
            }

            CfdEngine.LiquidationPreview memory liquidationPreview = engineLens.previewLiquidation(accountId, oraclePrice);
            assertFalse(liquidationPreview.liquidatable, "Empty positions must not preview as liquidatable");
            assertEq(
                liquidationPreview.reachableCollateralUsdc, 0, "Empty positions must not expose reachable collateral"
            );
            assertFalse(liquidationPreview.triggersDegradedMode, "Empty positions must not trigger degraded mode");

            CfdEngine.ClosePreview memory closePreview = engineLens.previewClose(accountId, 1, oraclePrice);
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

    function invariant_LiquidationPreviewReachableCollateralMatchesClearinghouse() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.LiquidationPreview memory liquidationPreview = engineLens.previewLiquidation(accountId, oraclePrice);
            assertEq(
                liquidationPreview.reachableCollateralUsdc,
                clearinghouse.getTerminalReachableUsdc(accountId),
                "Liquidation preview reachable collateral mismatch"
            );
        }
    }

    function invariant_LiquidationPreviewExcludesRouterExecutionEscrow() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            ICfdEngine.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(accountId);
            if (!snapshot.hasPosition || snapshot.executionEscrowUsdc == 0) {
                continue;
            }

            CfdEngine.LiquidationPreview memory liquidationPreview = engineLens.previewLiquidation(accountId, oraclePrice);
            assertEq(
                liquidationPreview.reachableCollateralUsdc,
                snapshot.terminalReachableUsdc,
                "Liquidation preview reachable collateral must match snapshot reachability"
            );
            assertLt(
                liquidationPreview.reachableCollateralUsdc,
                snapshot.settlementBalanceUsdc + snapshot.executionEscrowUsdc,
                "Liquidation preview must exclude router execution escrow from reachable collateral"
            );
        }
    }

    function invariant_PreviewLiquidation_EqualsSimulateLiquidationAtCanonicalDepth() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 canonicalDepth = vault.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, oraclePrice);
            CfdEngine.LiquidationPreview memory simulation =
                engineLens.simulateLiquidation(accountId, oraclePrice, canonicalDepth);

            _assertLiquidationPreviewEquals(preview, simulation);
        }
    }

    function invariant_FullClosePreviewStaysConsistentWithCurrentDegradedMode() public view {
        bool alreadyDegraded = engine.degradedMode();
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory closePreview = engineLens.previewClose(accountId, size, oraclePrice);
            assertTrue(closePreview.valid, "Full close preview should stay valid for open positions");

            if (alreadyDegraded) {
                assertFalse(closePreview.triggersDegradedMode, "Close preview must not re-trigger degraded mode");
            }
        }
    }

    function invariant_TransitionFlagsOnlyAppearBeforeDegradedMode() public view {
        bool alreadyDegraded = engine.degradedMode();
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory liquidationPreview = engineLens.previewLiquidation(accountId, oraclePrice);
            if (liquidationPreview.triggersDegradedMode) {
                assertFalse(alreadyDegraded, "Liquidation preview trigger flag must be transition-only");
            }

            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory closePreview = engineLens.previewClose(accountId, size, oraclePrice);
            if (closePreview.triggersDegradedMode) {
                assertFalse(alreadyDegraded, "Close preview trigger flag must be transition-only");
            }
        }
    }

    function invariant_PostOpDegradedFlagMatchesPreviewBalances() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory liquidationPreview = engineLens.previewLiquidation(accountId, oraclePrice);
            assertEq(
                liquidationPreview.postOpDegradedMode,
                liquidationPreview.effectiveAssetsAfterUsdc < liquidationPreview.maxLiabilityAfterUsdc,
                "Liquidation preview post-op degraded flag mismatch"
            );

            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory closePreview = engineLens.previewClose(accountId, size, oraclePrice);
            assertEq(
                closePreview.postOpDegradedMode,
                closePreview.effectiveAssetsAfterUsdc < closePreview.maxLiabilityAfterUsdc,
                "Close preview post-op degraded flag mismatch"
            );
        }
    }

    function invariant_LastOpenCommitAttemptRespectsPreviewCommitSemantics() public view {
        PerpAccountingHandler.OpenCommitAttempt memory attempt = handler.lastOpenCommitAttemptSnapshot();
        if (!attempt.active) {
            return;
        }

        if (attempt.commitSucceeded) {
            assertTrue(
                !attempt.prefilterActive
                    || attempt.failureCategory != CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable,
                "Committed opens must not succeed when preview classifies them as commit-time rejectable"
            );
        }

        if (
            attempt.routerOpenAllowed && attempt.prefilterActive
                && attempt.failureCategory == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable
        ) {
            assertFalse(
                attempt.commitSucceeded,
                "Predictably invalid opens must not bypass the router commit-time prefilter when router-local gates are open"
            );
        }
    }

    function invariant_LastWithdrawAttemptMatchesGuardParity() public view {
        PerpAccountingHandler.WithdrawParityAttempt memory attempt = handler.lastWithdrawParityAttemptSnapshot();
        if (!attempt.active) {
            return;
        }

        if (attempt.withdrawPasses) {
            assertTrue(
                attempt.checkWithdrawPasses,
                "Successful withdraws must only happen when checkWithdraw also passes under randomized funding/time evolution"
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

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _assertLiquidationPreviewEquals(
        CfdEngine.LiquidationPreview memory actual,
        CfdEngine.LiquidationPreview memory expected
    ) internal pure {
        assertEq(actual.liquidatable, expected.liquidatable, "Liquidatable flag should match canonical simulation");
        assertEq(actual.oraclePrice, expected.oraclePrice, "Liquidation oracle price should match");
        assertEq(actual.equityUsdc, expected.equityUsdc, "Liquidation equity should match");
        assertEq(actual.pnlUsdc, expected.pnlUsdc, "Liquidation pnl should match");
        assertEq(actual.fundingUsdc, expected.fundingUsdc, "Liquidation funding should match");
        assertEq(actual.reachableCollateralUsdc, expected.reachableCollateralUsdc, "Reachable collateral should match");
        assertEq(actual.keeperBountyUsdc, expected.keeperBountyUsdc, "Keeper bounty should match");
        assertEq(actual.seizedCollateralUsdc, expected.seizedCollateralUsdc, "Seized collateral should match");
        assertEq(actual.settlementRetainedUsdc, expected.settlementRetainedUsdc, "Settlement retained should match");
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Fresh trader payout should match");
        assertEq(
            actual.existingDeferredConsumedUsdc,
            expected.existingDeferredConsumedUsdc,
            "Deferred consumption should match"
        );
        assertEq(
            actual.existingDeferredRemainingUsdc,
            expected.existingDeferredRemainingUsdc,
            "Deferred remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Immediate payout should match");
        assertEq(actual.deferredPayoutUsdc, expected.deferredPayoutUsdc, "Deferred payout should match");
        assertEq(actual.badDebtUsdc, expected.badDebtUsdc, "Bad debt should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Post-op degraded mode should match");
        assertEq(actual.effectiveAssetsAfterUsdc, expected.effectiveAssetsAfterUsdc, "Effective assets should match");
        assertEq(actual.maxLiabilityAfterUsdc, expected.maxLiabilityAfterUsdc, "Max liability should match");
        assertEq(actual.solvencyFundingPnlUsdc, expected.solvencyFundingPnlUsdc, "Solvency funding pnl should match");
    }

}
