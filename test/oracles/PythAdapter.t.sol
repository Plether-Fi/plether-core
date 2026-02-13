// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";
import {PythAdapter} from "../../src/oracles/PythAdapter.sol";
import {Test} from "forge-std/Test.sol";

contract MockPyth is IPyth {

    mapping(bytes32 => PythStructs.Price) public prices;
    uint256 public updateFee = 1;

    function setPrice(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        uint256 publishTime
    ) external {
        prices[id] = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setUpdateFee(
        uint256 fee
    ) external {
        updateFee = fee;
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory) {
        return prices[id];
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint256
    ) external view returns (PythStructs.Price memory) {
        return prices[id];
    }

    function updatePriceFeeds(
        bytes[] calldata
    ) external payable {
        require(msg.value >= updateFee, "Insufficient fee");
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256) {
        return updateFee * updateData.length;
    }

}

contract PythAdapterTest is Test {

    PythAdapter public adapter;
    MockPyth public mockPyth;

    receive() external payable {}

    bytes32 constant SEK_USD_PRICE_ID = 0x1e26d4d9c56cb6a7e60d498b4ed4c21eb47e42f25c2b895bebe6c5a040ba129f;
    uint256 constant MAX_STALENESS = 1 hours;
    int64 constant SEK_PRICE = 10_860_000; // $0.1086 in 8 decimals

    uint256 constant MAX_CONFIDENCE_BPS = 500; // 5%

    function setUp() public {
        mockPyth = new MockPyth();
        adapter =
            new PythAdapter(address(mockPyth), SEK_USD_PRICE_ID, MAX_STALENESS, "SEK / USD", false, MAX_CONFIDENCE_BPS);

        // Set initial price with -8 exponent (already 8 decimals)
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, 100_000, -8, block.timestamp);
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(adapter.PYTH()), address(mockPyth));
        assertEq(adapter.PRICE_ID(), SEK_USD_PRICE_ID);
        assertEq(adapter.MAX_STALENESS(), MAX_STALENESS);
        assertEq(adapter.INVERSE(), false);
    }

    function test_Description_ReturnsCorrectValue() public view {
        assertEq(adapter.description(), "SEK / USD");
    }

    function test_LatestRoundData_ReturnsCorrectPrice() public view {
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, SEK_PRICE);
    }

    function test_LatestRoundData_ReturnsCorrectTimestamp() public {
        vm.warp(1000);
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, 100_000, -8, 1000);

        (,, uint256 startedAt, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(startedAt, 1000);
        assertEq(updatedAt, 1000);
    }

    function test_LatestRoundData_ReturnsRoundId1() public view {
        (uint80 roundId,,,, uint80 answeredInRound) = adapter.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
    }

    function test_LatestRoundData_ConvertsExpoMinus6To8Decimals() public {
        // Price with -6 exponent (6 decimals): 108600 = $0.1086
        mockPyth.setPrice(SEK_USD_PRICE_ID, 108_600, 1000, -6, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();
        // Should be converted to 8 decimals: 108600 * 10^2 = 10860000
        assertEq(answer, 10_860_000);
    }

    function test_LatestRoundData_ConvertsExpoMinus10To8Decimals() public {
        // Price with -10 exponent (10 decimals): 1086000000 = $0.1086
        mockPyth.setPrice(SEK_USD_PRICE_ID, 1_086_000_000, 100_000, -10, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();
        // Should be converted to 8 decimals: 1086000000 / 10^2 = 10860000
        assertEq(answer, 10_860_000);
    }

    function test_LatestRoundData_RevertsOnStalePrice() public {
        vm.warp(MAX_STALENESS + 100);
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, 100_000, -8, 1); // Very old timestamp

        vm.expectRevert(abi.encodeWithSelector(PythAdapter.PythAdapter__StalePrice.selector, 1, MAX_STALENESS));
        adapter.latestRoundData();
    }

    function test_LatestRoundData_RevertsOnZeroPublishTime() public {
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, 100_000, -8, 0);

        vm.expectRevert(abi.encodeWithSelector(PythAdapter.PythAdapter__StalePrice.selector, 0, MAX_STALENESS));
        adapter.latestRoundData();
    }

    function test_LatestRoundData_RevertsOnZeroPrice() public {
        mockPyth.setPrice(SEK_USD_PRICE_ID, 0, 100_000, -8, block.timestamp);

        vm.expectRevert(PythAdapter.PythAdapter__InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_LatestRoundData_RevertsOnNegativePrice() public {
        mockPyth.setPrice(SEK_USD_PRICE_ID, -1, 100_000, -8, block.timestamp);

        vm.expectRevert(PythAdapter.PythAdapter__InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_LatestRoundData_RevertsOnWideConfidence() public {
        // conf = 10% of price → exceeds 5% threshold
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, uint64(uint64(SEK_PRICE) / 10), -8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                PythAdapter.PythAdapter__ConfidenceTooWide.selector, uint64(uint64(SEK_PRICE) / 10), SEK_PRICE
            )
        );
        adapter.latestRoundData();
    }

    function test_LatestRoundData_AcceptsNarrowConfidence() public {
        // conf = 1% of price → well within 5% threshold
        uint64 conf = uint64(uint64(SEK_PRICE) / 100);
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, conf, -8, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, SEK_PRICE);
    }

    function test_LatestRoundData_AcceptsConfidenceAtExactLimit() public {
        // conf = exactly 5% of price → at threshold boundary
        uint64 conf = uint64(uint64(SEK_PRICE) * 500 / 10_000);
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, conf, -8, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, SEK_PRICE);
    }

    function test_GetRoundData_SucceedsForRoundId1() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.getRoundData(1);

        assertEq(roundId, 1);
        assertEq(answer, SEK_PRICE);
        assertTrue(startedAt > 0);
        assertTrue(updatedAt > 0);
        assertEq(answeredInRound, 1);
    }

    function test_GetRoundData_RevertsForInvalidRoundId() public {
        vm.expectRevert(PythAdapter.PythAdapter__InvalidRoundId.selector);
        adapter.getRoundData(0);

        vm.expectRevert(PythAdapter.PythAdapter__InvalidRoundId.selector);
        adapter.getRoundData(2);

        vm.expectRevert(PythAdapter.PythAdapter__InvalidRoundId.selector);
        adapter.getRoundData(999);
    }

    function test_UpdatePrice_ForwardsToMockPyth() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        uint256 fee = adapter.getUpdateFee(updateData);
        adapter.updatePrice{value: fee}(updateData);

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, SEK_PRICE, "Price should be valid after update");
    }

    function test_UpdatePrice_RefundsExcessETH() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        uint256 fee = adapter.getUpdateFee(updateData);
        uint256 excess = 1 ether;
        uint256 balBefore = address(this).balance;

        adapter.updatePrice{value: fee + excess}(updateData);

        assertEq(address(this).balance, balBefore - fee);
        assertEq(address(adapter).balance, 0);
    }

    function test_UpdatePrice_NoRefundWhenExactFee() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        uint256 fee = adapter.getUpdateFee(updateData);
        uint256 balBefore = address(this).balance;

        adapter.updatePrice{value: fee}(updateData);

        assertEq(address(this).balance, balBefore - fee);
        assertEq(address(adapter).balance, 0);
    }

    function test_UpdatePrice_RevertsWhenRefundFails() public {
        NoReceive caller = new NoReceive();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        uint256 fee = adapter.getUpdateFee(updateData);
        vm.deal(address(caller), fee + 1 ether);

        vm.expectRevert(PythAdapter.PythAdapter__RefundFailed.selector);
        caller.callUpdate(adapter, updateData, fee + 1 ether);
    }

    function test_UpdatePrice_RevertsOnInsufficientValue() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "test";

        // Adapter will try to pay 1 wei but we send 0, causing OutOfFunds
        vm.expectRevert();
        adapter.updatePrice{value: 0}(updateData);
    }

    function test_GetUpdateFee_ReturnsCorrectFee() public view {
        bytes[] memory updateData = new bytes[](2);
        updateData[0] = "test1";
        updateData[1] = "test2";

        uint256 fee = adapter.getUpdateFee(updateData);
        assertEq(fee, 2); // 1 wei per update * 2 updates
    }

    function test_LatestRoundData_AcceptsPriceAtExactStalenessLimit() public {
        vm.warp(MAX_STALENESS + 1000);
        mockPyth.setPrice(SEK_USD_PRICE_ID, SEK_PRICE, 100_000, -8, 1000); // Exactly at limit

        // Should not revert
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, SEK_PRICE);
    }

}

