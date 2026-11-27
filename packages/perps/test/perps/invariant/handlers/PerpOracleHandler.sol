// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract PerpOracleHandler is Test {

    MockSettlementToken public immutable settlementToken;
    MockPyth public immutable mockPyth;
    CfdEngine public immutable engine;
    CfdEngineAdmin public immutable engineAdmin;
    MarginClearinghouse public immutable clearinghouse;
    LegacyOrderRouterHarness public immutable router;
    address public immutable owner;

    address[2] internal actors;

    uint256 public markSyncAttempts;
    uint256 public successfulMarkSyncs;
    uint256 public expectedOutOfOrderRejections;

    error PerpOracleHandler__UnexpectedSuccess();
    error PerpOracleHandler__UnexpectedRevert(bytes reason);

    constructor(
        MockSettlementToken _settlementToken,
        MockPyth _mockPyth,
        CfdEngine _engine,
        MarginClearinghouse _clearinghouse,
        LegacyOrderRouterHarness _router
    ) {
        settlementToken = _settlementToken;
        mockPyth = _mockPyth;
        engine = _engine;
        engineAdmin = CfdEngineAdmin(_engine.admin());
        clearinghouse = _clearinghouse;
        router = _router;
        owner = msg.sender;

        actors[0] = address(0x7101);
        actors[1] = address(0x7102);
    }

    function seedPositions() external {
        for (uint256 i = 0; i < actors.length; i++) {
            _ensureOpenPosition(actors[i]);
        }
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 2;
    }

    function warpToOracleBoundary(
        uint256 modeFuzz
    ) external {
        uint256 mode = modeFuzz % 26;
        uint256 target;
        if (mode == 0) {
            target = 1_772_832_599; // Spring Friday 21:29:59 UTC: before standard-time FAD
        } else if (mode == 1) {
            target = 1_772_832_600; // Spring Friday 21:30:00 UTC: standard-time FAD starts
        } else if (mode == 2) {
            target = 1_772_834_399; // Spring Friday 21:59:59 UTC: before standard-time freeze
        } else if (mode == 3) {
            target = 1_772_834_400; // Spring Friday 22:00:00 UTC: standard-time freeze starts
        } else if (mode == 4) {
            target = 1_773_003_599; // Spring Sunday 20:59:59 UTC: daylight-time freeze active
        } else if (mode == 5) {
            target = 1_773_003_600; // Spring Sunday 21:00:00 UTC: daylight-time freeze ends
        } else if (mode == 6) {
            target = 1_773_004_499; // Spring Sunday 21:14:59 UTC: FAD shoulder active
        } else if (mode == 7) {
            target = 1_773_004_500; // Spring Sunday 21:15:00 UTC: FAD shoulder ends
        } else if (mode == 8) {
            target = 1_793_392_199; // Fall Friday 20:29:59 UTC: before daylight-time FAD
        } else if (mode == 9) {
            target = 1_793_392_200; // Fall Friday 20:30:00 UTC: daylight-time FAD starts
        } else if (mode == 10) {
            target = 1_793_393_999; // Fall Friday 20:59:59 UTC: before daylight-time freeze
        } else if (mode == 11) {
            target = 1_793_394_000; // Fall Friday 21:00:00 UTC: daylight-time freeze starts
        } else if (mode == 12) {
            target = 1_793_570_399; // Fall Sunday 21:59:59 UTC: standard-time freeze active
        } else if (mode == 13) {
            target = 1_793_570_400; // Fall Sunday 22:00:00 UTC: standard-time freeze ends
        } else if (mode == 14) {
            target = 1_793_571_299; // Fall Sunday 22:14:59 UTC: FAD shoulder active
        } else if (mode == 15) {
            target = 1_793_571_300; // Fall Sunday 22:15:00 UTC: FAD shoulder ends
        } else if (mode == 16) {
            target = 1_784_753_999; // Summer overridden Wednesday: before 21:00 UTC reopen
        } else if (mode == 17) {
            target = 1_784_754_000; // Summer holiday: exact 17:00 New York reopen
        } else if (mode == 18) {
            target = 1_784_754_001; // Summer holiday: after reopen, still FAD
        } else if (mode == 19) {
            target = 1_768_427_999; // Winter overridden Wednesday: before 22:00 UTC reopen
        } else if (mode == 20) {
            target = 1_768_428_000; // Winter holiday: exact 17:00 New York reopen
        } else if (mode == 21) {
            target = 1_768_428_001; // Winter holiday: after reopen, still FAD
        } else if (mode == 22) {
            target = 1_784_764_799; // Summer holiday: last UTC second remains live
        } else if (mode == 23) {
            target = 1_768_435_199; // Winter holiday: last UTC second remains live
        } else if (mode == 24) {
            target = 1_784_764_800; // Following summer override: UTC midnight freezes again
        } else {
            target = 1_768_435_200; // Following winter override: UTC midnight freezes again
        }
        vm.warp(target);
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 10 days));
    }

    function syncMarkNow(
        uint256 priceFuzz
    ) external {
        uint256 price = bound(priceFuzz, 0.5e8, 1.5e8);
        // Boundary selection may move time backwards; a changed mark also needs a later timestamp.
        bool expectOutOfOrder = block.timestamp < engine.lastMarkTime()
            || (block.timestamp == engine.lastMarkTime() && price != engine.lastMarkPrice());
        ++markSyncAttempts;
        vm.prank(address(router));
        try engine.updateMarkPrice(price, uint64(block.timestamp)) {
            if (expectOutOfOrder) {
                revert PerpOracleHandler__UnexpectedSuccess();
            }
            ++successfulMarkSyncs;
        } catch (bytes memory reason) {
            if (
                !expectOutOfOrder
                    || keccak256(reason)
                        != keccak256(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector))
            ) {
                revert PerpOracleHandler__UnexpectedRevert(reason);
            }
            ++expectedOutOfOrderRejections;
        }
    }

    function configureFadDayTomorrow(
        uint256 runwayFuzz
    ) external {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = ((block.timestamp / 86_400) + 1) * 86_400;

        vm.startPrank(owner);
        ICfdEngineAdminHost.EngineCalendarConfig memory config;
        config.fadDayTimestamps = timestamps;
        config.fadRunwaySeconds = bound(runwayFuzz, 0, 24 hours);
        engineAdmin.proposeCalendarConfig(config);
        vm.warp(block.timestamp + 7 days);
        engineAdmin.finalizeCalendarConfig();
        vm.stopPrank();
    }

    function configureHolidayOverrides() external {
        ICfdEngineAdminHost.EngineCalendarConfig memory config;
        config.fadDayTimestamps = new uint256[](4);
        config.fadDayTimestamps[0] = 1_784_678_400; // Wednesday 2026-07-22
        config.fadDayTimestamps[1] = 1_784_764_800; // Thursday 2026-07-23
        config.fadDayTimestamps[2] = 1_768_348_800; // Wednesday 2026-01-14
        config.fadDayTimestamps[3] = 1_768_435_200; // Thursday 2026-01-15
        config.fadRunwaySeconds = 24 hours;

        vm.startPrank(owner);
        engineAdmin.proposeCalendarConfig(config);
        vm.warp(block.timestamp + 7 days);
        engineAdmin.finalizeCalendarConfig();
        vm.stopPrank();
    }

    function configureFadMaxStaleness(
        uint256 secondsFuzz
    ) external {
        uint256 seconds_ = bound(secondsFuzz, 1 hours, 7 days);
        vm.startPrank(owner);
        ICfdEngineAdminHost.EngineFreshnessConfig memory config;
        config.fadMaxStaleness = seconds_;
        config.engineMarkStalenessLimit = engine.engineMarkStalenessLimit();
        engineAdmin.proposeFreshnessConfig(config);
        vm.warp(block.timestamp + 7 days);
        engineAdmin.finalizeFreshnessConfig();
        vm.stopPrank();
    }

    function ensureActorPosition(
        uint256 actorIndex
    ) external {
        _ensureOpenPosition(actors[actorIndex % actors.length]);
    }

    function _ensureOpenPosition(
        address actor
    ) internal {
        address account = actor;
        (uint256 size,,,,,,) = engine.positions(account);
        if (size > 0) {
            return;
        }

        settlementToken.mint(actor, 25_000e6);
        uint64 orderId = router.nextCommitId();
        vm.startPrank(actor);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(account, 25_000e6);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 0, false);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        mockPyth.setUniquePrice(
            bytes32(uint256(1)), int64(100_000_000), 0, int32(-8), block.timestamp, block.timestamp - 1
        );
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode(uint256(1e8));
        router.executeOrder{value: router.pletherOracle().getOrderExecutionFee(updateData)}(orderId, updateData);
    }

}
