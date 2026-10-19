// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PletherOracleEngineMock, PletherOracleVaultMock} from "./PletherOracleMocks.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract LiveBasketWatermarkTest is Test {

    bytes32 private constant A = bytes32(uint256(1));
    bytes32 private constant B = bytes32(uint256(2));
    uint256 private constant FEE = 1 gwei;

    MockPyth private pyth;
    PletherOracleEngineMock private engine;
    PletherOracle private oracle;

    function setUp() public {
        vm.warp(1000);
        pyth = new MockPyth();
        pyth.setFee(FEE);
        engine = new PletherOracleEngineMock();
        engine.setOrderRouter(address(this));
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = A;
        ids[1] = B;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        uint256[] memory bases = new uint256[](2);
        bases[0] = 1e8;
        bases[1] = 1e8;
        oracle = new PletherOracle(
            address(engine), address(new PletherOracleVaultMock()), address(pyth), ids, weights, bases, new bool[](2)
        );
        vm.deal(address(this), 1 ether);
    }

    function test_InitialBasketRequiresCompleteSignedFeedsAndIgnoresStoredFeeds() public {
        pyth.setPrice(A, 200_000_000, -8, 999);
        pyth.setPrice(B, 200_000_000, -8, 999);
        vm.expectRevert(IPletherOracle.PletherOracle__NoAcceptedBasket.selector);
        oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);
        uint256[] memory times = oracle.getAcceptedFeedPublishTimes();
        assertEq(times.length, 2);
        assertEq(times[0], 0);
        assertEq(times[1], 0);

        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(100_000_000, 990, 980, 100_000_000, 993, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        assertEq(snapshot.price, 100_000_000);
        assertEq(snapshot.publishTime, 993);
        times = oracle.getAcceptedFeedPublishTimes();
        assertEq(times[0], 990);
        assertEq(times[1], 993);
        assertEq(pyth.updatePriceFeedsCallCount(), 0);
        assertEq(pyth.parseCallCount(), 1);

        pyth.setPrice(A, 50_000_000, -8, 1000);
        pyth.setPrice(B, 50_000_000, -8, 1000);
        assertEq(oracle.getLatestPrice(), 100_000_000);
    }

    function test_RejectsMissingAndRegressedComponents() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(100_000_000, 990, 980, 100_000_000, 993, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(100_000_000, 993);
        vm.warp(1001);
        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(110_000_000, 994, 993, 80_000_000, 995, 993), IPletherOracle.PriceMode.MarkRefresh
        );
        assertEq(snapshot.price, 95_000_000);
        assertEq(snapshot.publishTime, 995);
        engine.setLastMark(snapshot.markPrice, snapshot.publishTime);

        vm.warp(1002);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__FeedTimeOutOfOrder.selector);
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(120_000_000, 996, 994, 80_000_000, 994, 993), IPletherOracle.PriceMode.MarkRefresh
        );
        bytes[] memory missing = new bytes[](1);
        MockPyth.FeedUpdate[] memory onlyA = new MockPyth.FeedUpdate[](1);
        onlyA[0] = MockPyth.FeedUpdate(A, MockPyth.MockPrice(120_000_000, 0, -8, 996, 994));
        missing[0] = abi.encode(onlyA);
        vm.expectRevert(bytes("feed not found within range"));
        oracle.updatePrice{value: FEE}(address(this), missing, IPletherOracle.PriceMode.MarkRefresh);
        assertEq(oracle.getLatestPrice(), 95_000_000);

        bytes[] memory empty = new bytes[](0);
        snapshot = oracle.updatePrice(address(this), empty, IPletherOracle.PriceMode.MarkRefresh);
        assertEq(snapshot.updateFee, 0);
        assertEq(snapshot.price, 95_000_000);
    }

    function test_EqualTimeReplayRequiresMatchingEngineMark() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(100_000_000, 990, 980, 100_000_000, 990, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(101_000_000, 990);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__EqualTimeMarkMismatch.selector);
        oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);
    }

    function test_NewerComponentAdvancesBasketMarkerForProtection() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(120_000_000, 990, 980, 120_000_000, 993, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(120_000_000, 993);
        vm.warp(1001);

        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(130_000_000, 994, 990, 120_000_000, 993, 990), IPletherOracle.PriceMode.MarkRefresh
        );
        assertEq(snapshot.price, 125_000_000);
        assertEq(snapshot.publishTime, 994, "a moving component advances the protection clock");
    }

    function test_EqualBasketMarkerCannotChangePrice() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(120_000_000, 990, 980, 120_000_000, 993, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(120_000_000, 993);
        vm.warp(1001);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__EqualTimeMarkMismatch.selector);
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(140_000_000, 992, 990, 120_000_000, 993, 990), IPletherOracle.PriceMode.MarkRefresh
        );
    }

    function test_PoolEpochRequiresEveryComponentAfterBoundary() public {
        vm.warp(3605);
        vm.expectRevert(
            abi.encodeWithSelector(IPletherOracle.PletherOracle__PoolEpochComponentTooOld.selector, 3599, 3600)
        );
        oracle.updatePrice{value: FEE}(
            address(this),
            _twoTicks(120_000_000, 3599, 3590, 120_000_000, 3601, 3590),
            IPletherOracle.PriceMode.PoolReconcile
        );

        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: FEE}(
            address(this),
            _twoTicks(120_000_000, 3601, 3590, 120_000_000, 3602, 3590),
            IPletherOracle.PriceMode.PoolReconcile
        );
        assertEq(snapshot.publishTime, 3602);
    }

    function test_FrozenReplaysEngineMarkAtZeroFee() public {
        engine.setLastMark(100_000_000, 990);
        engine.setFadDayOverride(block.timestamp / 86_400, true);
        bytes[] memory empty = new bytes[](0);
        assertEq(oracle.getUpdateFee(empty), 0);
        assertEq(oracle.getOrderExecutionFee(empty), 0);
        IPletherOracle.PriceSnapshot memory snapshot =
            oracle.updatePrice(address(this), empty, IPletherOracle.PriceMode.MarkRefresh);
        assertEq(snapshot.price, 100_000_000);
        assertEq(snapshot.publishTime, 990);
        assertEq(snapshot.updateFee, 0);
        assertEq(pyth.parseUniqueCallCount(), 0);
        assertEq(pyth.updatePriceFeedsCallCount(), 0);
    }

    function _twoTicks(
        int64 priceA,
        uint256 timeA,
        uint256 prevA,
        int64 priceB,
        uint256 timeB,
        uint256 prevB
    ) private pure returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](2);
        ticks[0] = MockPyth.FeedUpdate(A, MockPyth.MockPrice(priceA, 0, -8, timeA, prevA));
        ticks[1] = MockPyth.FeedUpdate(B, MockPyth.MockPrice(priceB, 0, -8, timeB, prevB));
        data = new bytes[](1);
        data[0] = abi.encode(ticks);
    }

}
