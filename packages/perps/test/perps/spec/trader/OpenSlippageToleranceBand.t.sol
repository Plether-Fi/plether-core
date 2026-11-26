// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @notice Open/increase commits honor `minOpenSlippageToleranceBps` across targetPrice, V3 bounds, and planner margin.
contract OpenSlippageToleranceBandTest is SourceBoundBountyFixture {

    uint256 private constant TOLERANCE_BPS = 25;
    uint256 private constant FUNDING = 10_000e6;

    function setUp() public override {
        super.setUp();
        _fundTrader(BOUNTY_TRADER, FUNDING);
    }

    function _setToleranceBps(
        uint256 toleranceBps,
        bool refreshMark
    ) private {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.minOpenSlippageToleranceBps = toleranceBps;
        engineAdmin.proposeRiskConfig(config);
        vm.warp(block.timestamp + 72 hours + 1);
        engineAdmin.finalizeRiskConfig();
        if (refreshMark) {
            router.updateMarkPrice(_mockPythUpdateData(BOUNTY_PRICE));
        }
    }

    function _setToleranceBps(
        uint256 toleranceBps
    ) private {
        _setToleranceBps(toleranceBps, true);
    }

    function _openRequest(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) private view returns (OrderV3Types.OrderRequest memory r) {
        r = _bountyRequest(side, false, sizeDelta, marginDelta);
        r.targetPrice = targetPrice;
    }

    function _bandEdges(
        uint256 commitPrice,
        uint256 toleranceBps
    ) private view returns (uint256 lowPrice, uint256 highPrice) {
        lowPrice = Math.mulDiv(commitPrice, 10_000 - toleranceBps, 10_000, Math.Rounding.Floor);
        if (lowPrice == 0) {
            lowPrice = 1;
        }
        highPrice = Math.mulDiv(commitPrice, 10_000 + toleranceBps, 10_000, Math.Rounding.Ceil);
        uint256 capPrice = engine.CAP_PRICE();
        if (highPrice > capPrice) {
            highPrice = capPrice;
        }
    }

    function _exactMinMarginForPrice(
        uint256 sizeDelta,
        uint256 price,
        int256 vpiAssets
    ) private view returns (uint256) {
        CfdTypes.RiskParams memory risk = _engineRiskConfig().riskParams;
        uint256 notional = (sizeDelta / CfdTypes.SIZE_QUANTUM) * price;
        uint256 fee = (notional * engine.executionFeeBps()) / 10_000;
        uint256 cost = fee + (vpiAssets > 0 ? uint256(vpiAssets) : 0);
        uint256 reserve = Math.max((notional * risk.bountyBps) / 10_000, risk.minBountyAssets);
        uint256 initReq = Math.max((notional * risk.initMarginBps) / 10_000, risk.minBountyAssets);
        // `OpenOrderFundingLib.validate` requires `equityAssets > initialRequirementAssets`.
        return cost + reserve + initReq + 1;
    }

    function test_GovernanceConfigValidatesBoundsAndAdvancesVersion() public {
        assertEq(engine.minOpenSlippageToleranceBps(), 0);

        ICfdEngineAdminHost.EngineRiskConfig memory bad = _engineRiskConfig();
        bad.minOpenSlippageToleranceBps = engineAdmin.MAX_MIN_OPEN_SLIPPAGE_TOLERANCE_BPS() + 1;
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(bad);

        uint64 versionBefore = engineAdmin.activeConfigVersion();
        _setToleranceBps(engineAdmin.MAX_MIN_OPEN_SLIPPAGE_TOLERANCE_BPS(), false);
        assertEq(engine.minOpenSlippageToleranceBps(), 500);
        assertEq(engineAdmin.activeConfigVersion(), versionBefore + 1);

        _setToleranceBps(0, false);
        assertEq(engine.minOpenSlippageToleranceBps(), 0);
    }

    function test_DirectionalTargetPriceEnforcedForLongAndShort() public {
        _setToleranceBps(TOLERANCE_BPS);
        (uint256 lowPrice, uint256 highPrice) = _bandEdges(BOUNTY_PRICE, TOLERANCE_BPS);

        // Open LONG requires targetPrice <= lowPrice.
        OrderV3Types.OrderRequest memory tightLong = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__SlippageToleranceTooTight.selector,
                lowPrice + 1,
                lowPrice
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(tightLong);

        OrderV3Types.OrderRequest memory validLong = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        vm.prank(BOUNTY_TRADER);
        uint64 longId = router.commitOrder(validLong);
        vm.warp(block.timestamp + 2);
        vm.prank(BOUNTY_KEEPER);
        OrderV3Types.ExecutionResult memory longRes = router.executeOrder(longId, _mockPythUpdateData(lowPrice));
        assertEq(uint8(longRes.status), uint8(OrderV3Types.LifecycleStatus.Executed));

        // Reset mark back to BOUNTY_PRICE and test SHORT on a separate account.
        address shortTrader = address(0x54087);
        _fundTrader(shortTrader, FUNDING);
        router.updateMarkPrice(_mockPythUpdateData(BOUNTY_PRICE));

        OrderV3Types.OrderRequest memory tightShort =
            _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__SlippageToleranceTooTight.selector,
                highPrice - 1,
                highPrice
            )
        );
        vm.prank(shortTrader);
        router.commitOrder(tightShort);

        OrderV3Types.OrderRequest memory validShort = _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice);
        vm.prank(shortTrader);
        uint64 shortId = router.commitOrder(validShort);
        vm.warp(block.timestamp + 2);
        vm.prank(BOUNTY_KEEPER);
        OrderV3Types.ExecutionResult memory shortRes = router.executeOrder(shortId, _mockPythUpdateData(highPrice));
        assertEq(uint8(shortRes.status), uint8(OrderV3Types.LifecycleStatus.Executed));
    }

    function test_BandRejectsEveryTightV3BoundAndPlannerMarginHeadroom() public {
        _setToleranceBps(TOLERANCE_BPS);
        (uint256 lowPrice, uint256 highPrice) = _bandEdges(BOUNTY_PRICE, TOLERANCE_BPS);

        _assertNotionalAndFeeBounds(lowPrice, highPrice);
        _assertChargeDebitAndSettlementBalanceBounds(lowPrice, highPrice);
        _assertEquityLeverageAndModeBounds(lowPrice);
        _assertPlannerMarginHeadroom(lowPrice, highPrice);
    }

    function _assertNotionalAndFeeBounds(
        uint256 lowPrice,
        uint256 highPrice
    ) private {
        uint256 lots = BOUNTY_SIZE / CfdTypes.SIZE_QUANTUM;
        uint256 commitNotional = lots * BOUNTY_PRICE;
        uint256 highNotional = lots * highPrice;
        uint256 commitFee = (commitNotional * engine.executionFeeBps()) / 10_000;
        uint256 highFee = (highNotional * engine.executionFeeBps()) / 10_000;
        assertGt(highNotional, commitNotional);
        assertGt(highFee, commitFee);

        // 1. Tight maxExecutionNotionalAssets passes at commitPrice, fails at highPrice.
        OrderV3Types.OrderRequest memory r = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        r.bounds.maxExecutionNotionalAssets = commitNotional;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExecutionNotional,
                highNotional,
                commitNotional
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(r);

        // 2. Tight maxExplicitFeesAssets passes at commitPrice, fails at highPrice.
        OrderV3Types.OrderRequest memory rFee = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rFee.bounds.maxExplicitFeesAssets = commitFee;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExplicitFees,
                highFee,
                commitFee
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rFee);
    }

    function _assertChargeDebitAndSettlementBalanceBounds(
        uint256 lowPrice,
        uint256 highPrice
    ) private {
        uint256 commitActionCharge = _actionChargeAt(BOUNTY_PRICE);
        uint256 highActionCharge = _actionChargeAt(highPrice);
        assertGt(highActionCharge, commitActionCharge);

        // 3. Tight maxActionChargeAssets passes at commitPrice, fails at highPrice.
        OrderV3Types.OrderRequest memory r = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        r.bounds.maxActionChargeAssets = commitActionCharge;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ActionCharge,
                highActionCharge,
                commitActionCharge
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(r);

        // 4. Tight maxGrossAccountDebitAssets passes at commitPrice, fails at highPrice.
        uint256 bounty = _expectedOpenBounty(BOUNTY_SIZE, BOUNTY_PRICE);
        OrderV3Types.OrderRequest memory rDebit = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rDebit.bounds.maxGrossAccountDebitAssets = commitActionCharge + bounty;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.GrossAccountDebit,
                highActionCharge + bounty,
                commitActionCharge + bounty
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rDebit);

        // 5. Tight minPostSettlementBalanceAssets passes at commitPrice, fails at highPrice.
        uint256 commitPostBal = FUNDING - commitActionCharge - bounty;
        uint256 highPostBal = FUNDING - highActionCharge - bounty;
        assertLt(highPostBal, commitPostBal);

        OrderV3Types.OrderRequest memory rBal = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rBal.bounds.minPostSettlementBalanceAssets = commitPostBal;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostSettlementBalance,
                highPostBal,
                commitPostBal
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rBal);
    }

    function _assertEquityLeverageAndModeBounds(
        uint256 lowPrice
    ) private {
        CfdTypes.RiskParams memory risk = _engineRiskConfig().riskParams;
        uint256 commitNotional = (BOUNTY_SIZE / CfdTypes.SIZE_QUANTUM) * BOUNTY_PRICE;
        uint256 commitCost = _actionChargeAt(BOUNTY_PRICE);
        uint256 commitReserve = Math.max((commitNotional * risk.bountyBps) / 10_000, risk.minBountyAssets);
        uint256 commitEquity = 250e6 - commitCost - commitReserve;
        uint256 commitLev = Math.mulDiv(commitNotional, 10_000, commitEquity, Math.Rounding.Ceil);

        // 6. Tight minPostPositionEquityAssets and maxPostLeverageBps pass at commitPrice, fail at highPrice.
        OrderV3Types.OrderRequest memory rEq = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rEq.bounds.minPostPositionEquityAssets = commitEquity;
        vm.expectRevert();
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rEq);

        OrderV3Types.OrderRequest memory rLev = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rLev.bounds.maxPostLeverageBps = uint32(commitLev);
        vm.expectRevert();
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rLev);

        // 7. Disallowing Live mode on open fails at commit.
        OrderV3Types.OrderRequest memory rMode = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, lowPrice);
        rMode.bounds.allowedExecutionModes = 2; // FAD only, no Live bit
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ImpossibleExecutionRequest.selector);
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rMode);
    }

    function _assertPlannerMarginHeadroom(
        uint256 lowPrice,
        uint256 highPrice
    ) private {
        // 8. Planner margin headroom: 1-wei margin above commitPrice minimum fails at highPrice.
        ICfdEngineTypes.OpenPreview memory commitPreview =
            engineLens.previewOpen(BOUNTY_TRADER, CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, BOUNTY_PRICE);
        uint256 tightMargin = _exactMinMarginForPrice(BOUNTY_SIZE, BOUNTY_PRICE, commitPreview.vpiAssets);

        OrderV3Types.OrderRequest memory rThin = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, tightMargin, lowPrice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(rThin);

        // Funding for highPrice passes and executes at highPrice.
        ICfdEngineTypes.OpenPreview memory highPreview =
            engineLens.previewOpen(BOUNTY_TRADER, CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, highPrice);
        uint256 bandMargin = _exactMinMarginForPrice(BOUNTY_SIZE, highPrice, highPreview.vpiAssets);
        assertGt(bandMargin, tightMargin);

        OrderV3Types.OrderRequest memory rBand = _openRequest(CfdTypes.Side.LONG, BOUNTY_SIZE, bandMargin, lowPrice);
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(rBand);
        vm.warp(block.timestamp + 2);
        vm.prank(BOUNTY_KEEPER);
        OrderV3Types.ExecutionResult memory res = router.executeOrder(id, _mockPythUpdateData(highPrice));
        assertEq(uint8(res.status), uint8(OrderV3Types.LifecycleStatus.Executed));
    }

    function _actionChargeAt(
        uint256 price
    ) private view returns (uint256) {
        uint256 notional = (BOUNTY_SIZE / CfdTypes.SIZE_QUANTUM) * price;
        uint256 fee = (notional * engine.executionFeeBps()) / 10_000;
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(BOUNTY_TRADER, CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, price);
        int256 tradeCost = int256(fee) + preview.vpiAssets;
        return tradeCost > 0 ? uint256(tradeCost) : 0;
    }

    function _expectedOpenBounty(
        uint256 sizeDelta,
        uint256 commitPrice
    ) private view returns (uint256 bounty) {
        uint256 notional = (sizeDelta / CfdTypes.SIZE_QUANTUM) * commitPrice;
        bounty = (notional * router.openOrderExecutionBountyBps()) / 10_000;
        uint256 minBounty = router.minOpenOrderExecutionBountyAssets();
        if (bounty < minBounty) {
            bounty = minBounty;
        }
        uint256 maxBounty = router.maxOpenOrderExecutionBountyAssets();
        if (bounty > maxBounty) {
            bounty = maxBounty;
        }
    }

    function test_ShortIncreaseChecksLowPriceAdversePnlAndStaleMarkDoesNotBypass() public {
        // Open a SHORT position while tolerance is disabled so entry is at BOUNTY_PRICE.
        _open(BOUNTY_TRADER, CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, BOUNTY_PRICE);
        _setToleranceBps(TOLERANCE_BPS);
        (uint256 lowPrice, uint256 highPrice) = _bandEdges(BOUNTY_PRICE, TOLERANCE_BPS);

        // At commitPrice, post-position equity of the combined SHORT is higher than at lowPrice (where SHORT loses).
        OrderV3Types.OrderRequest memory inc = _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice);
        CfdTypes.Order memory simOrder = CfdTypes.Order({
            account: BOUNTY_TRADER,
            sizeDelta: BOUNTY_SIZE,
            marginDelta: 250e6,
            targetPrice: highPrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        uint256 poolDepth = pool.totalAssets();
        OrderV3Types.ExecutionAssessment memory atCommit = policyEvaluator.assessOrder(
            address(engine), simOrder, address(0), BOUNTY_PRICE, poolDepth, inc.bounds, 200_000
        );
        OrderV3Types.ExecutionAssessment memory atLow = policyEvaluator.assessOrder(
            address(engine), simOrder, address(0), lowPrice, poolDepth, inc.bounds, 200_000
        );
        assertGt(atLow.postLeverageBps, atCommit.postLeverageBps);

        // Pinning maxPostLeverageBps to commit-price leverage passes standalone funding and commitPrice,
        // but reverts due to lowPrice adverse PnL on the existing SHORT position.
        inc.bounds.maxPostLeverageBps = uint32(atCommit.postLeverageBps);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostLeverage,
                atLow.postLeverageBps,
                atCommit.postLeverageBps
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(inc);

        // Letting cached mark go stale does NOT bypass the tolerance band.
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30);
        OrderV3Types.OrderRequest memory staleTight =
            _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__SlippageToleranceTooTight.selector,
                highPrice - 1,
                highPrice
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(staleTight);

        // Closes are unaffected by minOpenSlippageToleranceBps.
        OrderV3Types.OrderRequest memory closeReq = _bountyRequest(CfdTypes.Side.SHORT, true, BOUNTY_SIZE, 0);
        closeReq.targetPrice = BOUNTY_PRICE;
        vm.prank(BOUNTY_TRADER);
        uint64 closeId = router.commitOrder(closeReq);
        assertGt(closeId, 0);
    }

    function test_QueuedFlipEnforcesTargetPriceBoundsAndMarginHeadroom() public {
        _open(BOUNTY_TRADER, CfdTypes.Side.LONG, BOUNTY_SIZE, 250e6, BOUNTY_PRICE);
        _setToleranceBps(TOLERANCE_BPS);
        (, uint256 highPrice) = _bandEdges(BOUNTY_PRICE, TOLERANCE_BPS);

        // Queue full close LONG first so the opposing SHORT open enters the queued-flip branch.
        OrderV3Types.OrderRequest memory closeReq = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(closeReq);

        // Tight targetPrice on queued flip SHORT reverts.
        OrderV3Types.OrderRequest memory tightFlip =
            _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__SlippageToleranceTooTight.selector,
                highPrice - 1,
                highPrice
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(tightFlip);

        // Tight maxExecutionNotionalAssets on queued flip reverts.
        uint256 lots = BOUNTY_SIZE / CfdTypes.SIZE_QUANTUM;
        uint256 commitNotional = lots * BOUNTY_PRICE;
        uint256 highNotional = lots * highPrice;
        OrderV3Types.OrderRequest memory tightNotionalFlip =
            _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice);
        tightNotionalFlip.bounds.maxExecutionNotionalAssets = commitNotional;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExecutionNotional,
                highNotional,
                commitNotional
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(tightNotionalFlip);

        // Thin margin on queued flip reverts at highPrice.
        uint256 thinMargin = _exactMinMarginForPrice(BOUNTY_SIZE, BOUNTY_PRICE, 0);
        OrderV3Types.OrderRequest memory thinFlip =
            _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, thinMargin, highPrice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
            )
        );
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(thinFlip);

        // Properly headromed queued flip commits cleanly.
        OrderV3Types.OrderRequest memory validFlip = _openRequest(CfdTypes.Side.SHORT, BOUNTY_SIZE, 250e6, highPrice);
        vm.prank(BOUNTY_TRADER);
        uint64 flipId = router.commitOrder(validFlip);
        assertGt(flipId, 0);
    }

}
