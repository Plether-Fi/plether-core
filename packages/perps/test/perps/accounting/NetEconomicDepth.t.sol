// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: regression/spec. Source: ACCOUNTING_SPEC.md#lp-capital-carry.
// Authenticated seeded claims below are capability fixtures, not externally reachable claim-creation proofs.
// The cash-shortfall lifecycle case separately exercises production close and claim-payment entrypoints.

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract NetEconomicDepthTest is CfdEngineTestBase {

    address private constant TRADER = address(0xDE01);
    address private constant CLAIMANT = address(0xDE02);
    address private constant OTHER = address(0xDE03);

    function setUp() public override {
        super.setUp();
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.01e18;
        params.maxSkewRatio = 0.4e18;
        _setRiskParams(params);
    }

    // Independent arithmetic: do not use the production utilization or carry-index helper as an oracle.
    function _indexIncrement(
        uint256 borrowBase,
        uint256 depth,
        uint256 elapsed
    ) private pure returns (uint256) {
        if (borrowBase == 0) {
            return 0;
        }
        uint256 utilization = depth == 0 ? 10_000 : borrowBase * 10_000 / depth;
        if (utilization > 10_000) {
            utilization = 10_000;
        }
        return 500 * utilization * 1e18 * elapsed / (365 days * 10_000 * 10_000);
    }

    function _openBorrower() private {
        _fundTrader(TRADER, 100_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
    }

    function test_SeededFlatClaimPaymentPreservesCarryDepth() public {
        _openBorrower();
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        uint256 borrowBase = engine.sideBorrowBaseUsdc(0);
        uint256 startIndex = engine.sideCarryIndex(0);
        uint256 increment = _indexIncrement(borrowBase, assets - claim, 1 days);
        uint256 start = vm.getBlockTimestamp();

        vm.warp(start + 1 days);
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        assertEq(engine.sideCarryIndex(0), startIndex + increment, "pre-payment carry uses net depth");
        assertEq(pool.totalAssets(), assets - claim, "payment removes exactly the claim cash");
        assertEq(engine.totalTraderClaimBalanceUsdc(), 0);
        assertEq(engine.sideBorrowBaseUsdc(0), borrowBase, "flat claimant cannot change borrower collateral");

        vm.warp(start + 2 days);
        engine.checkpointCarryIndexes();
        assertEq(engine.sideCarryIndex(0), startIndex + 2 * increment, "payment cannot reprice future carry");
    }

    function test_SeededClaimsCloseCommitmentProjectsAndCollectsNetDepthCarry() public {
        _openBorrower();
        uint256 assets = pool.totalAssets();
        _seedAuthenticatedTraderClaim(CLAIMANT, 400_000e6);
        (uint256 borrowBase,,) = engine.positionCarryState(TRADER);
        uint256 expectedCarry = borrowBase * _indexIncrement(borrowBase, assets - 400_000e6, 1 days) / 1e18;
        uint256 beforeMargin = clearinghouse.pnlPledgeUsdc(TRADER);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(router));
        CfdEnginePlanTypes.CloseCommitment memory effects =
            engine.reserveCloseOrderExecutionBounty(TRADER, 100_000e18, 0);
        assertEq(effects.carryCollectedUsdc, expectedCarry, "commitment snapshot includes aggregate claims");
        assertEq(effects.carryOutstandingUsdc, 0);
        assertEq(pool.totalAssets(), assets + expectedCarry);
        assertEq(clearinghouse.pnlPledgeUsdc(TRADER), beforeMargin - expectedCarry);
    }

    function test_SeededClaimsOpenPreviewProjectsNetCarryAndMatchesExecution() public {
        _openBorrower();
        uint256 assets = pool.totalAssets();
        _seedAuthenticatedTraderClaim(CLAIMANT, 400_000e6);
        (uint256 borrowBase,,) = engine.positionCarryState(TRADER);
        uint256 expectedCarry = borrowBase * _indexIncrement(borrowBase, assets - 400_000e6, 1 days) / 1e18;
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 1000e18, 10_000e6, 1e8, uint64(block.timestamp));
        assertTrue(preview.valid);
        assertEq(preview.pendingCarryUsdc, expectedCarry, "preview carry uses actual cash net of claims");
        _open(TRADER, CfdTypes.Side.LONG, 1000e18, 10_000e6, 1e8);
        assertEq(clearinghouse.pnlPledgeUsdc(TRADER), preview.postMarginUsdc);
        assertEq(pool.totalAssets(), assets + expectedCarry + uint256(preview.vpiUsdc));
    }

    function test_ClaimCreationHookCheckpointsOldDepthBeforeIncreasingLiability() public {
        _openBorrower();
        uint256 assets = pool.totalAssets();
        uint256 borrowBase = engine.sideBorrowBaseUsdc(0);
        uint256 startIndex = engine.sideCarryIndex(0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);

        // Authorized sidecar capability test: an unavailable payout becomes a claim without transferring cash.
        vm.prank(address(engine.settlementSidecar()));
        engine.settlementRecordTraderClaim(CLAIMANT, assets + 1, false);
        uint256 oldIncrement = _indexIncrement(borrowBase, assets, 1 days);
        assertEq(engine.sideCarryIndex(0), startIndex + oldIncrement, "creation checkpoints the old denominator");
        assertEq(pool.totalAssets(), assets);
        assertEq(engine.totalTraderClaimBalanceUsdc(), assets + 1);

        vm.warp(start + 2 days);
        engine.checkpointCarryIndexes();
        assertEq(engine.sideCarryIndex(0), startIndex + oldIncrement + _indexIncrement(borrowBase, 0, 1 days));
    }

    function test_ClaimConsumptionHookCheckpointsOldDepthBeforeReducingLiability() public {
        _openBorrower();
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        uint256 borrowBase = engine.sideBorrowBaseUsdc(0);
        uint256 startIndex = engine.sideCarryIndex(0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);

        // Authorized sidecar capability test of claim netting; no cash leaves the pool.
        vm.prank(address(engine.settlementSidecar()));
        engine.settlementConsumeTraderClaim(CLAIMANT, claim);
        uint256 oldIncrement = _indexIncrement(borrowBase, assets - claim, 1 days);
        assertEq(engine.sideCarryIndex(0), startIndex + oldIncrement, "consumption checkpoints old net depth");
        assertEq(pool.totalAssets(), assets);
        vm.warp(start + 2 days);
        engine.checkpointCarryIndexes();
        assertEq(engine.sideCarryIndex(0), startIndex + oldIncrement + _indexIncrement(borrowBase, assets, 1 days));
    }

    function testFuzz_ClaimsAtOrAboveAssetsCapCarryAndLeaveEmptySideIdle(
        bool excess
    ) public {
        _openBorrower();
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        uint256 startIndex = engine.sideCarryIndex(0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        engine.checkpointCarryIndexes();
        assertEq(engine.sideCarryIndex(0), startIndex + _indexIncrement(engine.sideBorrowBaseUsdc(0), 0, 1 days));
        assertEq(engine.sideCarryIndex(1), 0, "zero borrowing never accrues carry, even at zero net depth");
    }

    function test_SeededClaimPaymentPreservesOpenVpiAndMaximumSkewQuote() public {
        _fundTrader(TRADER, 200_000e6);
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        ICfdEngineTypes.OpenPreview memory beforePreview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1e8, uint64(block.timestamp));
        assertTrue(beforePreview.valid);
        // C(S) = k*S*S/(2*D), with exact operands chosen to avoid intermediate rounding differences.
        int256 expectedVpi = int256(uint256(100_000e6) * 100_000e6 / (200 * (assets - claim)));
        assertEq(beforePreview.vpiUsdc, expectedVpi, "VPI uses LP capital net of claims");
        ICfdEngineLens.MaxOpenQuote memory beforeQuote =
            engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 100_000e6, 1e8, uint64(block.timestamp));
        uint256 skewUsdc = (assets - claim) * 4 / 10;
        uint256 expectedSize = skewUsdc / 100e6 * CfdTypes.SIZE_QUANTUM;
        assertEq(beforeQuote.maxSizeDelta, expectedSize, "skew capacity uses net depth and canonical lots");
        assertEq(uint256(beforeQuote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH));

        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        ICfdEngineTypes.OpenPreview memory afterPreview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1e8, uint64(block.timestamp));
        ICfdEngineLens.MaxOpenQuote memory afterQuote =
            engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 100_000e6, 1e8, uint64(block.timestamp));
        assertEq(afterPreview.vpiUsdc, beforePreview.vpiUsdc);
        assertEq(afterQuote.maxSizeDelta, beforeQuote.maxSizeDelta);
        assertEq(keccak256(abi.encode(afterQuote.preview)), keccak256(abi.encode(beforeQuote.preview)));
        _open(TRADER, CfdTypes.Side.LONG, afterQuote.maxSizeDelta, 100_000e6, 1e8);
        assertEq(clearinghouse.pnlPledgeUsdc(TRADER), afterQuote.preview.postMarginUsdc, "quote/live parity");
    }

    function test_SeededClaimPaymentPreservesCloseVpi() public {
        _fundTrader(OTHER, 50_000e6);
        _fundTrader(TRADER, 50_000e6);
        _open(OTHER, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 1e8);
        _open(TRADER, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);
        uint256 depth = pool.totalAssets() - 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, 400_000e6);
        ICfdEngineTypes.ClosePreview memory beforePreview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        int256 expectedVpi = int256(uint256(200_000e6) * 200_000e6 / (200 * depth))
            - int256(uint256(100_000e6) * 100_000e6 / (200 * depth));
        assertEq(beforePreview.vpiDeltaUsdc, expectedVpi, "skew-worsening close is priced from net depth");
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        ICfdEngineTypes.ClosePreview memory afterPreview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        assertEq(afterPreview.vpiDeltaUsdc, beforePreview.vpiDeltaUsdc);
        uint256 settlementBefore = clearinghouse.balanceUsdc(TRADER);
        _close(TRADER, CfdTypes.Side.SHORT, 100_000e18, 1e8);
        assertEq(
            clearinghouse.balanceUsdc(TRADER), settlementBefore - uint256(expectedVpi) - afterPreview.executionFeeUsdc
        );
    }

    function testFuzz_ClaimsAtOrAboveAssetsRejectOpenAndReturnZeroQuote(
        bool excess
    ) public {
        _fundTrader(TRADER, 100_000e6);
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, uint64(block.timestamp));
        assertFalse(preview.valid);
        assertEq(uint256(preview.invalidReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
        ICfdEngineLens.MaxOpenQuote memory quote =
            engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 10_000e6, 1e8, uint64(block.timestamp));
        assertEq(quote.maxSizeDelta, 0);
        assertEq(uint256(quote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
        uint256 grossDepth = pool.totalAssets();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
                false
            )
        );
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, grossDepth);
    }

    function testFuzz_ZeroNetDepthCloseDoesNotPayFreshVpiRebate(
        bool excess
    ) public {
        _openBorrower();
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        assertTrue(preview.valid, "protective close remains available");
        assertEq(preview.vpiDeltaUsdc, 0, "zero-depth curve produces no new rebate");
        uint256 settlementBefore = clearinghouse.balanceUsdc(TRADER);
        _close(TRADER, CfdTypes.Side.LONG, 100_000e18, 1e8);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0);
        assertEq(clearinghouse.balanceUsdc(TRADER), settlementBefore - preview.executionFeeUsdc);
    }

    function test_ZeroNetDepthRouterClosePreservesLifetimeRebateClawback() public {
        _fundTrader(OTHER, 50_000e6);
        _fundTrader(TRADER, 50_000e6);
        _open(OTHER, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 1e8);
        _open(TRADER, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);
        (,,,,,, int256 accrued) = engine.positions(TRADER);
        assertLt(accrued, 0, "fixture must include an outstanding lifetime rebate");
        vm.prank(TRADER);
        uint64 orderId = router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 0, 0, true);
        // Excess liabilities keep depth zero even after the tiny carry inflow collected on execution.
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + 1_000_000e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(block.number + 1);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        assertTrue(preview.valid);
        assertEq(preview.vpiDeltaUsdc, -accrued, "zero-depth close must still recover lifetime negative VPI");
        router.executeOrder(orderId, _mockPythUpdateData());
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0, "public router close must finish");
        assertEq(clearinghouse.vpiRebateReserveUsdc(TRADER), 0);
    }

    function test_CashShortfallCloseCreatesClaimAndRefillPaymentPreservesCarryDepth() public {
        _openBorrower();
        _fundTrader(CLAIMANT, 20_000e6);
        _open(CLAIMANT, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        // Model a physical cash shortfall; claim creation and payment themselves use production entrypoints.
        uint256 assetsBeforeLoss = pool.totalAssets();
        usdc.burn(address(pool), assetsBeforeLoss);
        _close(CLAIMANT, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        uint256 claim = engine.traderClaimBalanceUsdc(CLAIMANT);
        assertGt(claim, 0);
        (uint256 remaining,,,,,,) = engine.positions(CLAIMANT);
        assertEq(remaining, 0, "claimant must be flat for payment invariance");
        _assertTerminalCurveAuthenticated(CLAIMANT);
        usdc.mint(address(pool), assetsBeforeLoss);
        uint256 depth = pool.totalAssets() - claim;
        uint256 expected = _indexIncrement(engine.sideBorrowBaseUsdc(0), depth, 1 days);
        uint256 startIndex = engine.sideCarryIndex(0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        assertEq(engine.sideCarryIndex(0), startIndex + expected);
        assertEq(pool.totalAssets(), depth);
        assertEq(engine.totalTraderClaimBalanceUsdc(), 0);
        _assertTerminalCurveAuthenticated(CLAIMANT);
        vm.warp(start + 2 days);
        engine.checkpointCarryIndexes();
        assertEq(engine.sideCarryIndex(0), startIndex + 2 * expected);
    }

}
