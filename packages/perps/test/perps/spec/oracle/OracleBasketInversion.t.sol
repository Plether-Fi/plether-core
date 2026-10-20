// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OracleMathPolicyFixture} from "../../shared/PletherOracleMathHarness.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract InversionTest is Test {

    MockPyth internal mockPyth;
    OracleMathPolicyFixture internal policy;
    bytes32 internal constant FEED_JPY = bytes32(uint256(0xAA));
    bytes32 internal constant FEED_EUR = bytes32(uint256(0xBB));

    function setUp() public {
        mockPyth = new MockPyth();
        policy = new OracleMathPolicyFixture();
        vm.warp(1001);
    }

    function test_InvertedFeedUsesCorrectPrice() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = 500_000;
        bool[] memory inversions = new bool[](1);
        inversions[0] = true;
        PletherOracle oracle = _deploy(ids, weights, bases, inversions);

        mockPyth.setPrice(FEED_JPY, 156_700, -3, 1000);
        oracle.updatePrice(address(this), _oneFeed(156_700, 1000), IPletherOracle.PriceMode.MarkRefresh);
        IPletherOracle.PriceSnapshot memory snapshot = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);

        // 1 / 156.7 is 0.0063816209...; the eight-decimal component is 638162.
        // Against the 0.005 base, the public basket is 1.276324, well away from the $1 symmetry point.
        assertEq(snapshot.price, 127_632_400);
        assertEq(snapshot.markPrice, 127_632_400);
        assertEq(snapshot.publishTime, 1000);
    }

    function test_InvertedConfidenceAboveBasketLimitReverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = 50_000_000;
        bool[] memory inversions = new bool[](1);
        inversions[0] = true;
        PletherOracle oracle = _deploy(ids, weights, bases, inversions);

        mockPyth.setPrice(FEED_JPY, 200_000_000, 200_000, -8, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector,
                IPletherOracle.PriceMode.MarkRefresh,
                uint256(100_100),
                uint256(100_000_000),
                uint256(10)
            )
        );
        oracle.updatePrice(
            address(this), _oneFeedWithConfidence(200_000_000, 200_000, -8, 1000), IPletherOracle.PriceMode.MarkRefresh
        );
    }

    function test_InvertedConfidenceUsesWeightedUpperEndpoint() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = 50_000_000;
        bool[] memory inversions = new bool[](1);
        inversions[0] = true;
        PletherOracle oracle = _deploy(ids, weights, bases, inversions);

        mockPyth.setPrice(FEED_JPY, 200_000_000, 100_000, -8, 1000);
        oracle.updatePrice(
            address(this), _oneFeedWithConfidence(200_000_000, 100_000, -8, 1000), IPletherOracle.PriceMode.MarkRefresh
        );
        (IPletherOracle.PriceSnapshot memory snapshot, uint256 confidence) = oracle.getLatestPoolReconcilePrice();

        assertEq(snapshot.markPrice, 100_000_000, "midpoint is unchanged");
        assertEq(confidence, 50_024, "upper inverse endpoint is normalized and weighted before subtraction");
    }

    function test_InvertedConfidenceRejectsNonpositiveRawLowerBound() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = 50_000_000;
        bool[] memory inversions = new bool[](1);
        inversions[0] = true;
        PletherOracle oracle = _deploy(ids, weights, bases, inversions);

        uint64[2] memory confidences = [uint64(200_000_000), uint64(200_000_001)];
        for (uint256 i; i < confidences.length; ++i) {
            mockPyth.setPrice(FEED_JPY, 200_000_000, confidences[i], -8, 1000);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPletherOracle.PletherOracle__InvalidInverseConfidence.selector,
                    FEED_JPY,
                    int64(200_000_000),
                    confidences[i]
                )
            );
            oracle.updatePrice(
                address(this),
                _oneFeedWithConfidence(200_000_000, confidences[i], -8, 1000),
                IPletherOracle.PriceMode.MarkRefresh
            );
        }
    }

    function test_InversionsLengthMismatchReverts() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_JPY;
        ids[1] = FEED_EUR;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        uint256[] memory bases = new uint256[](2);
        bases[0] = 1e8;
        bases[1] = 1e8;

        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__ArrayLengthMismatch.selector, 2, 2, 2, 1));
        _deploy(ids, weights, bases, new bool[](1));
    }

    function test_MixedInversionsComputeCorrectBasket() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_EUR;
        ids[1] = FEED_JPY;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.7e18;
        weights[1] = 0.3e18;
        uint256[] memory bases = new uint256[](2);
        bases[0] = 100_000_000;
        bases[1] = 1_000_000;
        bool[] memory inversions = new bool[](2);
        inversions[1] = true;
        PletherOracle oracle = _deploy(ids, weights, bases, inversions);

        mockPyth.setPrice(FEED_EUR, 120_000_000, -8, 997);
        mockPyth.setPrice(FEED_JPY, 125_000, -3, 995);
        oracle.updatePrice(
            address(this), _twoFeeds(120_000_000, 997, 125_000, 995), IPletherOracle.PriceMode.MarkRefresh
        );
        IPletherOracle.PriceSnapshot memory snapshot = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);

        // Component ratios are 1.2 and 0.8 respectively; the 70/30 basket is exactly 1.08.
        assertEq(snapshot.price, 108_000_000);
        assertEq(snapshot.markPrice, 108_000_000);
        assertEq(snapshot.publishTime, 997, "public snapshot advances with the newest component timestamp");
    }

    function test_PublicBasketRejectsZeroAndNegativeFeedBeforeInversion() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = 500_000;
        bool[] memory inversions = new bool[](1);
        int64[3] memory invalid = [int64(0), int64(-1), type(int64).min];
        for (uint256 inverted; inverted < 2; ++inverted) {
            inversions[0] = inverted == 1;
            PletherOracle oracle = _deploy(ids, weights, bases, inversions);
            for (uint256 i; i < invalid.length; ++i) {
                mockPyth.setPrice(FEED_JPY, invalid[i], -3, 1000);
                vm.expectRevert(
                    abi.encodeWithSelector(IPletherOracle.PletherOracle__InvalidPrice.selector, FEED_JPY, invalid[i])
                );
                oracle.updatePrice(address(this), _oneFeed(invalid[i], 1000), IPletherOracle.PriceMode.MarkRefresh);
            }
        }
    }

    function _oneFeed(
        int64 price,
        uint64 time
    ) private pure returns (bytes[] memory data) {
        return _oneFeedWithConfidence(price, 0, -3, time);
    }

    function _oneFeedWithConfidence(
        int64 price,
        uint64 confidence,
        int32 exponent,
        uint64 time
    ) private pure returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory feeds = new MockPyth.FeedUpdate[](1);
        feeds[0] = MockPyth.FeedUpdate(FEED_JPY, MockPyth.MockPrice(price, confidence, exponent, time, 0));
        data = new bytes[](1);
        data[0] = abi.encode(feeds);
    }

    function _twoFeeds(
        int64 eurPrice,
        uint64 eurTime,
        int64 jpyPrice,
        uint64 jpyTime
    ) private pure returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory feeds = new MockPyth.FeedUpdate[](2);
        feeds[0] = MockPyth.FeedUpdate(FEED_EUR, MockPyth.MockPrice(eurPrice, 0, -8, eurTime, 0));
        feeds[1] = MockPyth.FeedUpdate(FEED_JPY, MockPyth.MockPrice(jpyPrice, 0, -3, jpyTime, 0));
        data = new bytes[](1);
        data[0] = abi.encode(feeds);
    }

    function _deploy(
        bytes32[] memory ids,
        uint256[] memory weights,
        uint256[] memory bases,
        bool[] memory inversions
    ) private returns (PletherOracle) {
        return new PletherOracle(address(policy), address(policy), address(mockPyth), ids, weights, bases, inversions);
    }

}
