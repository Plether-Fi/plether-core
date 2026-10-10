// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract OracleSynchronizationHandler is Test {

    LegacyOrderRouterHarness internal immutable router;
    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    MockPyth internal immutable pyth;
    MockUSDC internal immutable usdc;
    bytes32[] internal ids;
    uint256 public resolutions;
    bool public coverageViolation;

    constructor(
        LegacyOrderRouterHarness r,
        CfdEngine e,
        MarginClearinghouse c,
        MockPyth p,
        MockUSDC u,
        bytes32[] memory feeds
    ) {
        router = r;
        engine = e;
        clearinghouse = c;
        pyth = p;
        usdc = u;
        ids = feeds;
    }

    function execute(
        uint64 priceSeed,
        uint8 delaySeed,
        bool skipWrite,
        bool failWrite
    ) external {
        uint64 commit = uint64(block.timestamp);
        address trader = address(uint160(100_000 + router.nextCommitId()));
        usdc.mint(trader, 2000e6);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 2000e6);
        clearinghouse.deposit(trader, 2000e6);
        uint64 id = router.commitOrder(CfdTypes.Side(uint8(router.nextCommitId() % 2)), 2000e18, 500e6, 0, false);
        vm.stopPrank();
        uint64 tick = commit + 1 + delaySeed % 10;
        vm.warp(tick);
        vm.roll(block.number + 1);
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            updates[i] = MockPyth.FeedUpdate(
                ids[i], MockPyth.MockPrice(int64(uint64(99_000_000 + priceSeed % 2_000_001)), 0, -8, tick, commit)
            );
        }
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(updates);
        pyth.setUpdateFailure(failWrite, skipWrite, bytes32(0));
        uint64 beforeMark = engine.lastMarkTime();
        try router.executeOrder(id, data) {
            _recordCoverage();
        } catch {
            if (engine.lastMarkTime() != beforeMark) {
                coverageViolation = true;
            }
        }
        pyth.setUpdateFailure(false, false, bytes32(0));
        // Resolve a failed synchronization so later generated orders keep exercising the oracle path.
        if (router.nextExecuteId() == id) {
            try router.executeOrder(id, data) {
                _recordCoverage();
            } catch {}
        }
    }

    function _recordCoverage() internal {
        ++resolutions;
        for (uint256 i; i < ids.length; ++i) {
            if (pyth.getPriceUnsafe(ids[i]).publishTime < engine.lastMarkTime()) {
                coverageViolation = true;
            }
        }
    }

}
