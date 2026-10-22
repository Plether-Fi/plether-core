// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
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
        vm.expectRevert();
        IPyth(realPyth).parsePriceFeedUpdates{value: staleFee}(
            initial, ids, uint64(nextCutoff), uint64(block.timestamp)
        );
        vm.expectRevert();
        router.updateMarkPrice{value: staleFee}(initial);
        _assertAccepted(initialCutoff);

        fee = pletherOracle.getUpdateFee(next);
        gasBefore = gasleft();
        router.updateMarkPrice{value: fee}(next);
        emit log_named_uint("real Pyth next live basket call gas", gasBefore - gasleft());
        _assertAccepted(nextCutoff);
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
