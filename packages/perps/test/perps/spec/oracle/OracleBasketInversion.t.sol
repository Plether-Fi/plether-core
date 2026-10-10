// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";

import {BasketPriceHarness} from "../../shared/OrderRouterTestBase.sol";

contract InversionTest is RecordedOrderReceipts {

    MockPyth mockPyth;
    bytes32 constant FEED_JPY = bytes32(uint256(0xAA));
    bytes32 constant FEED_EUR = bytes32(uint256(0xBB));

    function setUp() public {
        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);
        vm.warp(1001);
    }

    function test_InvertedFeedUsesCorrectPrice() public {
        _startRecordingLogs();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 638_163;
        bool[] memory inv = new bool[](1);
        inv[0] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);
        vm.warp(1001);
        (uint256 price,) = harness.computeBasketPrice(60, 60);

        uint256 expectedNorm = (uint256(1e29) + (156_700 / 2)) / 156_700 / 1e18;
        uint256 expectedBasket = (expectedNorm * 1e18) / (uint256(638_163) * 1e10);
        assertEq(price, expectedBasket, "Inverted JPY should produce correct basket price");
    }

    function test_InversionsLengthMismatchReverts() public {
        _startRecordingLogs();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_JPY;
        ids[1] = FEED_EUR;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 1e8;
        b[1] = 1e8;
        bool[] memory inv = new bool[](1);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__ArrayLengthMismatch.selector);
        new BasketPriceHarness(address(mockPyth), ids, w, b, inv);
    }

    function test_MixedInversionsComputeCorrectBasket() public {
        _startRecordingLogs();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_EUR;
        ids[1] = FEED_JPY;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 108_000_000;
        b[1] = 638_163;
        bool[] memory inv = new bool[](2);
        inv[0] = false;
        inv[1] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_EUR, int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);

        vm.warp(1001);
        (uint256 price,) = harness.computeBasketPrice(60, 60);

        assertApproxEqAbs(price, 100_000_000, 100, "Mixed basket at base prices should be ~$1.00");
    }

}
