// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PletherOracle} from "../../src/perps/PletherOracle.sol";
import {IPletherOracle} from "../../src/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
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

    function test_UpdateAndGetPrice_ReturnsSingleSnapshotAndRefundsExcess() public {
        vm.warp(1000);
        vm.deal(address(this), 1 ether);
        pyth.setFee(0.1 ether);
        _setBothPrices(100_000_000, 990);

        uint256 balanceBefore = address(this).balance;
        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updateAndGetPrice{value: 0.25 ether}(_pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);

        assertEq(snapshot.price, 1e8, "basket price");
        assertEq(snapshot.publishTime, 990, "weakest publish time");
        assertEq(snapshot.updateFee, 0.1 ether, "fee snapshot");
        assertEq(snapshot.maxStaleness, 60, "mode staleness");
        assertEq(balanceBefore - address(this).balance, 0.1 ether, "only Pyth fee retained");
    }

    function test_GetPrice_IsViewOnlyAndUsesCurrentStoredPythPrice() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 995);

        IPletherOracle.PriceSnapshot memory snapshot = oracle.getPrice(IPletherOracle.PriceMode.MarkRefresh);

        assertEq(snapshot.price, 1e8, "view price");
        assertEq(snapshot.publishTime, 995, "view publish time");
        assertEq(snapshot.updateFee, 0, "view has no update fee");
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

    function test_UpdateAndGetPrice_RevertsOnStalePrice() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 939);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_UpdateAndGetPrice_RevertsOnConfidenceTooWide() public {
        vm.warp(1000);
        pyth.setPrice(FEED_A, int64(100_000_000), uint64(2_000_000), int32(-8), 990);
        pyth.setPrice(FEED_B, int64(100_000_000), uint64(2_000_000), int32(-8), 990);
        oracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: 60, liquidationStalenessLimit: 15, pythMaxConfidenceRatioBps: 100
            })
        );

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ConfidenceTooWide.selector);
        oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_LiquidationMode_UsesStricterStalenessThanOrderExecution() public {
        vm.warp(1000);
        _setBothPrices(100_000_000, 984);

        IPletherOracle.PriceSnapshot memory orderSnapshot =
            oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
        assertEq(orderSnapshot.price, 1e8, "order mode accepts 16 second old price");

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.Liquidation);
    }

    function test_FrozenWindow_RevertsWhenFeedPublishTimesDivergeTooFar() public {
        vm.warp(1000);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        pyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        pyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PublishTimeDivergence.selector);
        oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.OrderExecution);
    }

    function test_UpdateAndGetPrice_RevertsWhenPublishTimePredatesStoredMark() public {
        vm.warp(1000);
        engine.setLastMark(1e8, 995);
        _setBothPrices(100_000_000, 990);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PriceOutOfOrder.selector);
        oracle.updateAndGetPrice(_pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_ApplyConfig_OnlyOwnerOrRouter() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IPletherOracle.PletherOracle__Unauthorized.selector);
        oracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: 120, liquidationStalenessLimit: 30, pythMaxConfidenceRatioBps: 500
            })
        );

        vm.prank(engine.orderRouter());
        oracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: 120, liquidationStalenessLimit: 30, pythMaxConfidenceRatioBps: 500
            })
        );

        assertEq(oracle.orderExecutionStalenessLimit(), 120, "router can apply config");
        assertEq(oracle.liquidationStalenessLimit(), 30, "liquidation limit");
        assertEq(oracle.pythMaxConfidenceRatioBps(), 500, "confidence bps");
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

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = hex"01";
    }

}
