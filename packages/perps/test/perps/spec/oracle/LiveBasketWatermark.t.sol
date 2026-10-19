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

    function test_InitialBasketRequiresSignedFirstTicksAndIgnoresStoredFeeds() public {
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
        assertEq(snapshot.publishTime, 990);
        times = oracle.getAcceptedFeedPublishTimes();
        assertEq(times[0], 990);
        assertEq(times[1], 993);
        assertEq(pyth.updatePriceFeedsCallCount(), 0);
        assertEq(pyth.parseUniqueCallCount(), 1);

        pyth.setPrice(A, 50_000_000, -8, 1000);
        pyth.setPrice(B, 50_000_000, -8, 1000);
        assertEq(oracle.getLatestPrice(), 100_000_000);
    }

    function test_ReusesFutureComponentAndRejectsSkippedFirstTick() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(100_000_000, 990, 980, 100_000_000, 993, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(100_000_000, 990);
        vm.warp(1001);
        IPletherOracle.PriceSnapshot memory snapshot = oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(110_000_000, 991, 990, 80_000_000, 992, 991), IPletherOracle.PriceMode.MarkRefresh
        );
        assertEq(snapshot.price, 105_000_000, "B at 993 remains the first tick after 991");
        assertEq(snapshot.publishTime, 991);
        engine.setLastMark(snapshot.markPrice, snapshot.publishTime);

        vm.warp(1002);
        vm.expectRevert(bytes("feed not found within range"));
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(120_000_000, 993, 992, 80_000_000, 992, 991), IPletherOracle.PriceMode.MarkRefresh
        );
        assertEq(oracle.getLatestPrice(), 105_000_000);

        bytes[] memory empty = new bytes[](0);
        snapshot = oracle.updatePrice(address(this), empty, IPletherOracle.PriceMode.MarkRefresh);
        assertEq(snapshot.updateFee, 0);
        assertEq(snapshot.price, 105_000_000);
    }

    function test_EqualTimeReplayRequiresMatchingEngineMark() public {
        oracle.updatePrice{value: FEE}(
            address(this), _twoTicks(100_000_000, 990, 980, 100_000_000, 990, 980), IPletherOracle.PriceMode.MarkRefresh
        );
        engine.setLastMark(101_000_000, 990);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__EqualTimeMarkMismatch.selector);
        oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);
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
