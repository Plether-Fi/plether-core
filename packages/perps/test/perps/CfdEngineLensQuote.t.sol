// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEngineOpenQuoter} from "@plether/perps/CfdEngineOpenQuoter.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

contract CfdEngineLensQuoteTest is BasePerpTest {

    function test_Runtime_QuoteComponentsFitDeploymentLimits() public {
        CfdEngineOpenQuoter quoter = new CfdEngineOpenQuoter();
        assertLe(address(engineLens).code.length, 24_576, "lens runtime exceeds EIP-170");
        assertLe(address(quoter).code.length, 24_576, "quoter runtime exceeds EIP-170");
        assertLe(
            type(CfdEngineLens).creationCode.length + abi.encode(address(engine)).length,
            49_152,
            "lens creation input exceeds EIP-3860"
        );
        assertLe(type(CfdEngineOpenQuoter).creationCode.length, 49_152, "quoter initcode exceeds EIP-3860");
    }

    function _quote(
        address account,
        CfdTypes.Side side,
        uint256 marginDelta,
        uint256 price
    ) private view returns (ICfdEngineLens.MaxOpenQuote memory quote) {
        quote = ICfdEngineLens(address(engineLens))
            .quoteMaxOpen(account, side, marginDelta, price, uint64(block.timestamp));
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(account, side, quote.preview.sizeDelta, marginDelta, price, uint64(block.timestamp));
        assertEq(keccak256(abi.encode(quote.preview)), keccak256(abi.encode(preview)), "complete preview parity");
        assertEq(quote.maxSizeDelta % CfdTypes.SIZE_QUANTUM, 0, "quantum alignment");
        if (quote.maxSizeDelta == 0) {
            assertFalse(quote.preview.valid, "zero capacity must include a rejection");
            assertEq(uint256(quote.limitingReason), uint256(preview.invalidReason));
        } else {
            assertTrue(quote.preview.valid, "maximum is valid");
            assertEq(quote.preview.sizeDelta, quote.maxSizeDelta);
            ICfdEngineTypes.OpenPreview memory next = engineLens.previewOpen(
                account, side, quote.maxSizeDelta + CfdTypes.SIZE_QUANTUM, marginDelta, price, uint64(block.timestamp)
            );
            assertFalse(next.valid, "next quantum is invalid");
            assertEq(uint256(quote.limitingReason), uint256(next.invalidReason));
        }
    }

    function test_QuoteMaxOpen_ReturnsLargestPlannerValidQuantum() public {
        address account = address(0xA11CE);
        _fundTrader(account, 10_000e6);
        uint256 beforeGas = gasleft();
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.LONG, 10_000e6, 1e8);
        emit log_named_uint("quote and parity checks gas", beforeGas - gasleft());
        assertGt(quote.maxSizeDelta, 0);
        _open(account, CfdTypes.Side.LONG, quote.maxSizeDelta, 10_000e6, 1e8);
    }

    function test_QuoteMaxOpen_IsAvailableThroughInterface() public view {
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(address(this), CfdTypes.Side.SHORT, 0, 1e8);
        assertEq(quote.maxSizeDelta, 0);
    }

    function test_QuoteMaxOpen_ReturnsZeroForOpposingPosition() public {
        address account = address(0xB0B);
        _fundTrader(account, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.SHORT, 5000e6, 1e8);
        assertEq(quote.maxSizeDelta, 0);
        assertEq(uint256(quote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING));
    }

    function test_QuoteMaxOpen_QuotesSameSideIncrease() public {
        address account = address(0xBEEF);
        _fundTrader(account, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.LONG, 5000e6, 1e8);
        assertGt(quote.maxSizeDelta, 0);
        _open(account, CfdTypes.Side.LONG, quote.maxSizeDelta, 5000e6, 1e8);
    }

    function test_QuoteMaxOpen_ReturnsZeroForZeroPrice() public {
        address account = address(0xCAFE);
        _fundTrader(account, 10_000e6);
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.LONG, 10_000e6, 0);
        assertEq(quote.maxSizeDelta, 0);
        assertEq(uint256(quote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL));
    }

    function test_QuoteMaxOpen_SearchesPastInvalidVpiSolvencyRegion() public {
        address maker = address(0x1234);
        address taker = address(0x5678);
        _fundTrader(maker, 30_000e6);
        _open(maker, CfdTypes.Side.LONG, 400_000e18, 20_000e6, 1e8);
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 10e18;
        _setRiskParams(params);
        _fundTrader(taker, 13_000e6);
        ICfdEngineTypes.OpenPreview memory middle =
            engineLens.previewOpen(taker, CfdTypes.Side.SHORT, 400_000e18, 13_000e6, 1e8, uint64(block.timestamp));
        assertEq(uint256(middle.invalidReason), uint256(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
        assertTrue(
            engineLens.previewOpen(taker, CfdTypes.Side.SHORT, 790_000e18, 13_000e6, 1e8, uint64(block.timestamp)).valid
        );
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(taker, CfdTypes.Side.SHORT, 13_000e6, 1e8);
        assertGe(quote.maxSizeDelta, 790_000e18, "must include the later valid range");
        _open(taker, CfdTypes.Side.SHORT, quote.maxSizeDelta, 13_000e6, 1e8);
    }

    function test_QuoteMaxOpen_InvalidMinimumDoesNotImplyZeroCapacity() public {
        address maker = address(0x1234);
        address taker = address(0x5678);
        _fundTrader(maker, 30_000e6);
        _open(maker, CfdTypes.Side.LONG, 400_000e18, 20_000e6, 1e8);
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.1e18;
        _setRiskParams(params);
        _fundTrader(taker, 10_000e6);
        // Larger healing rebates make the hypothetical pledge affordable; the smallest admissible order cannot.
        assertFalse(
            engineLens.previewOpen(taker, CfdTypes.Side.SHORT, 1000e18, 11_000e6, 1e8, uint64(block.timestamp)).valid
        );
        assertTrue(
            engineLens.previewOpen(taker, CfdTypes.Side.SHORT, 100_000e18, 11_000e6, 1e8, uint64(block.timestamp)).valid
        );
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(taker, CfdTypes.Side.SHORT, 11_000e6, 1e8);
        assertGe(quote.maxSizeDelta, 100_000e18);
        _open(taker, CfdTypes.Side.SHORT, quote.maxSizeDelta, 11_000e6, 1e8);
    }

    function test_QuoteMaxOpen_SkewBoundIncludesCollectedCarry() public {
        address account = address(0xABC);
        _fundTrader(account, 100_000e6);
        _open(account, CfdTypes.Side.LONG, 400_000e18, 30_000e6, 1e8);
        vm.warp(block.timestamp + 28 days);
        uint256 beforeDepth = pool.totalAssets();
        uint256 beforeMargin = clearinghouse.pnlPledgeUsdc(account);
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.LONG, 20_000e6, 1e8);
        assertEq(quote.maxSizeDelta, 1000e18, "old pre-carry cap was only 800 tokens");
        assertGt(quote.preview.pendingCarryUsdc, 0);
        assertEq(pool.totalAssets(), beforeDepth, "view must not collect carry");
        assertEq(clearinghouse.pnlPledgeUsdc(account), beforeMargin);
        _open(account, CfdTypes.Side.LONG, quote.maxSizeDelta, 20_000e6, 1e8);
        assertEq(clearinghouse.pnlPledgeUsdc(account), quote.preview.postMarginUsdc);
    }

    function test_QuoteMaxOpen_ClampsPrice() public {
        address account = address(0xCAFE);
        _fundTrader(account, 10_000e6);
        ICfdEngineLens.MaxOpenQuote memory capped = _quote(account, CfdTypes.Side.SHORT, 10_000e6, CAP_PRICE);
        ICfdEngineLens.MaxOpenQuote memory above = _quote(account, CfdTypes.Side.SHORT, 10_000e6, CAP_PRICE + 1e8);
        assertEq(keccak256(abi.encode(capped)), keccak256(abi.encode(above)));
    }

    function test_QuoteMaxOpen_ExistingRebateReserveCanBeReleased() public {
        address maker = address(0xAB01);
        address taker = address(0xAB02);
        _fundTrader(maker, 30_000e6);
        _open(maker, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 1e8);
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.001e18;
        _setRiskParams(params);
        _fundTrader(taker, 30_000e6);
        _open(taker, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);
        uint256 reserveBefore = clearinghouse.vpiRebateReserveUsdc(taker);
        assertGt(reserveBefore, 0);
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(taker, CfdTypes.Side.SHORT, 5000e6, 1e8);
        assertGt(quote.maxSizeDelta, 0);
        assertEq(clearinghouse.vpiRebateReserveUsdc(taker), reserveBefore, "quote must not release backing");
        _open(taker, CfdTypes.Side.SHORT, quote.maxSizeDelta, 5000e6, 1e8);
        assertLt(clearinghouse.vpiRebateReserveUsdc(taker), reserveBefore);
        assertEq(clearinghouse.pnlPledgeUsdc(taker), quote.preview.postMarginUsdc);
    }

    function test_QuoteMaxOpen_UncollectibleCarryRejectsEverySize() public {
        address account = address(0xAB03);
        _fundTrader(account, 5000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.warp(block.timestamp + 36_500 days);
        assertGt(_expectedIndexedCarryUsdc(account), clearinghouse.balanceUsdc(account));
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, CfdTypes.Side.LONG, 5000e6, 1e8);
        assertEq(quote.maxSizeDelta, 0);
        assertEq(uint256(quote.limitingReason), uint256(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES));
    }

    function test_QuoteMaxOpen_SearchExhaustionIsExplicit() public {
        address account = address(0xA11CE);
        _fundTrader(account, 10_000e6);
        CfdEnginePlanTypes.OpenDelta memory rejected;
        rejected.revertCode = CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
        // A rejecting dependency prevents a witness even in ranges whose optimistic accounting bounds pass.
        vm.mockCall(
            address(engine.planner()), abi.encodeWithSelector(ICfdEnginePlanner.planOpen.selector), abi.encode(rejected)
        );
        vm.expectRevert(ICfdEngineLens.CfdEngineLens__QuoteSearchLimitExceeded.selector);
        engineLens.quoteMaxOpen(account, CfdTypes.Side.LONG, 10_000e6, 1e8, uint64(block.timestamp));
    }

    function testFuzz_QuoteMaxOpen_DominatesEveryValidCandidate(
        bool isLong,
        uint16 opposingLots,
        uint64 factor,
        uint32 elapsed,
        uint32 oraclePrice,
        uint64 margin,
        uint16 candidateLots
    ) public {
        address account = address(0xF001);
        address maker = address(0xF002);
        CfdTypes.Side side = isLong ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;
        _fundTrader(account, 100_000e6);
        _open(account, side, 100_000e18, 20_000e6, 1e8);
        uint256 makerSize = bound(opposingLots, 10, 4000) * CfdTypes.SIZE_QUANTUM;
        _fundTrader(maker, 30_000e6);
        _open(maker, isLong ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG, makerSize, 20_000e6, 1e8);
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = bound(factor, 0, 12e18);
        _setRiskParams(params);
        vm.warp(block.timestamp + bound(elapsed, 0, 30 days));
        uint256 price = bound(oraclePrice, 80_000_001, 120_000_003);
        uint256 marginDelta = bound(margin, 0, 40_000e6);
        uint256 candidate = bound(candidateLots, 1, 8000) * CfdTypes.SIZE_QUANTUM;
        ICfdEngineLens.MaxOpenQuote memory quote = _quote(account, side, marginDelta, price);
        if (engineLens.previewOpen(account, side, candidate, marginDelta, price, uint64(block.timestamp)).valid) {
            assertGe(quote.maxSizeDelta, candidate, "no planner-valid witness may exceed the quote");
        }
        if (quote.maxSizeDelta > 0) {
            _open(account, side, quote.maxSizeDelta, marginDelta, price);
            assertEq(clearinghouse.pnlPledgeUsdc(account), quote.preview.postMarginUsdc);
        }
    }

    function testFuzz_QuoteMaxOpen_EqualsExhaustiveSmallDomain(
        bool isLong,
        bool fad,
        uint8 longLots,
        uint8 shortLots,
        uint64 factor,
        uint32 cash,
        uint32 margin,
        uint32 claim
    ) public {
        CfdEngineOpenQuoter quoter = new CfdEngineOpenQuoter();
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 price = 1_000_003;
        snap.account = address(0x123);
        snap.capPrice = price * 2;
        snap.poolAssetsUsdc = 100e6;
        snap.poolCashUsdc = snap.poolAssetsUsdc;
        snap.traderClaimBalanceForAccount = bound(claim, 0, 5e6);
        snap.totalTraderClaimBalanceUsdc = snap.traderClaimBalanceForAccount;
        snap.riskParams = _riskParams();
        snap.riskParams.minBountyUsdc = 1000;
        snap.riskParams.initMarginBps = 1000;
        snap.riskParams.fadMarginBps = 2000;
        snap.riskParams.vpiFactor = bound(factor, 0, 18e18);
        snap.executionFeeBps = 7;
        snap.settlementBufferBps = 25;
        snap.isFadWindow = fad;
        snap.longSide.openInterest = bound(longLots, 0, 40) * CfdTypes.SIZE_QUANTUM;
        snap.shortSide.openInterest = bound(shortLots, 0, 40) * CfdTypes.SIZE_QUANTUM;
        snap.longSide.maxProfitUsdc = snap.longSide.openInterest / CfdTypes.SIZE_QUANTUM * price;
        snap.shortSide.maxProfitUsdc = snap.shortSide.openInterest / CfdTypes.SIZE_QUANTUM * price;
        snap.accountBuckets =
            MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(bound(cash, 0, 12e6), 0, 0, 0, 0);
        CfdTypes.Order memory order;
        order.account = snap.account;
        order.side = isLong ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;
        order.marginDelta = bound(margin, 0, 12e6);
        (uint256 maximum,,) = quoter.quote(engine.planner(), snap, order, price, 0);
        uint256 exhaustiveMaximum;
        // Opposing OI <= 40 lots and the skew allowance is strictly below 40 lots; no size above 80 can pass.
        for (uint256 lots = 1; lots <= 80; ++lots) {
            order.sizeDelta = lots * CfdTypes.SIZE_QUANTUM;
            if (engine.planner().planOpen(snap, order, price, 0).valid) {
                exhaustiveMaximum = order.sizeDelta;
            }
        }
        assertEq(maximum, exhaustiveMaximum, "global maximum must match exhaustive enumeration");
    }

}
