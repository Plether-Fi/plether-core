// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTreasury} from "@plether/perps/CfdTreasury.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {LegacyTreasuryReference} from "../../shared/LegacyTreasuryReference.sol";

contract TreasuryStateMachineHarness is CfdTreasury {}

contract TreasuryStateMachineTest is Test {

    address internal constant TREASURY_A = address(0xFEE90);
    address internal constant TREASURY_B = address(0xFEE91);
    address internal constant TREASURY_C = address(0xFEE92);
    address internal constant NEXT_OWNER = address(0xA11CE);
    address internal constant STRANGER = address(0xBAD);

    TreasuryStateMachineHarness internal treasury;
    LegacyTreasuryReference internal legacy;

    function setUp() public {
        vm.warp(1_000_000);
        treasury = new TreasuryStateMachineHarness();
        legacy = new LegacyTreasuryReference();
        _assertEquivalentState();
    }

    function testFuzz_TreasuryStateMachine_MatchesLegacyAcrossOperationSequences(
        bytes32 seed
    ) public {
        // Begin with a cancellable schedule so every sequence exercises an actual pending record.
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_A, 90 days));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_B, 30 days)));

        for (uint256 step; step < 32; ++step) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, step)));
            if (entropy % 3 == 0) {
                _advanceTime(entropy >> 32);
                _assertEquivalentState();
            }
            _callBoth(_caller(entropy >> 8), _operation(entropy, step));
        }
    }

    function test_TreasuryStateMachine_CancelReproposeAndMaturedSyncPreserveCountdown() public {
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_A, 90 days));
        uint256 firstExpiry = treasury.protocolTreasuryLockedUntil();
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_B, 30 days)));
        vm.warp(firstExpiry - 1);
        _callBoth(address(this), abi.encodeCall(treasury.cancelProtocolTreasuryProposal, ()));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_C, 60 days)));
        assertEq(treasury.protocolTreasuryLockedUntil(), firstExpiry);

        vm.warp(firstExpiry);
        _assertEquivalentState();
        assertEq(treasury.protocolTreasury(), TREASURY_C);
        uint256 secondExpiry = firstExpiry + 60 days;
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_A, 7 days)));
        _callBoth(address(this), abi.encodeCall(treasury.cancelProtocolTreasuryProposal, ()));
        assertEq(treasury.protocolTreasury(), TREASURY_C);
        assertEq(treasury.protocolTreasuryLockedUntil(), secondExpiry);

        vm.warp(secondExpiry);
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address)", TREASURY_B));
        assertEq(treasury.protocolTreasuryLockedUntil(), secondExpiry, "Immediate update retains elapsed expiry");
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_B, 3 days));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_A, 0)));
        uint256 thirdExpiry = treasury.protocolTreasuryLockedUntil();
        vm.warp(thirdExpiry);
        _assertEquivalentState();
        assertEq(treasury.protocolTreasury(), TREASURY_A);
        assertEq(treasury.protocolTreasuryLockedUntil(), thirdExpiry);
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address)", TREASURY_A));
    }

    function test_TreasuryStateMachine_RevertedSynchronizationPreservesErrorsAndActivatedTreasury() public {
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_A, 90 days));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_B, 30 days)));
        vm.warp(treasury.protocolTreasuryLockedUntil());

        (bool success, bytes memory result) =
            _callBoth(address(this), abi.encodeCall(treasury.cancelProtocolTreasuryProposal, ()));
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_C, type(uint256).max)));
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (address(0), 0)));
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", address(0), 0));
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address)", address(0)));
        assertEq(treasury.protocolTreasury(), TREASURY_B);

        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_C, 0)));
        vm.warp(treasury.protocolTreasuryLockedUntil());
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address)", address(0)));
        _callBoth(
            address(this),
            abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_A, type(uint256).max)
        );
        assertEq(treasury.protocolTreasury(), TREASURY_C);
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address)", TREASURY_A));
    }

    function test_TreasuryStateMachine_OwnershipAndRenunciationKeepScheduledActivation() public {
        _callBoth(address(this), abi.encodeWithSignature("setProtocolTreasury(address,uint256)", TREASURY_A, 90 days));
        uint256 activation = treasury.protocolTreasuryLockedUntil();
        _callBoth(address(this), abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_B, 30 days)));
        _callBoth(address(this), abi.encodeCall(treasury.transferOwnership, (NEXT_OWNER)));
        _callBoth(STRANGER, abi.encodeCall(treasury.acceptOwnership, ()));
        _callBoth(NEXT_OWNER, abi.encodeCall(treasury.acceptOwnership, ()));
        _callBoth(address(this), abi.encodeCall(treasury.cancelProtocolTreasuryProposal, ()));
        _callBoth(NEXT_OWNER, abi.encodeCall(treasury.proposeProtocolTreasury, (TREASURY_C, 7 days)));
        _callBoth(NEXT_OWNER, abi.encodeCall(treasury.transferOwnership, (STRANGER)));
        _callBoth(NEXT_OWNER, abi.encodeCall(treasury.renounceOwnership, ()));
        assertEq(treasury.owner(), address(0));
        assertEq(treasury.pendingOwner(), address(0));

        vm.warp(activation);
        _assertEquivalentState();
        assertEq(treasury.protocolTreasury(), TREASURY_C);
        assertEq(treasury.protocolTreasuryLockedUntil(), activation + 7 days);
        _callBoth(STRANGER, abi.encodeCall(treasury.acceptOwnership, ()));
        _callBoth(NEXT_OWNER, abi.encodeWithSignature("setProtocolTreasury(address)", TREASURY_A));
    }

    function _operation(
        uint256 entropy,
        uint256 step
    ) internal view returns (bytes memory) {
        uint256 operation = entropy % 10;
        address account = _treasuryAddress(entropy >> 16);
        uint256 duration = _duration(entropy >> 64);
        if (operation == 0) {
            return abi.encodeWithSignature("setProtocolTreasury(address)", account);
        }
        if (operation <= 2) {
            return abi.encodeWithSignature("setProtocolTreasury(address,uint256)", account, duration);
        }
        if (operation <= 4) {
            return abi.encodeCall(treasury.proposeProtocolTreasury, (account, duration));
        }
        if (operation == 5) {
            return abi.encodeCall(treasury.cancelProtocolTreasuryProposal, ());
        }
        if (operation == 6) {
            return abi.encodeCall(treasury.transferOwnership, (account));
        }
        if (operation == 7) {
            return abi.encodeCall(treasury.acceptOwnership, ());
        }
        if (operation == 8 && step >= 24) {
            return abi.encodeCall(treasury.renounceOwnership, ());
        }
        return abi.encodeCall(treasury.proposeProtocolTreasury, (account, duration));
    }

    function _caller(
        uint256 entropy
    ) internal view returns (address) {
        uint256 choice = entropy % 4;
        address currentOwner = treasury.owner();
        if (choice < 2 && currentOwner != address(0)) {
            return currentOwner;
        }
        if (choice == 2) {
            address pendingOwner = treasury.pendingOwner();
            return pendingOwner == address(0) ? NEXT_OWNER : pendingOwner;
        }
        // Never impersonate address(0), which could artificially revive renounced ownership.
        return STRANGER;
    }

    function _treasuryAddress(
        uint256 entropy
    ) internal view returns (address) {
        uint256 choice = entropy % 5;
        if (choice == 0) {
            return address(0);
        }
        if (choice == 1) {
            return treasury.protocolTreasury();
        }
        if (choice == 2) {
            return TREASURY_A;
        }
        if (choice == 3) {
            return TREASURY_B;
        }
        return address(uint160(entropy >> 8));
    }

    function _duration(
        uint256 entropy
    ) internal pure returns (uint256) {
        uint256 choice = entropy % 6;
        if (choice == 0) {
            return 0;
        }
        if (choice == 1) {
            return 1;
        }
        if (choice == 2) {
            return 1 days;
        }
        if (choice == 3) {
            return 30 days;
        }
        if (choice == 4) {
            return type(uint256).max;
        }
        return 1 + entropy % 365 days;
    }

    function _advanceTime(
        uint256 entropy
    ) internal {
        uint256 expiry = treasury.protocolTreasuryLockedUntil();
        uint256 target;
        uint256 choice = entropy % 5;
        if (choice == 0) {
            target = expiry == 0 ? 0 : expiry - 1;
        } else if (choice == 1) {
            target = expiry;
        } else if (choice == 2) {
            target = expiry + 1;
        } else if (choice == 3) {
            (,, uint256 nextExpiry) = treasury.pendingProtocolTreasury();
            target = nextExpiry + 1;
        } else {
            target = block.timestamp + 1 + entropy % 30 days;
        }
        if (target > block.timestamp) {
            vm.warp(target);
        }
    }

    function _callBoth(
        address caller,
        bytes memory data
    ) internal returns (bool success, bytes memory result) {
        vm.recordLogs();
        vm.prank(caller);
        (bool legacySuccess, bytes memory legacyResult) = address(legacy).call(data);
        Vm.Log[] memory legacyLogs = vm.getRecordedLogs();

        vm.recordLogs();
        vm.prank(caller);
        (success, result) = address(treasury).call(data);
        Vm.Log[] memory currentLogs = vm.getRecordedLogs();

        assertEq(success, legacySuccess, "Call success differs from legacy treasury");
        assertEq(result, legacyResult, "Return or revert data differs from legacy treasury");
        assertEq(currentLogs.length, legacyLogs.length, "Event count differs from legacy treasury");
        for (uint256 i; i < currentLogs.length; ++i) {
            assertEq(currentLogs[i].emitter, address(treasury), "Current event must come from the host contract");
            assertEq(legacyLogs[i].emitter, address(legacy), "Legacy event must come from the host contract");
            assertEq(currentLogs[i].topics, legacyLogs[i].topics, "Event topics differ from legacy treasury");
            assertEq(currentLogs[i].data, legacyLogs[i].data, "Event data differs from legacy treasury");
        }
        _assertEquivalentState();
    }

    function _assertEquivalentState() internal view {
        assertEq(treasury.protocolTreasury(), legacy.protocolTreasury(), "Effective treasury differs");
        assertEq(treasury.protocolTreasuryLockedUntil(), legacy.protocolTreasuryLockedUntil(), "Effective lock differs");
        (address account, uint256 activation, uint256 expiry) = treasury.pendingProtocolTreasury();
        (address oldAccount, uint256 oldActivation, uint256 oldExpiry) = legacy.pendingProtocolTreasury();
        assertEq(account, oldAccount, "Pending treasury differs");
        assertEq(activation, oldActivation, "Pending activation differs");
        assertEq(expiry, oldExpiry, "Pending lock differs");
        assertEq(treasury.owner(), legacy.owner(), "Owner differs");
        assertEq(treasury.pendingOwner(), legacy.pendingOwner(), "Pending owner differs");
    }

}
