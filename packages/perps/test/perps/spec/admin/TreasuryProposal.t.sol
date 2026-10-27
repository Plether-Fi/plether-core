// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract TreasuryProposalTest is CfdEngineTestBase {

    address internal constant TREASURY_A = address(0xFEE90);
    address internal constant TREASURY_B = address(0xFEE91);
    address internal constant TREASURY_C = address(0xFEE92);

    function test_TreasuryProposal_RecordsOriginalExpiryWithoutChangingActiveTreasury() public {
        uint256 expiry = _lockTreasury();
        vm.warp(expiry - 30 days);

        vm.expectEmit(true, false, false, true, address(engine));
        emit CfdEngine.ProtocolTreasuryProposed(TREASURY_B, expiry, expiry + 60 days);
        engine.proposeProtocolTreasury(TREASURY_B, 60 days);

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(TREASURY_B, expiry, expiry + 60 days);
    }

    function test_TreasuryProposal_ReplacementDoesNotRestartCountdown() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 60 days);
        vm.warp(expiry - 1);

        vm.expectEmit(true, false, false, true, address(engine));
        emit CfdEngine.ProtocolTreasuryProposed(TREASURY_C, expiry, expiry + 30 days);
        engine.proposeProtocolTreasury(TREASURY_C, 30 days);

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(TREASURY_C, expiry, expiry + 30 days);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_CancellationPreservesCurrentTreasuryAndCountdown() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 60 days);
        vm.warp(expiry - 1);

        vm.expectEmit(false, false, false, true, address(engine));
        emit CfdEngine.ProtocolTreasuryProposalCancelled();
        engine.cancelProtocolTreasuryProposal();

        _assertPending(address(0), 0, 0);
        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        engine.setProtocolTreasury(TREASURY_C);
        assertEq(engine.protocolTreasury(), TREASURY_C);
    }

    function test_TreasuryProposal_CancelAndReproposeKeepsOriginalExpiry() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 60 days);
        vm.warp(expiry - 10 days);
        engine.cancelProtocolTreasuryProposal();
        vm.warp(expiry - 1);
        engine.proposeProtocolTreasury(TREASURY_C, 30 days);

        _assertPending(TREASURY_C, expiry, expiry + 30 days);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_C);
    }

    function test_TreasuryProposal_ActivatesAtExactExpiryWithoutTransaction() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);

        vm.warp(expiry - 1);
        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(TREASURY_B, expiry, expiry + 30 days);

        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);

        vm.warp(expiry + 1);
        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
    }

    function test_TreasuryProposal_CannotCancelActivatedTreasury() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector);
        engine.cancelProtocolTreasuryProposal();

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_ActivatedLockBlocksBothImmediateSetters() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry);

        bytes memory reason =
            abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry + 30 days);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(TREASURY_C);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(TREASURY_C, 1 days);

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        vm.warp(expiry + 30 days);
        engine.setProtocolTreasury(TREASURY_C, 1 days);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 31 days);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_CanQueueNextTransitionAfterAutomaticActivation() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry + 10 days);

        engine.proposeProtocolTreasury(TREASURY_C, 7 days);

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(TREASURY_C, expiry + 30 days, expiry + 37 days);
        vm.warp(expiry + 30 days);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 37 days);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_CancellingNextTransitionCannotRestorePreviousTreasury() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry);
        engine.proposeProtocolTreasury(TREASURY_C, 7 days);
        engine.cancelProtocolTreasuryProposal();

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
        vm.warp(expiry + 30 days);
        assertEq(engine.protocolTreasury(), TREASURY_B);
    }

    function test_TreasuryProposal_SkippingBothExpiriesDoesNotExtendLockOrRestoreOldTreasury() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry + 31 days);

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
        engine.setProtocolTreasury(TREASURY_C);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        vm.warp(expiry + 60 days);
        assertEq(engine.protocolTreasury(), TREASURY_C);
    }

    function test_TreasuryProposal_ZeroDurationActivatesWithoutAnotherLock() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 0);
        _assertPending(TREASURY_B, expiry, expiry);
        vm.warp(expiry);

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(address(0), 0, 0);
        engine.setProtocolTreasury(TREASURY_C);
        assertEq(engine.protocolTreasury(), TREASURY_C);
    }

    function test_TreasuryProposal_RequiresAnActiveLock() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__TreasuryNotLocked.selector);
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);

        uint256 expiry = _lockTreasury();
        vm.warp(expiry);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__TreasuryNotLocked.selector);
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_RejectsCancellationWithoutPendingProposal() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector);
        engine.cancelProtocolTreasuryProposal();
        _lockTreasury();
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector);
        engine.cancelProtocolTreasuryProposal();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        engine.cancelProtocolTreasuryProposal();
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector);
        engine.cancelProtocolTreasuryProposal();
    }

    function test_TreasuryProposal_InvalidReplacementLeavesExistingScheduleIntact() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAddress.selector);
        engine.proposeProtocolTreasury(address(0), 7 days);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        engine.proposeProtocolTreasury(TREASURY_C, type(uint256).max);

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(TREASURY_B, expiry, expiry + 30 days);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_B);
    }

    function test_TreasuryProposal_InvalidNextProposalCannotUndoAutomaticActivation() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        engine.proposeProtocolTreasury(TREASURY_C, type(uint256).max);

        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
    }

    function test_TreasuryProposal_OnlyOwnerMayProposeReplaceOrCancel() public {
        uint256 expiry = _lockTreasury();
        address stranger = address(0xBAD);
        bytes memory reason = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger);
        vm.prank(stranger);
        vm.expectRevert(reason);
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);

        vm.startPrank(stranger);
        vm.expectRevert(reason);
        engine.proposeProtocolTreasury(TREASURY_C, 7 days);
        vm.expectRevert(reason);
        engine.cancelProtocolTreasuryProposal();
        vm.stopPrank();

        _assertPending(TREASURY_B, expiry, expiry + 30 days);
        assertEq(engine.protocolTreasury(), TREASURY_A);
    }

    function test_TreasuryProposal_NewOwnerControlsPendingChangeWithoutBypassingLock() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        address nextOwner = address(0xA11CE);
        engine.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        engine.acceptOwnership();

        bytes memory reason = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this));
        vm.expectRevert(reason);
        engine.cancelProtocolTreasuryProposal();
        vm.expectRevert(reason);
        engine.proposeProtocolTreasury(TREASURY_C, 7 days);

        vm.startPrank(nextOwner);
        engine.cancelProtocolTreasuryProposal();
        engine.proposeProtocolTreasury(TREASURY_C, 7 days);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry));
        engine.setProtocolTreasury(nextOwner);
        vm.stopPrank();

        _assertPending(TREASURY_C, expiry, expiry + 7 days);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 7 days);
    }

    function test_TreasuryProposal_CurrentAddressMayBeScheduledWithAnotherLock() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_A, 30 days);
        _assertPending(TREASURY_A, expiry, expiry + 30 days);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry);

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry + 30 days));
        engine.setProtocolTreasury(TREASURY_B);
    }

    function test_TreasuryProposal_ActivationDoesNotRequireAnOwner() public {
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        engine.renounceOwnership();

        assertEq(engine.owner(), address(0));
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_B);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        _assertPending(address(0), 0, 0);
        vm.warp(expiry + 31 days);
        assertEq(engine.protocolTreasury(), TREASURY_B);
    }

    function test_TreasuryProposal_FutureExecutionFeesFollowActivationAndOldBalancesRemainWithdrawable() public {
        address firstTrader = address(0xA11CE);
        address secondTrader = address(0xB0B);
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry - 1);
        _fundTrader(firstTrader, 50_000e6);
        _fundTrader(secondTrader, 50_000e6);
        _open(firstTrader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        assertEq(clearinghouse.balanceAssets(TREASURY_A), 40e6);
        assertEq(clearinghouse.balanceAssets(TREASURY_B), 0);
        assertEq(engineProtocolLens.getProtocolAccountingSnapshot().protocolTreasuryBalanceAssets, 40e6);

        vm.warp(expiry);
        assertEq(engineProtocolLens.getProtocolAccountingSnapshot().protocolTreasuryBalanceAssets, 0);
        _open(secondTrader, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        assertEq(clearinghouse.balanceAssets(TREASURY_A), 40e6);
        assertEq(clearinghouse.balanceAssets(TREASURY_B), 40e6);
        assertEq(engineProtocolLens.getProtocolAccountingSnapshot().protocolTreasuryBalanceAssets, 40e6);
        vm.prank(TREASURY_A);
        clearinghouse.withdraw(TREASURY_A, 40e6);
        vm.prank(TREASURY_B);
        clearinghouse.withdraw(TREASURY_B, 40e6);
        assertEq(settlementToken.balanceOf(TREASURY_A), 40e6);
        assertEq(settlementToken.balanceOf(TREASURY_B), 40e6);
        assertEq(clearinghouse.balanceAssets(TREASURY_A), 0);
        assertEq(clearinghouse.balanceAssets(TREASURY_B), 0);
    }

    function test_TreasuryProposal_ForfeitedBountyUsesAutomaticallyActivatedTreasury() public {
        address trader = address(0xA202);
        address counterparty = address(0xA203);
        address keeper = address(0xA204);
        // A Tuesday noon start makes the 90-day expiry Monday noon, outside the close-only weekend.
        vm.warp(SETUP_TIMESTAMP + 1 days + 2 hours);
        uint256 expiry = _lockTreasury();
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(expiry - 1);
        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 100_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterparty, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        uint256 forfeitedBounty = _executionBountyReserve(1);
        assertGt(forfeitedBounty, 0);
        uint256 oldTreasuryBalance = clearinghouse.balanceAssets(TREASURY_A);
        assertEq(clearinghouse.balanceAssets(TREASURY_B), 0);

        vm.warp(expiry);
        vm.roll(block.number + 1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(196_000_000));
        vm.expectCall(
            address(engine), abi.encodeCall(CfdEngine.absorbReservedExecutionBounty, (trader, forfeitedBounty))
        );
        vm.prank(keeper);
        router.executeLiquidation(trader, priceData);

        assertEq(clearinghouse.balanceAssets(TREASURY_A), oldTreasuryBalance);
        assertEq(clearinghouse.balanceAssets(TREASURY_B), forfeitedBounty);
    }

    function testFuzz_TreasuryProposal_ReplacementAlwaysActivatesOnOriginalExpiry(
        uint64 start,
        uint32 durationSeed,
        uint256 replacementTimeSeed,
        uint32 nextDuration
    ) public {
        uint256 duration = bound(uint256(durationSeed), 1, 3650 days);
        vm.warp(uint256(start));
        engine.setProtocolTreasury(TREASURY_A, duration);
        uint256 expiry = uint256(start) + duration;
        engine.proposeProtocolTreasury(TREASURY_B, 1 days);
        vm.warp(uint256(start) + bound(replacementTimeSeed, 0, duration - 1));
        engine.proposeProtocolTreasury(TREASURY_C, uint256(nextDuration));

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(TREASURY_C, expiry, expiry + uint256(nextDuration));
        vm.warp(expiry - 1);
        assertEq(engine.protocolTreasury(), TREASURY_A);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + uint256(nextDuration));
        _assertPending(address(0), 0, 0);
        vm.warp(expiry + uint256(nextDuration) + 1);
        assertEq(engine.protocolTreasury(), TREASURY_C);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + uint256(nextDuration));
    }

    function testFuzz_TreasuryProposal_CancellationCannotChangeCurrentLock(
        uint32 durationSeed,
        uint256 cancellationTimeSeed
    ) public {
        uint256 duration = bound(uint256(durationSeed), 1, 3650 days);
        uint256 start = block.timestamp;
        engine.setProtocolTreasury(TREASURY_A, duration);
        uint256 expiry = start + duration;
        engine.proposeProtocolTreasury(TREASURY_B, 30 days);
        vm.warp(start + bound(cancellationTimeSeed, 0, duration - 1));
        engine.cancelProtocolTreasuryProposal();

        assertEq(engine.protocolTreasury(), TREASURY_A);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        _assertPending(address(0), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry));
        engine.setProtocolTreasury(TREASURY_C);
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), TREASURY_A);
        engine.setProtocolTreasury(TREASURY_C);
        assertEq(engine.protocolTreasury(), TREASURY_C);
    }

    function test_TreasuryProposal_MaturedSlotSupportsImmediateUpdateRelockAndNextSchedule() public {
        address original = address(0xFEE90);
        address firstSuccessor = address(0xFEE91);
        address immediateTreasury = address(0xFEE92);
        address secondSuccessor = address(0xFEE93);
        address replacement = address(0xFEE94);

        engine.setProtocolTreasury(original, 90 days);
        uint256 firstActivation = engine.protocolTreasuryLockedUntil();
        engine.proposeProtocolTreasury(firstSuccessor, 30 days);
        vm.warp(firstActivation + 30 days);
        assertEq(engine.protocolTreasury(), firstSuccessor);
        engine.setProtocolTreasury(immediateTreasury);
        engine.setProtocolTreasury(immediateTreasury, 7 days);
        uint256 nextActivation = vm.getBlockTimestamp() + 7 days;
        assertEq(engine.protocolTreasury(), immediateTreasury);
        assertEq(engine.protocolTreasuryLockedUntil(), nextActivation);
        (address pending,,) = engine.pendingProtocolTreasury();
        assertEq(pending, address(0), "Relocked effective treasury must not appear as a pending proposal");
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTreasuryProposal.selector);
        engine.cancelProtocolTreasuryProposal();

        engine.proposeProtocolTreasury(secondSuccessor, 2 days);
        engine.proposeProtocolTreasury(replacement, 3 days);
        engine.cancelProtocolTreasuryProposal();
        assertEq(engine.protocolTreasury(), immediateTreasury, "Cancellation cannot restore an earlier treasury");
        assertEq(engine.protocolTreasuryLockedUntil(), nextActivation);
        engine.proposeProtocolTreasury(secondSuccessor, 4 days);

        vm.warp(nextActivation - 1);
        assertEq(engine.protocolTreasury(), immediateTreasury);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, nextActivation));
        engine.setProtocolTreasury(replacement);
        vm.warp(nextActivation);
        assertEq(engine.protocolTreasury(), secondSuccessor);
        assertEq(engine.protocolTreasuryLockedUntil(), nextActivation + 4 days);
        vm.expectRevert(
            abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, nextActivation + 4 days)
        );
        engine.setProtocolTreasury(replacement);
    }

    function _lockTreasury() internal returns (uint256 expiry) {
        engine.setProtocolTreasury(TREASURY_A, 90 days);
        return block.timestamp + 90 days;
    }

    function _assertPending(
        address expectedTreasury,
        uint256 expectedActivationTime,
        uint256 expectedLockedUntil
    ) internal view {
        (address treasury, uint256 activationTime, uint256 lockedUntil) = engine.pendingProtocolTreasury();
        assertEq(treasury, expectedTreasury);
        assertEq(activationTime, expectedActivationTime);
        assertEq(lockedUntil, expectedLockedUntil);
    }

}
