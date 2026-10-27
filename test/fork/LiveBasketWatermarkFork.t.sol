// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

/// @notice Exercises complete signed live baskets against the real Arbitrum Sepolia Pyth parser.
contract LiveBasketWatermarkForkTest is BasePerpTest {

    string internal fixture;
    address internal realPyth;
    bytes32[] internal ids;

    function setUp() public override {
        fixture = vm.readFile("test/fixtures/oracle-sync/live-watermark-sep22.json");
        uint256 forkNumber = vm.parseJsonUint(fixture, ".forkBlockNumber");
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), forkNumber);
        assertEq(block.chainid, 421_614);
        vm.roll(forkNumber + 1);
        assertEq(blockhash(forkNumber), vm.parseJsonBytes32(fixture, ".forkBlockHash"));
        vm.roll(forkNumber);
        assertEq(block.timestamp, vm.parseJsonUint(fixture, ".forkTimestamp"));
        realPyth = vm.parseJsonAddress(fixture, ".pyth");
        assertGt(realPyth.code.length, 0);
        ids = vm.parseJsonBytes32Array(fixture, ".feedIds");
        assertEq(ids.length, 6);

        vm.warp(SETUP_TIMESTAMP);
        super.setUp();
        pletherOracle = new ArbitrumSepoliaReleaseOracle(
            address(engine),
            address(pool),
            realPyth,
            ids,
            vm.parseJsonUintArray(fixture, ".quantities"),
            vm.parseJsonUintArray(fixture, ".basePrices"),
            abi.decode(vm.parseJson(fixture, ".inversions"), (bool[]))
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(vm.parseJsonUint(fixture, ".forkTimestamp"));
        assertGe(block.timestamp, routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        vm.deal(address(this), 10 ether);
    }

    function test_RealSignedBasketsAdvanceAndStaleDataReverts() public {
        uint256 initialCutoff = vm.parseJsonUint(fixture, ".updates.initial.cutoff");
        uint256 nextCutoff = vm.parseJsonUint(fixture, ".updates.next.cutoff");
        bytes[] memory initial = _data("initial");
        bytes[] memory next = _data("next");
        assertEq(nextCutoff, initialCutoff + 6);

        uint256[] memory storedBefore = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            storedBefore[i] = IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime;
        }
        vm.warp(initialCutoff + pletherOracle.LIVE_TICK_LOOKBACK());
        vm.roll(block.number + 1);
        assertFalse(pletherOracle.isOracleFrozen());
        uint256 fee = pletherOracle.getUpdateFee(initial);
        uint256 gasBefore = gasleft();
        router.updateMarkPrice{value: fee}(initial);
        emit log_named_uint("real Pyth first live basket call gas", gasBefore - gasleft());
        _assertAccepted(initialCutoff);
        assertGt(pletherOracle.getLatestPrice(), 0);

        assertEq(pletherOracle.getUpdateFee(new bytes[](0)), 0);
        router.updateMarkPrice(new bytes[](0));
        _assertAccepted(initialCutoff);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(
                IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime,
                storedBefore[i],
                "live parse must not mutate Pyth storage"
            );
        }

        vm.warp(nextCutoff + pletherOracle.LIVE_TICK_LOOKBACK());
        vm.roll(block.number + 1);
        uint256 staleFee = pletherOracle.getUpdateFee(initial);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        IPyth(realPyth).parsePriceFeedUpdates{value: staleFee}(
            initial, ids, uint64(nextCutoff), uint64(block.timestamp)
        );
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        router.updateMarkPrice{value: staleFee}(initial);
        _assertAccepted(initialCutoff);

        fee = pletherOracle.getUpdateFee(next);
        gasBefore = gasleft();
        router.updateMarkPrice{value: fee}(next);
        emit log_named_uint("real Pyth next live basket call gas", gasBefore - gasleft());
        _assertAccepted(nextCutoff);
    }

    function test_RealSignedUnequalTimesReuseFasterFeedAndAdvanceWatermark() public {
        string memory uneven = vm.readFile("test/fixtures/oracle-sync/live-watermark-uneven.json");
        bytes[] memory first = _mixedData(uneven, "lagging");
        uint256 fastTime = vm.parseJsonUintArray(uneven, ".updates.fast.publishTimes")[0];
        uint256 slowTime = vm.parseJsonUintArray(uneven, ".updates.lagging.publishTimes")[0];
        uint256 caughtUpTime = vm.parseJsonUintArray(uneven, ".updates.caughtUp.publishTimes")[0];
        assertLt(slowTime, fastTime);
        assertGt(caughtUpTime, fastTime);
        uint256[] memory storedBefore = _storedTimes();

        vm.warp(slowTime + pletherOracle.LIVE_TICK_LOOKBACK());
        router.updateMarkPrice{value: pletherOracle.getUpdateFee(first)}(first);
        _assertUnequalAccepted(fastTime, slowTime, fastTime);

        // Only the five slower feeds advance. The first feed's exact signed bytes are reused.
        bytes[] memory caughtUp = _mixedData(uneven, "caughtUp");
        assertEq(keccak256(first[0]), keccak256(caughtUp[0]));
        vm.warp(vm.getBlockTimestamp() + 1);
        router.updateMarkPrice{value: pletherOracle.getUpdateFee(caughtUp)}(caughtUp);
        _assertUnequalAccepted(fastTime, caughtUpTime, caughtUpTime);

        uint256 acceptedPrice = engine.lastMarkPrice();
        router.updateMarkPrice(new bytes[](0));
        assertEq(engine.lastMarkPrice(), acceptedPrice);
        _assertUnequalAccepted(fastTime, caughtUpTime, caughtUpTime);
        _assertStoredTimes(storedBefore);
    }

    function test_RealSignedMissingAndRegressedComponentsPreserveAcceptedBasket() public {
        string memory uneven = vm.readFile("test/fixtures/oracle-sync/live-watermark-uneven.json");
        bytes[] memory complete = _mixedData(uneven, "caughtUp");
        uint256 fastTime = vm.parseJsonUintArray(uneven, ".updates.fast.publishTimes")[0];
        uint256 caughtUpTime = vm.parseJsonUintArray(uneven, ".updates.caughtUp.publishTimes")[0];
        uint256 slowTime = vm.parseJsonUintArray(uneven, ".updates.lagging.publishTimes")[0];
        vm.warp(slowTime + pletherOracle.LIVE_TICK_LOOKBACK());
        uint256[] memory storedBefore = _storedTimes();
        bytes[] memory missing = new bytes[](1);
        missing[0] = complete[0];
        uint256 fee = pletherOracle.getUpdateFee(missing);
        uint256 markBefore = engine.lastMarkPrice();
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        router.updateMarkPrice{value: fee}(missing);
        (bool accepted,,) = pletherOracle.getAcceptedBasketMark();
        assertFalse(accepted, "Stored Pyth feeds cannot fill omitted signed components");
        assertEq(engine.lastMarkPrice(), markBefore);

        router.updateMarkPrice{value: pletherOracle.getUpdateFee(complete)}(complete);
        _assertUnequalAccepted(fastTime, caughtUpTime, caughtUpTime);
        uint256 acceptedPrice = engine.lastMarkPrice();

        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        router.updateMarkPrice{value: fee}(missing);
        assertEq(engine.lastMarkPrice(), acceptedPrice);
        _assertUnequalAccepted(fastTime, caughtUpTime, caughtUpTime);

        bytes[] memory regressed = _mixedData(uneven, "lagging");
        fee = pletherOracle.getUpdateFee(regressed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__FeedTimeOutOfOrder.selector, ids[1], slowTime, caughtUpTime
            )
        );
        router.updateMarkPrice{value: fee}(regressed);
        assertEq(engine.lastMarkPrice(), acceptedPrice);
        _assertUnequalAccepted(fastTime, caughtUpTime, caughtUpTime);
        _assertStoredTimes(storedBefore);
    }

    function _mixedData(
        string memory uneven,
        string memory rest
    ) internal pure returns (bytes[] memory data) {
        data = new bytes[](2);
        data[0] = _subset(uneven, "fast");
        data[1] = _subset(uneven, rest);
    }

    function _subset(
        string memory uneven,
        string memory name
    ) internal pure returns (bytes memory payload) {
        string memory key = string.concat(".updates.", name);
        bytes[] memory data = abi.decode(vm.parseJson(uneven, string.concat(key, ".updateData")), (bytes[]));
        assertEq(data.length, 1);
        payload = data[0];
        assertEq(sha256(payload), vm.parseJsonBytes32(uneven, string.concat(key, ".payloadSha256")));
    }

    function _assertUnequalAccepted(
        uint256 first,
        uint256 rest,
        uint256 watermark
    ) internal view {
        (bool accepted, uint256 price, uint64 publishTime) = pletherOracle.getAcceptedBasketMark();
        assertTrue(accepted);
        assertGt(price, 0);
        assertEq(publishTime, watermark);
        assertEq(engine.lastMarkTime(), watermark);
        assertEq(engine.lastMarkPrice(), price);
        uint256[] memory times = pletherOracle.getAcceptedFeedPublishTimes();
        assertEq(times.length, ids.length);
        assertEq(times[0], first);
        for (uint256 i = 1; i < ids.length; ++i) {
            assertEq(times[i], rest);
        }
    }

    function _storedTimes() internal view returns (uint256[] memory times) {
        times = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            times[i] = IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime;
        }
    }

    function _assertStoredTimes(
        uint256[] memory expected
    ) internal view {
        for (uint256 i; i < ids.length; ++i) {
            assertEq(IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime, expected[i]);
        }
    }

    function _data(
        string memory name
    ) internal view returns (bytes[] memory) {
        return abi.decode(vm.parseJson(fixture, string.concat(".updates.", name, ".updateData")), (bytes[]));
    }

    function _assertAccepted(
        uint256 expectedTime
    ) internal view {
        (bool accepted, uint256 price, uint64 publishTime) = pletherOracle.getAcceptedBasketMark();
        assertTrue(accepted);
        assertEq(publishTime, expectedTime);
        assertEq(engine.lastMarkTime(), expectedTime);
        assertEq(engine.lastMarkPrice(), price);
        uint256[] memory feedTimes = pletherOracle.getAcceptedFeedPublishTimes();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(feedTimes[i], expectedTime);
        }
    }

}