contract PythAdapterInverseTest is Test {

    PythAdapter public adapter;
    MockPyth public mockPyth;

    bytes32 constant USD_SEK_PRICE_ID = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;
    uint256 constant MAX_STALENESS = 1 hours;

    function setUp() public {
        mockPyth = new MockPyth();
        adapter = new PythAdapter(address(mockPyth), USD_SEK_PRICE_ID, MAX_STALENESS, "SEK / USD", true, 500);
    }

    function test_Constructor_SetsInverseTrue() public view {
        assertEq(adapter.INVERSE(), true);
    }

    function test_LatestRoundData_InvertsPrice() public {
        // USD/SEK = 8.94849 (894849 with expo -5)
        // SEK/USD = 1 / 8.94849 ≈ 0.1118
        mockPyth.setPrice(USD_SEK_PRICE_ID, 894_849, 1000, -5, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();

        // 10^(8-(-5)) / 894849 = 10^13 / 894849 = 11175069 (integer division)
        assertEq(answer, 11_175_069);
    }

    function test_LatestRoundData_InvertsPrice_DifferentExponent() public {
        // USD/SEK = 8.94849 (89484900 with expo -7)
        mockPyth.setPrice(USD_SEK_PRICE_ID, 89_484_900, 1000, -7, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();

        // 10^(8-(-7)) / 89484900 = 10^15 / 89484900 = 11175069 (integer division)
        assertEq(answer, 11_175_069);
    }

    function test_LatestRoundData_InvertsPrice_RealWorldValue() public {
        // USD/SEK = 10.50 (1050000 with expo -5) → SEK/USD = 0.0952
        mockPyth.setPrice(USD_SEK_PRICE_ID, 1_050_000, 1000, -5, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();

        // 10^13 / 1050000 = 9523809 (~$0.0952)
        assertEq(answer, 9_523_809);
    }

    function test_LatestRoundData_InvertsPrice_StrongSEK() public {
        // USD/SEK = 8.00 (800000 with expo -5) → SEK/USD = 0.125
        mockPyth.setPrice(USD_SEK_PRICE_ID, 800_000, 1000, -5, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();

        // 10^13 / 800000 = 12500000 ($0.125)
        assertEq(answer, 12_500_000);
    }

    function test_LatestRoundData_InvertsPrice_WeakSEK() public {
        // USD/SEK = 12.00 (1200000 with expo -5) → SEK/USD = 0.0833
        mockPyth.setPrice(USD_SEK_PRICE_ID, 1_200_000, 1000, -5, block.timestamp);

        (, int256 answer,,,) = adapter.latestRoundData();

        // 10^13 / 1200000 = 8333333 (~$0.0833)
        assertEq(answer, 8_333_333);
    }

}

contract NoReceive {

    function callUpdate(
        PythAdapter adapter,
        bytes[] calldata updateData,
        uint256 value
    ) external {
        adapter.updatePrice{value: value}(updateData);
    }

}
