// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract PletherOracleEngineMock {

    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;
    uint256 public CAP_PRICE = 2e8;
    bool public isFadWindow;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public engineMarkStalenessLimit = 60;
    address public orderRouter;
    mapping(uint256 => bool) public fadDayOverrides;
    uint256 internal mockPositionSize;
    CfdTypes.Side internal mockPositionSide;

    function setLastMark(
        uint256 price,
        uint64 publishTime
    ) external {
        lastMarkPrice = price;
        lastMarkTime = publishTime;
    }

    function setCapPrice(
        uint256 price
    ) external {
        CAP_PRICE = price;
    }

    function setFadWindow(
        bool active
    ) external {
        isFadWindow = active;
    }

    function setOrderRouter(
        address router
    ) external {
        orderRouter = router;
    }

    function setFadDayOverride(
        uint256 dayNumber,
        bool active
    ) external {
        fadDayOverrides[dayNumber] = active;
    }

    function setPosition(
        uint256 size,
        CfdTypes.Side side
    ) external {
        mockPositionSize = size;
        mockPositionSide = side;
    }

    function positions(
        address
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        )
    {
        return (mockPositionSize, 0, 0, 0, mockPositionSide, 0, 0);
    }

}

contract PletherOracleVaultMock {

    uint256 public markStalenessLimit = 60;

    function setMarkStalenessLimit(
        uint256 limit
    ) external {
        markStalenessLimit = limit;
    }

}

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

    function test_GetLatestPrice_IsViewOnlyAndUsesCurrentStoredPythPrice() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 995);

        IPletherOracle.PriceSnapshot memory snapshot = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);

        assertEq(snapshot.price, 1e8, "view price");
        assertEq(snapshot.publishTime, 995, "view publish time");
        assertEq(snapshot.updateFee, 0, "view has no update fee");
    }

    function test_ReportInterface_ReturnsLatestPriceOnly() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 995);

        uint256 latestPrice = oracle.getLatestPrice();
        assertEq(latestPrice, 1e8, "latest price view");

        latestPrice = oracle.updatePrice(address(this), _pythUpdateData());
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

    function test_Constructor_RevertsOnInvalidTotalWeight() public {
        weights[1] = 0.4e18;

        vm.expectPartialRevert(IPletherOracle.PletherOracle__InvalidTotalWeight.selector);
        new PletherOracle(address(engine), address(vault), address(pyth), feedIds, weights, basePrices, inversions);
    }

    function test_UpdatePrice_RevertsOnStalePrice() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 939);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_UpdatePrice_RevertsOnConfidenceTooWide() public {
        vm.warp(1000);
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(2_000_000), int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), uint64(2_000_000), int32(-8), 990);
        oracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: 60,
                liquidationStalenessLimit: 15,
                pythMaxConfidenceRatioBps: 100,
                orderSettlementWindow: oracle.orderSettlementWindow(),
                maxComponentPublishTimeDivergence: oracle.maxComponentPublishTimeDivergence(),
                adverseConfidenceMultiplierBps: oracle.adverseConfidenceMultiplierBps()
            })
        );

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ConfidenceTooWide.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_LiquidationMode_UsesStricterStalenessThanOrderExecution() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 984);

        IPletherOracle.PriceSnapshot memory orderSnapshot =
            oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
        assertEq(orderSnapshot.price, 1e8, "order mode accepts 16 second old price");

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.Liquidation);
    }

    function test_FrozenWindow_RevertsWhenFeedPublishTimesDivergeTooFar() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        pyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        pyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PublishTimeDivergence.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_FrozenLiquidation_AllowsFeedDivergenceWithinFadMaxStaleness() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        pyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        pyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 984);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));

        assertTrue(snapshot.oracleFrozen, "setup should use frozen oracle policy");
        assertEq(snapshot.maxStaleness, engine.fadMaxStaleness(), "liquidation should use frozen staleness");
        assertEq(snapshot.publishTime, 984, "basket should retain weakest publish time");
        assertEq(snapshot.price, 1e8, "basket price");
    }

    function test_LiveClose_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        _setHistoricalPricesWithConfidence(100_000_000, 100_000);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, true));

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
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, true));

        assertTrue(ok, "FAD-only close should resolve a historical execution price");
        assertTrue(snapshot.closeOnly, "FAD execution should be close-only");
        assertTrue(snapshot.isFadWindow, "setup should use FAD policy");
        assertFalse(snapshot.oracleFrozen, "FAD runway should not imply oracle freeze");
        assertEq(snapshot.price, 100_020_000, "FAD-only close should retain the adverse confidence shift");
    }

    function test_OracleFrozenClose_WaivesAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, true));

        assertTrue(ok, "oracle-frozen close should resolve the stored Pyth basket");
        assertTrue(snapshot.closeOnly, "oracle-frozen execution should be close-only");
        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.markPrice, 100_000_000, "mark should retain the unshifted basket price");
        assertEq(snapshot.price, 100_000_000, "oracle-frozen close should waive the adverse confidence shift");
    }

    function test_OracleFrozenClose_StillRejectsConfidenceTooWide() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        _setLivePricesWithConfidence(100_000_000, 100_001, 990);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ConfidenceTooWide.selector);
        oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, true));
    }

    function test_OracleFrozenBatchClose_WaivesAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);
        IPletherOracle.BatchOrderPriceCache memory cache;

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot, IPletherOracle.BatchOrderPriceCache memory nextCache) = oracle.updateBatchOrderExecutionPrice(
            address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, true), cache
        );

        assertTrue(ok, "oracle-frozen batch close should resolve the stored Pyth basket");
        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.price, 100_000_000, "batch close should waive the adverse confidence shift");
        assertFalse(nextCache.hasHistoricalBasket, "frozen execution should not cache a historical basket");
    }

    function test_OracleFrozenOpen_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            oracle.updateOrderExecutionPrice(address(this), _pythUpdateData(), _orderRequest(CfdTypes.Side.BULL, false));

        assertTrue(ok, "direct oracle call should still resolve a frozen open price");
        assertEq(snapshot.price, 99_980_000, "non-close execution should retain the adverse confidence shift");
    }

    function test_OracleFrozenLiquidation_RetainsAdverseConfidenceAdjustment() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        engine.setPosition(1e18, CfdTypes.Side.BULL);
        _setLivePricesWithConfidence(100_000_000, 100_000, 990);

        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateLiquidationPrice(address(this), _pythUpdateData(), address(0xCAFE));

        assertTrue(snapshot.oracleFrozen, "setup should use oracle-frozen policy");
        assertEq(snapshot.price, 100_020_000, "liquidation should retain the adverse confidence shift");
    }

    function test_UpdatePrice_RevertsWhenPublishTimePredatesStoredMark() public {
        vm.warp(1000);
        engine.setLastMark(1e8, 995);
        _setBothPrices(100_000_000, 990);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PriceOutOfOrder.selector);
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_ApplyConfig_OnlyConfiguredRouter() public {
        IPletherOracle.OracleConfig memory config = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 120,
            liquidationStalenessLimit: 30,
            pythMaxConfidenceRatioBps: 500,
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
        assertEq(oracle.pythMaxConfidenceRatioBps(), 500, "confidence bps");
    }

    function test_ApplyConfig_DeployerCannotBypassRouter() public {
        address router = address(0xA11CE);
        engine.setOrderRouter(router);

        IPletherOracle.OracleConfig memory config = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 120,
            liquidationStalenessLimit: 30,
            pythMaxConfidenceRatioBps: 500,
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
