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

    // Independently calculated 5% annual index for one day; margin, claims and pool depth cannot reprice it.
    uint256 private constant ONE_DAY_INDEX = 136_986_301_369_863;

    function _openTraderPosition() private {
        _fundTrader(TRADER, 100_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
    }

    function test_SeededFlatClaimPaymentPreservesFlatCarry() public {
        _openTraderPosition();
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        uint256 maxProfitAssets = _sideMaxProfit(CfdTypes.Side.LONG);
        uint256 startIndex = engine.carryIndex();
        uint256 increment = ONE_DAY_INDEX;
        uint256 start = vm.getBlockTimestamp();

        vm.warp(start + 1 days);
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        assertEq(engine.carryIndex(), startIndex + increment, "claim payment preserves the flat annual rate");
        assertEq(pool.totalAssets(), assets - claim, "payment removes exactly the claim cash");
        assertEq(engine.totalTraderClaimBalanceAssets(), 0);
        assertEq(_sideMaxProfit(CfdTypes.Side.LONG), maxProfitAssets, "flat claimant cannot change position exposure");

        vm.warp(start + 2 days);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), startIndex + 2 * increment, "payment cannot reprice future carry");
    }

    function test_SeededClaimsCloseCommitmentProjectsAndCollectsFlatCarry() public {
        _openTraderPosition();
        uint256 assets = pool.totalAssets();
        _seedAuthenticatedTraderClaim(CLAIMANT, 400_000e6);
        (uint256 maxProfitAssets,,) = engine.positionCarryState(TRADER);
        assertEq(maxProfitAssets, 100_000e6, "carry basis is full maximum profit despite margin and claims");
        uint256 expectedCarry = 13_698_630;
        uint256 beforeMargin = clearinghouse.pnlPledgeAssets(TRADER);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(router));
        CfdEnginePlanTypes.CloseCommitment memory effects = engine.reserveCloseOrderExecutionBounty(TRADER, 100_000e18);
        assertEq(effects.carryCollectedAssets, expectedCarry, "claims do not change commitment carry");
        assertEq(effects.carryOutstandingAssets, 0);
        assertEq(pool.totalAssets(), assets + expectedCarry);
        assertEq(clearinghouse.pnlPledgeAssets(TRADER), beforeMargin - expectedCarry);
    }

    function test_SeededClaimsOpenPreviewProjectsFlatCarryAndMatchesExecution() public {
        _openTraderPosition();
        uint256 assets = pool.totalAssets();
        _seedAuthenticatedTraderClaim(CLAIMANT, 400_000e6);
        (uint256 maxProfitAssets,,) = engine.positionCarryState(TRADER);
        assertEq(maxProfitAssets, 100_000e6, "carry basis is full maximum profit despite margin and claims");
        uint256 expectedCarry = 13_698_630;
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 1000e18, 10_000e6, 1e8);
        assertTrue(preview.valid);
        assertEq(preview.pendingCarryAssets, expectedCarry, "preview carry is independent of claims");
        _open(TRADER, CfdTypes.Side.LONG, 1000e18, 10_000e6, 1e8);
        assertEq(clearinghouse.pnlPledgeAssets(TRADER), preview.postMarginAssets);
        assertEq(pool.totalAssets(), assets + expectedCarry + uint256(preview.vpiAssets));
    }

    function test_ClaimCreationHookCheckpointsFlatCarryBeforeIncreasingLiability() public {
        _openTraderPosition();
        uint256 assets = pool.totalAssets();
        uint256 startIndex = engine.carryIndex();
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);

        // Authorized sidecar capability test: an unavailable payout becomes a claim without transferring cash.
        vm.prank(address(engine.settlementSidecar()));
        engine.settlementRecordTraderClaim(CLAIMANT, assets + 1, false);
        uint256 oldIncrement = ONE_DAY_INDEX;
        assertEq(engine.carryIndex(), startIndex + oldIncrement, "creation checkpoints elapsed flat carry");
        assertEq(pool.totalAssets(), assets);
        assertEq(engine.totalTraderClaimBalanceAssets(), assets + 1);

        vm.warp(start + 2 days);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), startIndex + oldIncrement + ONE_DAY_INDEX);
    }

    function test_ClaimConsumptionHookCheckpointsFlatCarryBeforeReducingLiability() public {
        _openTraderPosition();
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        uint256 startIndex = engine.carryIndex();
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);

        // Authorized sidecar capability test of claim netting; no cash leaves the pool.
        vm.prank(address(engine.settlementSidecar()));
        engine.settlementConsumeTraderClaim(CLAIMANT, claim);
        uint256 oldIncrement = ONE_DAY_INDEX;
        assertEq(engine.carryIndex(), startIndex + oldIncrement, "consumption checkpoints elapsed flat carry");
        assertEq(pool.totalAssets(), assets);
        vm.warp(start + 2 days);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), startIndex + oldIncrement + ONE_DAY_INDEX);
    }

    function testFuzz_ClaimsAtOrAboveAssetsDoNotChangeFlatCarry(
        bool excess
    ) public {
        _openTraderPosition();
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        uint256 startIndex = engine.carryIndex();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), startIndex + ONE_DAY_INDEX);
        assertEq(_sideMaxProfit(CfdTypes.Side.SHORT), 0, "an empty side has no exposure to charge");
    }

    function test_SeededClaimPaymentPreservesOpenVpiAndMaximumSkewQuote() public {
        _fundTrader(TRADER, 200_000e6);
        uint256 assets = pool.totalAssets();
        uint256 claim = 400_000e6;
        _seedAuthenticatedTraderClaim(CLAIMANT, claim);
        ICfdEngineTypes.OpenPreview memory beforePreview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1e8);
        assertTrue(beforePreview.valid);
        // C(S) = k*S*S/(2*D), with exact operands chosen to avoid intermediate rounding differences.
        int256 expectedVpi = int256(uint256(100_000e6) * 100_000e6 / (200 * (assets - claim)));
        assertEq(beforePreview.vpiAssets, expectedVpi, "VPI uses LP capital net of claims");
        ICfdEngineLens.MaxOpenQuote memory beforeQuote =
            engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 100_000e6, 1e8);
        uint256 skewAssets = (assets - claim) * 4 / 10;
        uint256 expectedSize = skewAssets / 100e6 * CfdTypes.SIZE_QUANTUM;
        assertEq(beforeQuote.maxSizeDelta, expectedSize, "skew capacity uses net depth and canonical lots");
        assertEq(uint256(beforeQuote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH));

        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        ICfdEngineTypes.OpenPreview memory afterPreview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1e8);
        ICfdEngineLens.MaxOpenQuote memory afterQuote =
            engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 100_000e6, 1e8);
        assertEq(afterPreview.vpiAssets, beforePreview.vpiAssets);
        assertEq(afterQuote.maxSizeDelta, beforeQuote.maxSizeDelta);
        assertEq(keccak256(abi.encode(afterQuote.preview)), keccak256(abi.encode(beforeQuote.preview)));
        _open(TRADER, CfdTypes.Side.LONG, afterQuote.maxSizeDelta, 100_000e6, 1e8);
        assertEq(clearinghouse.pnlPledgeAssets(TRADER), afterQuote.preview.postMarginAssets, "quote/live parity");
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
        assertEq(beforePreview.vpiDeltaAssets, expectedVpi, "skew-worsening close is priced from net depth");
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        ICfdEngineTypes.ClosePreview memory afterPreview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        assertEq(afterPreview.vpiDeltaAssets, beforePreview.vpiDeltaAssets);
        uint256 settlementBefore = clearinghouse.balanceAssets(TRADER);
        _close(TRADER, CfdTypes.Side.SHORT, 100_000e18, 1e8);
        assertEq(
            clearinghouse.balanceAssets(TRADER),
            settlementBefore - uint256(expectedVpi) - afterPreview.executionFeeAssets
        );
    }

    function testFuzz_ClaimsAtOrAboveAssetsRejectOpenAndReturnZeroQuote(
        bool excess
    ) public {
        _fundTrader(TRADER, 100_000e6);
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        assertFalse(preview.valid);
        assertEq(uint256(preview.invalidReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
        ICfdEngineLens.MaxOpenQuote memory quote = engineLens.quoteMaxOpen(TRADER, CfdTypes.Side.LONG, 10_000e6, 1e8);
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
        _openTraderPosition();
        _seedAuthenticatedTraderClaim(CLAIMANT, pool.totalAssets() + (excess ? 1e6 : 0));
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, 100_000e18, 1e8);
        assertTrue(preview.valid, "protective close remains available");
        assertEq(preview.vpiDeltaAssets, 0, "zero-depth curve produces no new rebate");
        uint256 settlementBefore = clearinghouse.balanceAssets(TRADER);
        _close(TRADER, CfdTypes.Side.LONG, 100_000e18, 1e8);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0);
        assertEq(clearinghouse.balanceAssets(TRADER), settlementBefore - preview.executionFeeAssets);
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
        assertEq(preview.vpiDeltaAssets, -accrued, "zero-depth close must still recover lifetime negative VPI");
        router.executeOrder(orderId, _mockPythUpdateData());
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0, "public router close must finish");
        assertEq(clearinghouse.vpiRebateReserveAssets(TRADER), 0);
    }

    function test_CashShortfallCloseCreatesClaimAndRefillPaymentPreservesFlatCarry() public {
        _openTraderPosition();
        _fundTrader(CLAIMANT, 20_000e6);
        _open(CLAIMANT, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        // Model a physical cash shortfall; claim creation and payment themselves use production entrypoints.
        uint256 assetsBeforeLoss = pool.totalAssets();
        settlementToken.burn(address(pool), assetsBeforeLoss);
        _close(CLAIMANT, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        uint256 claim = engine.traderClaimBalanceAssets(CLAIMANT);
        assertGt(claim, 0);
        (uint256 remaining,,,,,,) = engine.positions(CLAIMANT);
        assertEq(remaining, 0, "claimant must be flat for payment invariance");
        _assertTerminalCurveAuthenticated(CLAIMANT);
        settlementToken.mint(address(pool), assetsBeforeLoss);
        uint256 depth = pool.totalAssets() - claim;
        uint256 expected = ONE_DAY_INDEX;
        uint256 startIndex = engine.carryIndex();
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);
        vm.prank(CLAIMANT);
        engine.settleTraderClaim(CLAIMANT);
        assertEq(engine.carryIndex(), startIndex + expected);
        assertEq(pool.totalAssets(), depth);
        assertEq(engine.totalTraderClaimBalanceAssets(), 0);
        _assertTerminalCurveAuthenticated(CLAIMANT);
        vm.warp(start + 2 days);
        engine.checkpointCarryIndex();
        assertEq(engine.carryIndex(), startIndex + 2 * expected);
    }

}
