// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SettlementMonitorLensTestFixture} from "../../shared/SettlementMonitorLensFixture.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";

/// @dev Normative spec: SECURITY.md, Settlement Monitor Trust Boundary.
contract SettlementMonitorCalendarDigestTest is SettlementMonitorLensTestFixture {

    bytes4 internal constant ACTIVE_CONFIG_VERSION_SELECTOR = bytes4(keccak256("activeConfigVersion()"));
    bytes4 internal constant ENGINE_ADMIN_SELECTOR = bytes4(keccak256("admin()"));

    function test_CalendarOnlyAddReplaceAndClearChangeConfigDigest() public {
        bytes32 initialDigest = monitorLens.observableConfigDigest();
        uint256 runway = engine.fadRunwaySeconds();
        uint256 firstDay = (block.timestamp / 1 days) + 30;
        uint256 secondDay = firstDay + 1;
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](1);
        config.fadDayTimestamps[0] = firstDay * 1 days;

        bytes32 addedDigest = _finalizeCalendarAndAssertConfigChanged(config, initialDigest);
        assertTrue(engine.fadDayOverrides(firstDay));
        assertEq(engine.fadRunwaySeconds(), runway);

        config.fadDayTimestamps[0] = secondDay * 1 days;
        bytes32 replacedDigest = _finalizeCalendarAndAssertConfigChanged(config, addedDigest);
        assertFalse(engine.fadDayOverrides(firstDay));
        assertTrue(engine.fadDayOverrides(secondDay));
        assertEq(engine.fadRunwaySeconds(), runway);

        config.fadDayTimestamps = new uint256[](0);
        bytes32 clearedDigest = _finalizeCalendarAndAssertConfigChanged(config, replacedDigest);
        assertFalse(engine.fadDayOverrides(firstDay));
        assertFalse(engine.fadDayOverrides(secondDay));
        assertEq(engine.fadRunwaySeconds(), runway);
        assertTrue(
            clearedDigest != initialDigest, "a finalized revision remains observable after restoring the old days"
        );
    }

    function test_PendingCancelledAndPrematureCalendarChangesKeepConfigDigest() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        uint64 version = engineAdmin.activeConfigVersion();
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](1);
        config.fadDayTimestamps[0] = block.timestamp + 30 days;

        engineAdmin.proposeCalendarConfig(config);
        _assertConfigDigest(originalDigest);
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TimelockNotReady.selector);
        engineAdmin.finalizeCalendarConfig();
        _assertConfigDigest(originalDigest);

        config.fadDayTimestamps[0] += 1 days;
        engineAdmin.proposeCalendarConfig(config);
        _assertConfigDigest(originalDigest);
        engineAdmin.cancelCalendarConfig();
        _assertConfigDigest(originalDigest);
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeCalendarConfig();
        _assertConfigDigest(originalDigest);
        assertEq(engineAdmin.activeConfigVersion(), version);
    }

    function test_RevertingCalendarApplicationKeepsConfigDigest() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        uint64 version = engineAdmin.activeConfigVersion();
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](1);
        config.fadDayTimestamps[0] = block.timestamp + 30 days;
        engineAdmin.proposeCalendarConfig(config);
        vm.warp(engineAdmin.calendarConfigActivationTime());
        vm.mockCallRevert(
            address(engine),
            abi.encodeWithSelector(ICfdEngineAdminHost.applyCalendarConfig.selector),
            bytes("apply failed")
        );

        vm.expectRevert(bytes("apply failed"));
        engineAdmin.finalizeCalendarConfig();

        _assertConfigDigest(originalDigest);
        assertEq(engineAdmin.activeConfigVersion(), version);
        assertTrue(engineAdmin.calendarConfigActivationTime() != 0, "failed application must retain the proposal");
        assertFalse(engine.fadDayOverrides(config.fadDayTimestamps[0] / 1 days));
    }

    function test_UnreadableActiveConfigVersionFailsClosed() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        vm.mockCallRevert(
            address(engineAdmin), abi.encodeWithSelector(ACTIVE_CONFIG_VERSION_SELECTOR), bytes("unreadable")
        );

        _assertConfigUnavailable();

        vm.clearMockedCalls();
        _assertConfigDigest(originalDigest);
    }

    function test_MalformedActiveConfigVersionFailsClosed() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        bytes[] memory malformed = new bytes[](3);
        malformed[0] = new bytes(0);
        malformed[1] = new bytes(31);
        malformed[2] = abi.encode(uint256(1), uint256(1));
        for (uint256 i; i < malformed.length; ++i) {
            vm.mockCall(address(engineAdmin), abi.encodeWithSelector(ACTIVE_CONFIG_VERSION_SELECTOR), malformed[i]);
            _assertConfigUnavailable();
            vm.clearMockedCalls();
            _assertConfigDigest(originalDigest);
        }
    }

    function test_NoncanonicalActiveConfigVersionFailsClosed() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        uint256[2] memory invalid = [uint256(0), uint256(type(uint64).max) + 1];
        for (uint256 i; i < invalid.length; ++i) {
            vm.mockCall(
                address(engineAdmin), abi.encodeWithSelector(ACTIVE_CONFIG_VERSION_SELECTOR), abi.encode(invalid[i])
            );
            _assertConfigUnavailable();
            vm.clearMockedCalls();
            _assertConfigDigest(originalDigest);
        }
    }

    function test_MaximumActiveConfigVersionRemainsReadable() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        vm.mockCall(
            address(engineAdmin), abi.encodeWithSelector(ACTIVE_CONFIG_VERSION_SELECTOR), abi.encode(type(uint64).max)
        );

        bytes32 maximumVersionDigest = monitorLens.observableConfigDigest();
        assertTrue(maximumVersionDigest != bytes32(0));
        assertTrue(maximumVersionDigest != originalDigest);
        _assertConfigDigest(maximumVersionDigest);
    }

    function test_MissingAdminCodeFailsClosed() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        bytes memory adminCode = address(engineAdmin).code;
        vm.etch(address(engineAdmin), bytes(""));

        _assertConfigUnavailable();

        vm.etch(address(engineAdmin), adminCode);
        _assertConfigDigest(originalDigest);
    }

    function test_UnreadableAndMalformedEngineAdminFailClosed() public {
        bytes32 originalDigest = monitorLens.observableConfigDigest();
        vm.mockCallRevert(address(engine), abi.encodeWithSelector(ENGINE_ADMIN_SELECTOR), bytes("unreadable"));
        _assertConfigUnavailable();
        vm.clearMockedCalls();
        _assertConfigDigest(originalDigest);

        bytes[] memory malformed = new bytes[](4);
        malformed[0] = new bytes(0);
        malformed[1] = new bytes(31);
        malformed[2] = abi.encode(address(engineAdmin), uint256(1));
        malformed[3] = abi.encode(uint256(type(uint160).max) + 1);
        for (uint256 i; i < malformed.length; ++i) {
            vm.mockCall(address(engine), abi.encodeWithSelector(ENGINE_ADMIN_SELECTOR), malformed[i]);
            _assertConfigUnavailable();
            vm.clearMockedCalls();
            _assertConfigDigest(originalDigest);
        }
    }

    function _finalizeCalendarAndAssertConfigChanged(
        ICfdEngineAdminHost.EngineCalendarConfig memory config,
        bytes32 previousDigest
    ) internal returns (bytes32 nextDigest) {
        uint64 version = engineAdmin.activeConfigVersion();
        engineAdmin.proposeCalendarConfig(config);
        vm.warp(engineAdmin.calendarConfigActivationTime());
        _assertConfigDigest(previousDigest);
        uint256 observedEpoch = pool.currentLpEpoch();
        SettlementMonitorViewTypes.SettlementObservation memory beforeFinalization =
            monitorLens.getSettlementObservation(observedEpoch);

        engineAdmin.finalizeCalendarConfig();

        assertEq(engineAdmin.activeConfigVersion(), version + 1);
        nextDigest = monitorLens.observableConfigDigest();
        assertTrue(nextDigest != bytes32(0));
        assertTrue(nextDigest != previousDigest, "calendar-only finalization must change the configuration fingerprint");
        _assertConfigDigest(nextDigest);
        SettlementMonitorViewTypes.SettlementObservation memory afterFinalization =
            monitorLens.getSettlementObservation(observedEpoch);
        assertTrue(
            afterFinalization.observationDigest != beforeFinalization.observationDigest,
            "the composite observation must commit to the calendar revision"
        );
    }

    function _assertConfigDigest(
        bytes32 expected
    ) internal view {
        assertTrue(expected != bytes32(0));
        assertEq(monitorLens.observableConfigDigest(), expected);
        uint256 observedEpoch = pool.currentLpEpoch();
        SettlementMonitorViewTypes.SettlementObservation memory first =
            monitorLens.getSettlementObservation(observedEpoch);
        SettlementMonitorViewTypes.SettlementObservation memory second =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(first.observableConfigDigest, expected);
        assertEq(second.observableConfigDigest, expected);
        assertEq(
            first.observationDigest, second.observationDigest, "unchanged same-block observations are deterministic"
        );
    }

    function _assertConfigUnavailable() internal view {
        assertEq(monitorLens.observableConfigDigest(), bytes32(0));
        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(pool.currentLpEpoch());
        assertEq(observation.observableConfigDigest, bytes32(0));
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

}
