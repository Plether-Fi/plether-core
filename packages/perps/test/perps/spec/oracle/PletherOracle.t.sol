// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    GasBurningOracleRefundRecipient,
    PletherOracleEngineMock,
    PletherOracleVaultMock
} from "./PletherOracleMocks.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract PletherOracleTest is Test {

    bytes32 internal constant FEED_A = bytes32(uint256(1));
    bytes32 internal constant FEED_B = bytes32(uint256(2));

    MockPyth internal pyth;
    PletherOracleEngineMock internal engine;
    PletherOracleVaultMock internal vault;
    PletherOracle internal oracle;

    bytes32[] internal feedIds;
    uint256[] internal weights;
    uint256[] internal basePrices;
    bool[] internal inversions;

    receive() external payable {}

    function setUp() public {
        pyth = new MockPyth();
        pyth.setSynchronizeLegacyUniquePrices(true);
        engine = new PletherOracleEngineMock();
        vault = new PletherOracleVaultMock();
        engine.setOrderRouter(address(this));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        basePrices.push(1e8);
        basePrices.push(1e8);
        inversions.push(false);
        inversions.push(false);

        oracle = _deployOracle(address(pyth));
    }

    function test_UpdatePrice_ReturnsSingleSnapshotAndRefundsExcess() public {
        vm.warp(1000);
        vm.deal(address(this), 1 ether);
        pyth.setFee(0.1 ether);
        _setBothPrices(100_000_000, 990);

        uint256 balanceBefore = address(this).balance;
        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: 0.25 ether}(
            address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution
        );

        assertEq(snapshot.price, 1e8, "basket price");
        assertEq(snapshot.publishTime, 990, "weakest publish time");
        assertEq(snapshot.updateFee, 0.1 ether, "fee snapshot");
        assertEq(snapshot.maxStaleness, 60, "mode staleness");
        assertEq(balanceBefore - address(this).balance, 0.1 ether, "only Pyth fee retained");
    }

    function test_UpdatePrice_GasBurningRefundRecipientAccruesAndClaimsDeferredRefund() public {
        vm.warp(1000);
        vm.deal(address(this), 1 ether);
        pyth.setFee(0.1 ether);
        _setBothPrices(100_000_000, 990);

        GasBurningOracleRefundRecipient recipient = new GasBurningOracleRefundRecipient();
        uint256 refund = 0.15 ether;

        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: 0.1 ether + refund, gas: 1_000_000}(
            address(recipient), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution
        );

        assertEq(snapshot.updateFee, 0.1 ether, "price update should still complete after the capped callback fails");
        assertEq(address(recipient).balance, 0, "failed immediate refund must not transfer ETH");
        assertEq(recipient.receivedEth(), 0, "failed callback state must roll back");
        assertEq(oracle.claimableEth(address(recipient)), refund, "the full failed refund must become claimable");
        assertEq(address(oracle).balance, refund, "the deferred claim must remain fully funded");

        recipient.setBurnRefundGas(false);
        recipient.claim(oracle);

        assertEq(oracle.claimableEth(address(recipient)), 0, "a successful claim must clear its accounting");
        assertEq(recipient.receivedEth(), refund, "the recipient must receive the complete deferred refund");
        assertEq(address(recipient).balance, refund, "claimed ETH balance");
        assertEq(address(oracle).balance, 0, "the oracle must not retain claimed ETH");
    }

    function test_GetLatestPrice_IsViewOnlyAndUsesAcceptedBasket() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 995);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        IPletherOracle.PriceSnapshot memory snapshot = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);

        assertEq(snapshot.price, 1e8, "view price");
        assertEq(snapshot.publishTime, 995, "view publish time");
        assertEq(snapshot.updateFee, 0, "view has no update fee");
    }

    function test_GetLatestPoolReconcilePrice_ReturnsSnapshotAndAggregateConfidence() public {
        vm.warp(1000);
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(80_000), int32(-8), 995);
        pyth.setPrice(FEED_B, int64(100_000_000), uint64(40_000), int32(-8), 995);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        (IPletherOracle.PriceSnapshot memory snapshot, uint256 confidence) = oracle.getLatestPoolReconcilePrice();
        IPletherOracle.PriceSnapshot memory existingSnapshot =
            oracle.getLatestPrice(IPletherOracle.PriceMode.PoolReconcile);

        assertEq(snapshot.price, existingSnapshot.price, "price parity");
        assertEq(snapshot.markPrice, existingSnapshot.markPrice, "mark parity");
        assertEq(snapshot.publishTime, existingSnapshot.publishTime, "publish-time parity");
        assertEq(snapshot.updateFee, existingSnapshot.updateFee, "fee parity");
        assertEq(snapshot.maxStaleness, existingSnapshot.maxStaleness, "staleness parity");
        assertEq(snapshot.closeOnly, existingSnapshot.closeOnly, "close-only parity");
        assertEq(snapshot.oracleFrozen, existingSnapshot.oracleFrozen, "frozen parity");
        assertEq(snapshot.isFadWindow, existingSnapshot.isFadWindow, "FAD parity");
        assertEq(confidence, 60_000, "weighted aggregate confidence");
    }

    function test_GetLatestPoolReconcilePrice_PreservesPoolReconcileValidationErrors() public {
        vm.warp(970);
        vault.setMarkStalenessLimit(30);
        _setBothPrices(100_000_000, 969);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
        vm.warp(1000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StalePrice.selector,
                IPletherOracle.PriceMode.PoolReconcile,
                FEED_A,
                uint256(969),
                uint256(30),
                uint256(1000)
            )
        );
        oracle.getLatestPoolReconcilePrice();
    }

    function test_ReportInterface_ReturnsLatestPriceOnly() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 995);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        uint256 latestPrice = oracle.getLatestPrice();
        assertEq(latestPrice, 1e8, "latest price view");

        latestPrice = oracle.updatePrice(address(this), new bytes[](0));
        assertEq(latestPrice, 1e8, "latest price update");
    }

    function test_Constructor_RevertsOnMissingFeeds() public {
        bytes32[] memory ids = new bytes32[](0);
        uint256[] memory w = new uint256[](0);
        uint256[] memory bases = new uint256[](0);
        bool[] memory inv = new bool[](0);

        vm.expectRevert(IPletherOracle.PletherOracle__NoFeeds.selector);
        new PletherOracle(address(engine), address(vault), address(pyth), ids, w, bases, inv);
    }

    function test_Constructor_RevertsOnZeroPyth() public {
        vm.expectRevert(IPletherOracle.PletherOracle__ZeroPyth.selector);
        _deployOracle(address(0));
    }

    function test_Constructor_RevertsOnArrayLengthMismatch() public {
        bool[] memory inv = new bool[](1);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ArrayLengthMismatch.selector);
        new PletherOracle(address(engine), address(vault), address(pyth), feedIds, weights, basePrices, inv);
    }

    function test_Constructor_RevertsOnZeroBasePrice() public {
        basePrices[1] = 0;

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ZeroBasePrice.selector);
        new PletherOracle(address(engine), address(vault), address(pyth), feedIds, weights, basePrices, inversions);
    }

    function test_Constructor_RevertsOnZeroWeightWithValidTotal() public {
        weights[0] = 0;
        weights[1] = 1e18;

        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__ZeroWeight.selector, 0));
        _deployOracle(address(pyth));

        weights[0] = 1e18;
        weights[1] = 0;

        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__ZeroWeight.selector, 1));
        _deployOracle(address(pyth));
    }

    function test_Constructor_RejectsZeroAndDuplicateFeedIds() public {
        feedIds[0] = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__InvalidFeedId.selector, bytes32(0)));
        _deployOracle(address(pyth));

        feedIds[0] = FEED_A;
        feedIds[1] = FEED_A;
        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__InvalidFeedId.selector, FEED_A));
        _deployOracle(address(pyth));
    }

    function test_Constructor_RevertsOnInvalidTotalWeight() public {
        weights[1] = 0.4e18;

        vm.expectPartialRevert(IPletherOracle.PletherOracle__InvalidTotalWeight.selector);
        new PletherOracle(address(engine), address(vault), address(pyth), feedIds, weights, basePrices, inversions);
    }

    function test_UpdatePrice_RevertsOnStalePrice() public {
        vm.warp(940);
        _setBothPrices(100_000_000, 939);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
        vm.warp(1000);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_CurrentUpdates_RejectNonRouterCaller() public {
        vm.warp(1000);
        _setBothPrices(120_000_000, 995);

        vm.expectRevert(IPletherOracle.PletherOracle__Unauthorized.selector);
        vm.prank(address(0xBEEF));
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        vm.expectRevert(IPletherOracle.PletherOracle__Unauthorized.selector);
        vm.prank(address(0xBEEF));
        oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));
    }

    function test_LiveUpdate_RequiresQuotedPythFee() public {
        vm.warp(1000);
        pyth.setFee(1 gwei);
        _setBothPrices(120_000_000, 995);

        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__InsufficientFee.selector, 0, 1 gwei));
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
        assertFalse(oracle.hasAcceptedBasket());
    }

    function test_FrozenCurrentUpdate_RequiresStoredMark() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);

        vm.expectRevert(IPletherOracle.PletherOracle__NoAcceptedBasket.selector);
        oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_HistoricalOrderExecution_RequiresSignedPayload() public {
        vm.warp(1000);

        vm.expectRevert(IPletherOracle.PletherOracle__MissingUpdateData.selector);
        oracle.updateOrderExecutionPrice(address(this), new bytes[](0), _orderRequest(CfdTypes.Side.LONG, false));
    }

    function test_UpdatePrice_AllowsWideLowWeightComponentWhenBasketConfidenceWithinLimit() public {
        vm.warp(1000);
        weights[0] = 0.05e18;
        weights[1] = 0.95e18;
        oracle = _deployOracle(address(pyth));
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(1_000_000), int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), uint64(0), int32(-8), 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        assertEq(snapshot.price, 100_000_000, "wide low-weight feed should not block a sound basket");
    }

    function test_UpdatePrice_AllowsBasketConfidenceExactlyAtThreshold() public {
        vm.warp(1000);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);

        assertEq(snapshot.price, 100_000_000, "equality at the basket limit should pass");
    }

    function test_UpdatePrice_RevertsOneUnitAboveBasketConfidenceLimitInEveryMode() public {
        vm.warp(1000);
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(100_002), int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), uint64(100_000), int32(-8), 990);

        for (uint8 i = 0; i <= uint8(IPletherOracle.PriceMode.PoolReconcile); i++) {
            IPletherOracle.PriceMode mode = IPletherOracle.PriceMode(i);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector,
                    mode,
                    uint256(100_001),
                    uint256(100_000_000),
                    uint256(10)
                )
            );
            oracle.updatePrice(address(this), _pythUpdateData(), mode);
        }
    }

    function test_InvertedAndNonInvertedFeedsUseWeightedBasketConfidence() public {
        vm.warp(1000);
        inversions[1] = true;
        basePrices[1] = 50_000_000;
        oracle = _deployOracle(address(pyth));
        engine.setPosition(1e18, CfdTypes.Side.LONG);
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(100_000), int32(-8), 990);
        pyth.setPrice(FEED_B, int64(200_000_000), uint64(200_000), int32(-8), 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));

        assertEq(snapshot.markPrice, 100_000_000, "normalized basket price");
        assertEq(snapshot.price, 100_020_000, "aggregate confidence should be 100,000 before the 20% shift");
    }

    function testFuzz_BasketAcceptsWhenBothComponentsAreWithinLimit(
        uint64 confidenceA,
        uint64 confidenceB
    ) public {
        vm.warp(1000);
        confidenceA = uint64(bound(uint256(confidenceA), 0, 100_000));
        confidenceB = uint64(bound(uint256(confidenceB), 0, 100_000));
        pyth.setPrice(FEED_A, int64(100_000_000), confidenceA, int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), confidenceB, int32(-8), 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
        assertEq(snapshot.price, 100_000_000, "accepted basket price");
    }

    function testFuzz_BasketRejectsWhenBothComponentsExceedLimit(
        uint64 confidenceA,
        uint64 confidenceB
    ) public {
        vm.warp(1000);
        confidenceA = uint64(bound(uint256(confidenceA), 100_002, 1_000_000));
        confidenceB = uint64(bound(uint256(confidenceB), 100_002, 1_000_000));
        pyth.setPrice(FEED_A, int64(100_000_000), confidenceA, int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), confidenceB, int32(-8), 990);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_LiquidationMode_UsesStricterStalenessThanOrderExecution() public {
        vm.warp(985);
        _setBothPrices(100_000_000, 984);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
        vm.warp(1000);

        IPletherOracle.PriceSnapshot memory orderSnapshot =
            oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.OrderExecution);
        assertEq(orderSnapshot.price, 1e8, "order mode accepts 16 second old price");

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.Liquidation);
    }

    function test_FrozenWindow_IgnoresStoredFeedDivergenceAndReplaysEngineMark() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        pyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        pyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.OrderExecution);
        assertEq(snapshot.publishTime, 990);
        assertEq(snapshot.price, 100_000_000);
    }

    function test_FrozenLiquidation_AllowsFeedDivergenceWithinFadMaxStaleness() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 984);
        pyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        pyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 984);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));

        assertTrue(snapshot.oracleFrozen, "setup should use frozen oracle policy");
        assertEq(snapshot.maxStaleness, engine.fadMaxStaleness(), "liquidation should use frozen staleness");
        assertEq(snapshot.publishTime, 984, "basket should retain weakest publish time");
        assertEq(snapshot.price, 100_000_000, "neutral price without a position");
    }

    function test_LiveClose_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        _setHistoricalPricesWithConfidence(100_000_000, 100_000);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, true));

        assertTrue(ok, "live close should resolve a historical execution price");
        assertFalse(snapshot.closeOnly, "live execution should not be close-only");
        assertFalse(snapshot.oracleFrozen, "live execution should not be oracle-frozen");
        assertEq(snapshot.markPrice, 100_000_000, "mark should retain the unshifted basket price");
        assertEq(snapshot.price, 100_020_000, "live close should retain the adverse confidence shift");
    }

    function test_FadOnlyClose_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadWindow(true);
        _setHistoricalPricesWithConfidence(100_000_000, 100_000);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, true));

        assertTrue(ok, "FAD-only close should resolve a historical execution price");
        assertTrue(snapshot.closeOnly, "FAD execution should be close-only");
        assertTrue(snapshot.isFadWindow, "setup should use FAD policy");
        assertFalse(snapshot.oracleFrozen, "FAD runway should not imply oracle freeze");
        assertEq(snapshot.price, 100_020_000, "FAD-only close should retain the adverse confidence shift");
    }

    function test_OracleFrozenClose_WaivesAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, true));

        assertTrue(ok, "oracle-frozen close should replay the Engine mark");
        assertTrue(snapshot.closeOnly, "oracle-frozen execution should be close-only");
        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.markPrice, 100_000_000, "mark should retain the unshifted basket price");
        assertEq(snapshot.price, 100_000_000, "oracle-frozen close should waive the adverse confidence shift");
    }

    function test_OracleFrozenClose_IgnoresMutablePythConfidence() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        _setLivePricesWithConfidence(100_000_000, 100_002, 990);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, true));
        assertTrue(ok);
        assertEq(snapshot.price, 100_000_000);
    }

    function test_OracleFrozenBatchClose_WaivesAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);
        IPletherOracle.BatchOrderPriceCache memory cache;

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot, IPletherOracle.BatchOrderPriceCache memory nextCache) = oracle.updateBatchOrderExecutionPrice(
            address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, true), cache
        );

        assertTrue(ok, "oracle-frozen batch close should resolve the stored Pyth basket");
        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.price, 100_000_000, "batch close should waive the adverse confidence shift");
        assertFalse(nextCache.hasHistoricalBasket, "frozen execution should not cache a historical basket");
    }

    function test_OracleFrozenOpen_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.LONG, false));

        assertTrue(ok, "direct oracle call should still resolve a frozen open price");
        assertEq(snapshot.price, 99_980_000, "non-close execution should retain the adverse confidence shift");
    }

    function test_OracleFrozenLiquidation_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setLastMark(100_000_000, 990);
        engine.setPosition(1e18, CfdTypes.Side.LONG);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));

        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.price, 100_020_000, "liquidation should retain the adverse confidence shift");
    }

    function test_UpdatePrice_RevertsWhenPublishTimePredatesStoredMark() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 990);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
        engine.setLastMark(1e8, 995);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PriceOutOfOrder.selector);
        oracle.updatePrice(address(this), new bytes[](0), IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_ApplyConfig_OnlyConfiguredRouter() public {
        IPletherOracle.OracleConfig memory config = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 120,
            liquidationStalenessLimit: 30,
            basketMaxConfidenceRatioBps: 500,
            orderSettlementWindow: oracle.orderSettlementWindow(),
            maxComponentPublishTimeDivergence: oracle.maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: oracle.adverseConfidenceMultiplierBps()
        });

        vm.expectRevert(IPletherOracle.PletherOracle__Unauthorized.selector);
        vm.prank(address(0xBEEF));
        oracle.applyConfig(config);

        vm.prank(engine.orderRouter());
        oracle.applyConfig(config);

        assertEq(oracle.orderExecutionStalenessLimit(), 120, "router can apply config");
        assertEq(oracle.liquidationStalenessLimit(), 30, "liquidation limit");
        assertEq(oracle.basketMaxConfidenceRatioBps(), 500, "confidence bps");
    }

    function test_ApplyConfig_DeployerCannotBypassRouter() public {
        address router = address(0xA11CE);
        engine.setOrderRouter(router);

        IPletherOracle.OracleConfig memory config = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 120,
            liquidationStalenessLimit: 30,
            basketMaxConfidenceRatioBps: 500,
            orderSettlementWindow: oracle.orderSettlementWindow(),
            maxComponentPublishTimeDivergence: oracle.maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: oracle.adverseConfidenceMultiplierBps()
        });

        vm.expectRevert(IPletherOracle.PletherOracle__Unauthorized.selector);
        oracle.applyConfig(config);

        vm.prank(router);
        oracle.applyConfig(config);

        assertEq(oracle.orderExecutionStalenessLimit(), 120, "router can apply config");
    }

    function _deployOracle(
        address pyth_
    ) internal returns (PletherOracle) {
        return new PletherOracle(address(engine), address(vault), pyth_, feedIds, weights, basePrices, inversions);
    }

    function _setBothPrices(
        int64 price,
        uint256 publishTime
    ) internal {
        pyth.setPrice(FEED_A, price, int32(-8), publishTime);
        pyth.setPrice(FEED_B, price, int32(-8), publishTime);
    }

    function _setHistoricalPricesWithConfidence(
        int64 price,
        uint64 confidence
    ) internal {
        pyth.setAllUniquePrices(feedIds, price, confidence, int32(-8), 995, 990);
    }

    function _setLivePricesWithConfidence(
        int64 price,
        uint64 confidence,
        uint256 publishTime
    ) internal {
        pyth.setPrice(FEED_A, price, confidence, int32(-8), publishTime);
        pyth.setPrice(FEED_B, price, confidence, int32(-8), publishTime);
    }

    function _orderRequest(
        CfdTypes.Side side,
        bool isClose
    ) internal pure returns (IPletherOracle.OrderExecutionRequest memory request) {
        request = IPletherOracle.OrderExecutionRequest({
            commitTime: 990, targetPrice: 0, side: side, isClose: isClose, revertOnHistoricalUnavailable: true
        });
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = hex"01";
    }

}
