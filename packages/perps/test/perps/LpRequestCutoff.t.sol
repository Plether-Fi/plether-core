// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @notice Focused coverage for the shared five-minute LP request cutoff.
contract LpRequestCutoffTest is BasePerpTest {

    uint256 internal constant EPOCH_DURATION = 1 hours;
    uint256 internal constant REQUEST_CUTOFF = 5 minutes;
    uint256 internal constant REQUEST_ASSETS = 2e6;
    uint256 internal constant REQUEST_SHARES = 2e9;
    uint256 internal constant ACTOR_SHARE_ALLOCATION = 100e9;

    address internal constant DIRECT_CONTROLLER = address(0xD1EC7);
    address internal constant OPERATED_CONTROLLER = address(0x0A3A7ED);
    address internal constant OPERATOR = address(0x0F3A4702);

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 200_000e6;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 100_000e6;
    }

    function test_RequestBoundaryMatrix_AllTranchesDirectionsAndAuthorizations() public {
        uint256 boundary = _prepareActors();
        uint256[8] memory timestamps;
        timestamps[0] = boundary - REQUEST_CUTOFF - 1;
        timestamps[1] = boundary - REQUEST_CUTOFF;
        timestamps[2] = boundary - REQUEST_CUTOFF + 1;
        timestamps[3] = boundary - 1;
        timestamps[4] = boundary;
        timestamps[5] = boundary + 1;
        timestamps[6] = boundary + EPOCH_DURATION - REQUEST_CUTOFF - 1;
        timestamps[7] = boundary + EPOCH_DURATION - REQUEST_CUTOFF;

        uint256 previousRequestId;
        uint256 lockedEpoch;
        uint256 lockedSeniorDepositAssets;
        uint256 lockedJuniorDepositAssets;
        uint256 lockedSeniorRedeemShares;
        uint256 lockedJuniorRedeemShares;

        for (uint256 i; i < timestamps.length; ++i) {
            vm.warp(timestamps[i]);
            uint256 expectedRequestId = _assertCanonicalWindow(timestamps[i]);
            if (i != 0) {
                assertGe(expectedRequestId, previousRequestId, "request ids must be monotonic");
            }

            uint256 seniorDepositBefore = _depositEpochAssets(seniorVault, expectedRequestId);
            uint256 juniorDepositBefore = _depositEpochAssets(juniorVault, expectedRequestId);
            uint256 seniorRedeemBefore = _redeemEpochShares(seniorVault, expectedRequestId);
            uint256 juniorRedeemBefore = _redeemEpochShares(juniorVault, expectedRequestId);

            // Route bits are: 0 = Junior/Senior, 1 = deposit/redeem, 2 = controller/operator.
            for (uint256 route; route < 8; ++route) {
                assertEq(
                    _issueMatrixRequest(route),
                    expectedRequestId,
                    "every tranche, direction, and authorization route must use the canonical id"
                );
            }

            assertEq(
                _depositEpochAssets(seniorVault, expectedRequestId),
                seniorDepositBefore + 2 * REQUEST_ASSETS,
                "both Senior deposit authorization routes must batch"
            );
            assertEq(
                _depositEpochAssets(juniorVault, expectedRequestId),
                juniorDepositBefore + 2 * REQUEST_ASSETS,
                "both Junior deposit authorization routes must batch"
            );
            assertEq(
                _redeemEpochShares(seniorVault, expectedRequestId),
                seniorRedeemBefore + 2 * REQUEST_SHARES,
                "both Senior redeem authorization routes must batch"
            );
            assertEq(
                _redeemEpochShares(juniorVault, expectedRequestId),
                juniorRedeemBefore + 2 * REQUEST_SHARES,
                "both Junior redeem authorization routes must batch"
            );

            if (i == 0) {
                lockedEpoch = expectedRequestId;
                lockedSeniorDepositAssets = _depositEpochAssets(seniorVault, lockedEpoch);
                lockedJuniorDepositAssets = _depositEpochAssets(juniorVault, lockedEpoch);
                lockedSeniorRedeemShares = _redeemEpochShares(seniorVault, lockedEpoch);
                lockedJuniorRedeemShares = _redeemEpochShares(juniorVault, lockedEpoch);
            } else {
                assertEq(
                    _depositEpochAssets(seniorVault, lockedEpoch),
                    lockedSeniorDepositAssets,
                    "post-cutoff Senior deposits must not increase the locked epoch"
                );
                assertEq(
                    _depositEpochAssets(juniorVault, lockedEpoch),
                    lockedJuniorDepositAssets,
                    "post-cutoff Junior deposits must not increase the locked epoch"
                );
                assertEq(
                    _redeemEpochShares(seniorVault, lockedEpoch),
                    lockedSeniorRedeemShares,
                    "post-cutoff Senior redeems must not increase the locked epoch"
                );
                assertEq(
                    _redeemEpochShares(juniorVault, lockedEpoch),
                    lockedJuniorRedeemShares,
                    "post-cutoff Junior redeems must not increase the locked epoch"
                );
            }
            previousRequestId = expectedRequestId;
        }

        assertEq(previousRequestId, lockedEpoch + 2, "the exact next cutoff must advance to the third target epoch");
    }

    function testFuzz_RequestEpochWindowMatchesFormulaForEverySecondOffset(
        uint16 rawOffset
    ) public {
        uint256 offset = bound(uint256(rawOffset), 0, EPOCH_DURATION - 1);
        uint256 epoch = pool.currentLpEpoch() + 1;
        uint256 timestamp = pool.lpEpochStart(epoch) + offset;
        vm.warp(timestamp);

        uint256 expectedRequestId = epoch + (offset < EPOCH_DURATION - REQUEST_CUTOFF ? 1 : 2);
        uint256 expectedCutoffTime = pool.lpEpochStart(expectedRequestId) - REQUEST_CUTOFF;
        (uint256 seniorRequestId, uint256 seniorCutoffTime) =
            IAsyncTrancheVault(address(seniorVault)).getRequestEpochWindow();
        (uint256 juniorRequestId, uint256 juniorCutoffTime) =
            IAsyncTrancheVault(address(juniorVault)).getRequestEpochWindow();

        assertEq(seniorRequestId, expectedRequestId);
        assertEq(juniorRequestId, expectedRequestId);
        assertEq(seniorCutoffTime, expectedCutoffTime);
        assertEq(juniorCutoffTime, expectedCutoffTime);
        assertGt(expectedCutoffTime, timestamp, "the advertised cutoff must never be elapsed");
        assertGt(pool.lpEpochStart(expectedRequestId) - timestamp, REQUEST_CUTOFF);
        assertLe(pool.lpEpochStart(expectedRequestId) - timestamp, EPOCH_DURATION + REQUEST_CUTOFF);
    }

    function test_UpdatedCustomAndStandardInterfacesRemainAdvertised() public view {
        _assertInterfaces(seniorVault);
        _assertInterfaces(juniorVault);
    }

    function test_CancelControllersDuringQuietPeriod_PreservesThenClearsSingleEpochNodes() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF - 1);
        uint256 requestId = _expectedWindow(block.timestamp).requestId;

        _requestBothControllersAndDirections(seniorVault);
        _requestBothControllersAndDirections(juniorVault);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 2 * REQUEST_ASSETS);

        vm.warp(boundary - REQUEST_CUTOFF);
        _cancelControllerBothDirections(seniorVault, DIRECT_CONTROLLER, false);
        _cancelControllerBothDirections(juniorVault, DIRECT_CONTROLLER, false);

        _assertOnlyOperatedControllerRemains(seniorVault, requestId);
        _assertOnlyOperatedControllerRemains(juniorVault, requestId);
        assertEq(
            pool.reservedSeniorDepositAssetsUsdc(),
            REQUEST_ASSETS,
            "Senior cancellation must release exactly one controller reservation"
        );

        _cancelControllerBothDirections(seniorVault, OPERATED_CONTROLLER, true);
        _cancelControllerBothDirections(juniorVault, OPERATED_CONTROLLER, true);

        _assertRequestQueuesEmpty(seniorVault, requestId);
        _assertRequestQueuesEmpty(juniorVault, requestId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0, "final Senior cancellation must release all reservation");
        assertEq(seniorVault.lastDepositTime(OPERATED_CONTROLLER), block.timestamp);
        assertEq(juniorVault.lastDepositTime(OPERATED_CONTROLLER), block.timestamp);
    }

    function test_CancelOlderFinalController_RelinksEveryQueueToLaterEpoch() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF - 1);
        uint256 olderRequestId = _expectedWindow(block.timestamp).requestId;
        _requestOneControllerAndBothDirections(seniorVault, DIRECT_CONTROLLER, false);
        _requestOneControllerAndBothDirections(juniorVault, DIRECT_CONTROLLER, false);

        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 laterRequestId = _expectedWindow(block.timestamp).requestId;
        assertEq(laterRequestId, olderRequestId + 1, "exact cutoff must create the next FIFO node");
        _requestOneControllerAndBothDirections(seniorVault, OPERATED_CONTROLLER, true);
        _requestOneControllerAndBothDirections(juniorVault, OPERATED_CONTROLLER, true);

        _cancelControllerBothDirections(seniorVault, DIRECT_CONTROLLER, false);
        _cancelControllerBothDirections(juniorVault, DIRECT_CONTROLLER, false);

        _assertRelinkedToLaterEpoch(seniorVault, olderRequestId, laterRequestId);
        _assertRelinkedToLaterEpoch(juniorVault, olderRequestId, laterRequestId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), REQUEST_ASSETS);
    }

    function test_LateDepositCancellationAndReplacementUseCanonicalLaterEpoch() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 canonicalRequestId = _assertCanonicalWindow(block.timestamp);

        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            uint256 firstRequestId = _requestDeposit(vault, OPERATED_CONTROLLER, true);
            assertEq(firstRequestId, canonicalRequestId, "late request must succeed in the rolled epoch");
            _cancelDeposit(vault, OPERATED_CONTROLLER, firstRequestId, true);
            assertEq(
                _requestDeposit(vault, OPERATED_CONTROLLER, true),
                canonicalRequestId,
                "same-timestamp replacement must use the advertised rolled epoch"
            );
        }

        vm.warp(pool.lpEpochStart(canonicalRequestId) - 1);
        _cancelDeposit(seniorVault, OPERATED_CONTROLLER, canonicalRequestId, true);
        _cancelDeposit(juniorVault, OPERATED_CONTROLLER, canonicalRequestId, true);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
        assertEq(seniorVault.depositQueueHead(), 0);
        assertEq(juniorVault.depositQueueHead(), 0);
    }

    function test_LateRedeemCancellationRestartsCooldownAndLaterRequestMatchesWindow() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 initialRequestId = _assertCanonicalWindow(block.timestamp);

        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            assertEq(_requestRedeem(vault, OPERATED_CONTROLLER, true), initialRequestId);
            _cancelRedeem(vault, OPERATED_CONTROLLER, initialRequestId, true);

            vm.prank(OPERATOR);
            vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
            vault.requestRedeem(REQUEST_SHARES, OPERATED_CONTROLLER, OPERATED_CONTROLLER);
        }

        vm.warp(block.timestamp + EPOCH_DURATION);
        uint256 laterRequestId = _assertCanonicalWindow(block.timestamp);
        assertGt(laterRequestId, initialRequestId);
        assertEq(_requestRedeem(seniorVault, OPERATED_CONTROLLER, true), laterRequestId);
        assertEq(_requestRedeem(juniorVault, OPERATED_CONTROLLER, true), laterRequestId);

        vm.warp(pool.lpEpochStart(laterRequestId) - 1);
        _cancelRedeem(seniorVault, OPERATED_CONTROLLER, laterRequestId, true);
        _cancelRedeem(juniorVault, OPERATED_CONTROLLER, laterRequestId, true);
        assertEq(seniorVault.redeemQueueHead(), 0);
        assertEq(juniorVault.redeemQueueHead(), 0);
    }

    function test_LateRequestsBecomeNoncancellableAtTheirOwnMaturity() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 requestId = _assertCanonicalWindow(block.timestamp);
        _requestOneControllerAndBothDirections(seniorVault, OPERATED_CONTROLLER, true);
        _requestOneControllerAndBothDirections(juniorVault, OPERATED_CONTROLLER, true);

        vm.warp(pool.lpEpochStart(requestId));
        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            vm.prank(OPERATOR);
            vm.expectRevert(TrancheVault.TrancheVault__DepositEpochAlreadyActive.selector);
            vault.cancelPendingDeposit(requestId, OPERATED_CONTROLLER, OPERATED_CONTROLLER);

            vm.prank(OPERATOR);
            vm.expectRevert(TrancheVault.TrancheVault__RedeemCancellationUnavailable.selector);
            vault.cancelRedeemRequest(requestId, OPERATED_CONTROLLER, OPERATED_CONTROLLER);
        }
    }

    function test_RedeemCancellationRemainsUnavailableAfterAnyFunding() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 requestId = _assertCanonicalWindow(block.timestamp);
        uint256 maturity = pool.lpEpochStart(requestId);

        assertEq(_requestRedeem(seniorVault, OPERATED_CONTROLLER, true), requestId);
        assertEq(_requestRedeem(juniorVault, OPERATED_CONTROLLER, true), requestId);

        uint256 fundedShares = REQUEST_SHARES / 2;
        uint256 fundedAssets = REQUEST_ASSETS;
        vm.warp(maturity);
        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            usdc.mint(address(vault), fundedAssets);
            vm.prank(address(pool));
            vault.fundRedeemEpoch(requestId, fundedShares, fundedAssets);
            assertEq(vault.claimableRedeemRequest(requestId, OPERATED_CONTROLLER), fundedShares);
            assertEq(vault.claimableRedeemAssets(requestId, OPERATED_CONTROLLER), fundedAssets);
        }

        // Isolate the funding guard from the independent maturity guard.
        vm.warp(maturity - 1);
        assertLt(pool.currentLpEpoch(), requestId);
        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            vm.prank(OPERATOR);
            vm.expectRevert(TrancheVault.TrancheVault__RedeemCancellationUnavailable.selector);
            vault.cancelRedeemRequest(requestId, OPERATED_CONTROLLER, OPERATED_CONTROLLER);
            assertEq(vault.pendingRedeemRequest(requestId, OPERATED_CONTROLLER), REQUEST_SHARES - fundedShares);
        }
    }

    function test_RedeemCancellationRemainsUnavailableAfterRefundActivation() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 requestId = _assertCanonicalWindow(block.timestamp);
        uint256 maturity = pool.lpEpochStart(requestId);

        assertEq(_requestRedeem(seniorVault, OPERATED_CONTROLLER, true), requestId);
        assertEq(_requestRedeem(juniorVault, OPERATED_CONTROLLER, true), requestId);

        vm.warp(maturity);
        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            vm.prank(address(pool));
            assertEq(vault.refundRedeemEpochRemainder(requestId, REQUEST_SHARES), REQUEST_SHARES);
            assertTrue(vault.redeemRefundPending(requestId, OPERATED_CONTROLLER));
            assertEq(vault.refundableRedeemRequest(requestId, OPERATED_CONTROLLER), REQUEST_SHARES);
        }

        // Isolate the refund-state guard from the independent maturity guard.
        vm.warp(maturity - 1);
        assertLt(pool.currentLpEpoch(), requestId);
        for (uint256 i; i < 2; ++i) {
            TrancheVault vault = i == 0 ? seniorVault : juniorVault;
            vm.prank(OPERATOR);
            vm.expectRevert(TrancheVault.TrancheVault__RedeemCancellationUnavailable.selector);
            vault.cancelRedeemRequest(requestId, OPERATED_CONTROLLER, OPERATED_CONTROLLER);
            assertTrue(vault.redeemRefundPending(requestId, OPERATED_CONTROLLER));
            assertEq(vault.refundableRedeemRequest(requestId, OPERATED_CONTROLLER), REQUEST_SHARES);
        }
    }

    function test_RequestEventsCarryCanonicalRolledEpoch() public {
        uint256 boundary = _prepareActors();
        vm.warp(boundary - REQUEST_CUTOFF);
        uint256 requestId = _expectedWindow(block.timestamp).requestId;

        vm.expectEmit(true, true, true, true, address(juniorVault));
        emit DepositRequest(OPERATED_CONTROLLER, OPERATED_CONTROLLER, requestId, OPERATOR, REQUEST_ASSETS);
        assertEq(_requestDeposit(juniorVault, OPERATED_CONTROLLER, true), requestId);

        vm.expectEmit(true, true, true, true, address(seniorVault));
        emit RedeemRequest(OPERATED_CONTROLLER, OPERATED_CONTROLLER, requestId, OPERATOR, REQUEST_SHARES);
        assertEq(_requestRedeem(seniorVault, OPERATED_CONTROLLER, true), requestId);
    }

    struct ExpectedWindow {
        uint256 currentEpoch;
        uint256 requestId;
        uint256 cutoffTime;
        bool cutoffActive;
    }

    function _assertCanonicalWindow(
        uint256 timestamp
    ) internal view returns (uint256 requestId) {
        ExpectedWindow memory expected = _expectedWindow(timestamp);
        (uint256 seniorRequestId, uint256 seniorCutoffTime) =
            IAsyncTrancheVault(address(seniorVault)).getRequestEpochWindow();
        (uint256 juniorRequestId, uint256 juniorCutoffTime) =
            IAsyncTrancheVault(address(juniorVault)).getRequestEpochWindow();

        assertEq(seniorRequestId, expected.requestId, "Senior target must match the normative formula");
        assertEq(juniorRequestId, expected.requestId, "Junior target must match the normative formula");
        assertEq(seniorCutoffTime, expected.cutoffTime, "Senior cutoff must match the normative formula");
        assertEq(juniorCutoffTime, expected.cutoffTime, "Junior cutoff must match the normative formula");
        assertGt(expected.requestId, expected.currentEpoch, "target request epoch must be future");
        assertGt(expected.cutoffTime, timestamp, "next request cutoff must be future");

        uint256 targetDelay = pool.lpEpochStart(expected.requestId) - timestamp;
        assertGt(targetDelay, REQUEST_CUTOFF, "target start must be more than five minutes away");
        assertLe(targetDelay, EPOCH_DURATION + REQUEST_CUTOFF, "target start must be no more than 65 minutes away");
        assertEq(
            expected.requestId > expected.currentEpoch + 1,
            expected.cutoffActive,
            "derived cutoff state must match the within-epoch offset"
        );

        PerpsViewTypes.TrancheQueueView memory seniorView = publicLens.getTrancheQueues(true);
        PerpsViewTypes.TrancheQueueView memory juniorView = publicLens.getTrancheQueues(false);
        assertEq(seniorView.currentEpoch, expected.currentEpoch);
        assertEq(juniorView.currentEpoch, expected.currentEpoch);
        assertEq(seniorView.nextRequestEpoch, expected.requestId);
        assertEq(juniorView.nextRequestEpoch, expected.requestId);
        assertEq(seniorView.nextRequestCutoffTime, expected.cutoffTime);
        assertEq(juniorView.nextRequestCutoffTime, expected.cutoffTime);
        return expected.requestId;
    }

    function _expectedWindow(
        uint256 timestamp
    ) internal pure returns (ExpectedWindow memory expected) {
        expected.currentEpoch = timestamp / EPOCH_DURATION;
        uint256 withinEpoch = timestamp % EPOCH_DURATION;
        expected.cutoffActive = withinEpoch >= EPOCH_DURATION - REQUEST_CUTOFF;
        expected.requestId = expected.currentEpoch + (expected.cutoffActive ? 2 : 1);
        expected.cutoffTime = expected.requestId * EPOCH_DURATION - REQUEST_CUTOFF;
    }

    function _prepareActors() internal returns (uint256 boundary) {
        uint256 sourceCooldownEnd = seniorVault.lastDepositTime(address(this)) + seniorVault.DEPOSIT_COOLDOWN();
        uint256 juniorCooldownEnd = juniorVault.lastDepositTime(address(this)) + juniorVault.DEPOSIT_COOLDOWN();
        if (juniorCooldownEnd > sourceCooldownEnd) {
            sourceCooldownEnd = juniorCooldownEnd;
        }
        if (block.timestamp < sourceCooldownEnd) {
            vm.warp(sourceCooldownEnd);
        }

        vm.startPrank(address(this));
        seniorVault.transfer(DIRECT_CONTROLLER, ACTOR_SHARE_ALLOCATION);
        seniorVault.transfer(OPERATED_CONTROLLER, ACTOR_SHARE_ALLOCATION);
        juniorVault.transfer(DIRECT_CONTROLLER, ACTOR_SHARE_ALLOCATION);
        juniorVault.transfer(OPERATED_CONTROLLER, ACTOR_SHARE_ALLOCATION);
        vm.stopPrank();

        usdc.mint(DIRECT_CONTROLLER, 1000e6);
        usdc.mint(OPERATED_CONTROLLER, 1000e6);
        _approveActor(DIRECT_CONTROLLER, false);
        _approveActor(OPERATED_CONTROLLER, true);

        boundary = (block.timestamp / EPOCH_DURATION + 1) * EPOCH_DURATION;
        assertGt(boundary - REQUEST_CUTOFF - 1, block.timestamp, "fixture must approach a future cutoff");
    }

    function _approveActor(
        address actor,
        bool approveOperator
    ) internal {
        vm.startPrank(actor);
        usdc.approve(address(seniorVault), type(uint256).max);
        usdc.approve(address(juniorVault), type(uint256).max);
        if (approveOperator) {
            IAsyncTrancheVault(address(seniorVault)).setOperator(OPERATOR, true);
            IAsyncTrancheVault(address(juniorVault)).setOperator(OPERATOR, true);
        }
        vm.stopPrank();
    }

    function _issueMatrixRequest(
        uint256 route
    ) internal returns (uint256 requestId) {
        TrancheVault vault = route & 1 == 0 ? seniorVault : juniorVault;
        bool redeemRequest = route & 2 != 0;
        bool operated = route & 4 != 0;
        address controller = operated ? OPERATED_CONTROLLER : DIRECT_CONTROLLER;
        return
            redeemRequest ? _requestRedeem(vault, controller, operated) : _requestDeposit(vault, controller, operated);
    }

    function _requestDeposit(
        TrancheVault vault,
        address controller,
        bool operated
    ) internal returns (uint256 requestId) {
        vm.prank(operated ? OPERATOR : controller);
        requestId = vault.requestDeposit(REQUEST_ASSETS, controller, controller);
    }

    function _requestRedeem(
        TrancheVault vault,
        address controller,
        bool operated
    ) internal returns (uint256 requestId) {
        vm.prank(operated ? OPERATOR : controller);
        requestId = vault.requestRedeem(REQUEST_SHARES, controller, controller);
    }

    function _cancelDeposit(
        TrancheVault vault,
        address controller,
        uint256 requestId,
        bool operated
    ) internal {
        vm.prank(operated ? OPERATOR : controller);
        assertEq(vault.cancelPendingDeposit(requestId, controller, controller), REQUEST_ASSETS);
    }

    function _cancelRedeem(
        TrancheVault vault,
        address controller,
        uint256 requestId,
        bool operated
    ) internal {
        vm.prank(operated ? OPERATOR : controller);
        assertEq(vault.cancelRedeemRequest(requestId, controller, controller), REQUEST_SHARES);
    }

    function _requestBothControllersAndDirections(
        TrancheVault vault
    ) internal {
        _requestOneControllerAndBothDirections(vault, DIRECT_CONTROLLER, false);
        _requestOneControllerAndBothDirections(vault, OPERATED_CONTROLLER, true);
    }

    function _requestOneControllerAndBothDirections(
        TrancheVault vault,
        address controller,
        bool operated
    ) internal {
        uint256 depositRequestId = _requestDeposit(vault, controller, operated);
        assertEq(_requestRedeem(vault, controller, operated), depositRequestId, "deposit and redeem must batch");
    }

    function _cancelControllerBothDirections(
        TrancheVault vault,
        address controller,
        bool operated
    ) internal {
        uint256 depositRequestId = vault.controllerDepositHead(controller);
        uint256 redeemRequestId = vault.controllerRedeemHead(controller);
        assertEq(depositRequestId, redeemRequestId, "fixture directions must share an epoch");
        _cancelDeposit(vault, controller, depositRequestId, operated);
        _cancelRedeem(vault, controller, redeemRequestId, operated);
    }

    function _assertOnlyOperatedControllerRemains(
        TrancheVault vault,
        uint256 requestId
    ) internal view {
        assertEq(vault.depositQueueHead(), requestId);
        assertEq(vault.depositQueueTail(), requestId);
        assertEq(vault.redeemQueueHead(), requestId);
        assertEq(vault.redeemQueueTail(), requestId);
        assertEq(vault.pendingDepositEscrowAssets(), REQUEST_ASSETS);
        assertEq(vault.pendingRedeemEscrowShares(), REQUEST_SHARES);
        assertEq(vault.pendingDepositRequest(requestId, DIRECT_CONTROLLER), 0);
        assertEq(vault.pendingRedeemRequest(requestId, DIRECT_CONTROLLER), 0);
        assertEq(vault.pendingDepositRequest(requestId, OPERATED_CONTROLLER), REQUEST_ASSETS);
        assertEq(vault.pendingRedeemRequest(requestId, OPERATED_CONTROLLER), REQUEST_SHARES);
        assertEq(vault.controllerDepositHead(DIRECT_CONTROLLER), 0);
        assertEq(vault.controllerRedeemHead(DIRECT_CONTROLLER), 0);
        assertEq(vault.controllerDepositHead(OPERATED_CONTROLLER), requestId);
        assertEq(vault.controllerRedeemHead(OPERATED_CONTROLLER), requestId);
        assertEq(_depositEpochAssets(vault, requestId), REQUEST_ASSETS);
        assertEq(_redeemEpochShares(vault, requestId), REQUEST_SHARES);
    }

    function _assertRequestQueuesEmpty(
        TrancheVault vault,
        uint256 requestId
    ) internal view {
        assertEq(vault.depositQueueHead(), 0);
        assertEq(vault.depositQueueTail(), 0);
        assertEq(vault.redeemQueueHead(), 0);
        assertEq(vault.redeemQueueTail(), 0);
        assertEq(vault.pendingDepositEscrowAssets(), 0);
        assertEq(vault.pendingRedeemEscrowShares(), 0);
        assertEq(vault.controllerDepositHead(OPERATED_CONTROLLER), 0);
        assertEq(vault.controllerDepositTail(OPERATED_CONTROLLER), 0);
        assertEq(vault.controllerRedeemHead(OPERATED_CONTROLLER), 0);
        assertEq(vault.controllerRedeemTail(OPERATED_CONTROLLER), 0);
        assertEq(_depositEpochAssets(vault, requestId), 0);
        assertEq(_redeemEpochShares(vault, requestId), 0);
        (,, bool depositQueued,) = vault.depositEpochQueueState(requestId);
        (,, bool redeemQueued,) = vault.redeemEpochQueueState(requestId);
        assertFalse(depositQueued);
        assertFalse(redeemQueued);
    }

    function _assertRelinkedToLaterEpoch(
        TrancheVault vault,
        uint256 olderRequestId,
        uint256 laterRequestId
    ) internal view {
        assertEq(vault.depositQueueHead(), laterRequestId);
        assertEq(vault.depositQueueTail(), laterRequestId);
        assertEq(vault.redeemQueueHead(), laterRequestId);
        assertEq(vault.redeemQueueTail(), laterRequestId);
        (,, bool oldDepositQueued,) = vault.depositEpochQueueState(olderRequestId);
        (uint256 depositPrevious, uint256 depositNext, bool laterDepositQueued,) =
            vault.depositEpochQueueState(laterRequestId);
        (,, bool oldRedeemQueued,) = vault.redeemEpochQueueState(olderRequestId);
        (uint256 redeemPrevious, uint256 redeemNext, bool laterRedeemQueued,) =
            vault.redeemEpochQueueState(laterRequestId);
        assertFalse(oldDepositQueued);
        assertFalse(oldRedeemQueued);
        assertTrue(laterDepositQueued);
        assertTrue(laterRedeemQueued);
        assertEq(depositPrevious, 0);
        assertEq(depositNext, 0);
        assertEq(redeemPrevious, 0);
        assertEq(redeemNext, 0);
        assertEq(vault.pendingDepositEscrowAssets(), REQUEST_ASSETS);
        assertEq(vault.pendingRedeemEscrowShares(), REQUEST_SHARES);
        assertEq(vault.pendingDepositRequest(olderRequestId, DIRECT_CONTROLLER), 0);
        assertEq(vault.pendingRedeemRequest(olderRequestId, DIRECT_CONTROLLER), 0);
        assertEq(vault.pendingDepositRequest(laterRequestId, OPERATED_CONTROLLER), REQUEST_ASSETS);
        assertEq(vault.pendingRedeemRequest(laterRequestId, OPERATED_CONTROLLER), REQUEST_SHARES);
        assertEq(vault.controllerDepositHead(DIRECT_CONTROLLER), 0);
        assertEq(vault.controllerRedeemHead(DIRECT_CONTROLLER), 0);
        assertEq(vault.controllerDepositHead(OPERATED_CONTROLLER), laterRequestId);
        assertEq(vault.controllerRedeemHead(OPERATED_CONTROLLER), laterRequestId);
    }

    function _assertInterfaces(
        TrancheVault vault
    ) internal view {
        IAsyncTrancheVault asyncVault = IAsyncTrancheVault(address(vault));
        (uint256 requestId, uint256 cutoffTime) = asyncVault.getRequestEpochWindow();
        assertGt(requestId, vault.currentLpEpoch());
        assertGt(cutoffTime, block.timestamp);
        assertTrue(asyncVault.supportsInterface(type(IAsyncTrancheVault).interfaceId));
        assertTrue(asyncVault.supportsInterface(0x01ffc9a7), "ERC-165 must remain advertised");
        assertTrue(asyncVault.supportsInterface(0xe3bc4e65), "ERC-7540 operator must remain advertised");
        assertTrue(asyncVault.supportsInterface(0xce3bbe50), "ERC-7540 deposit must remain advertised");
        assertTrue(asyncVault.supportsInterface(0x620ee8e4), "ERC-7540 redeem must remain advertised");
        assertTrue(asyncVault.supportsInterface(0x2f0a18c5), "ERC-7575 must remain advertised");
        assertTrue(asyncVault.supportsInterface(0xf815c03d), "ERC-7575 share must remain advertised");
        assertFalse(asyncVault.supportsInterface(0xffffffff));
    }

    function _depositEpochAssets(
        TrancheVault vault,
        uint256 requestId
    ) internal view returns (uint256 assets) {
        (assets,,,,) = vault.depositEpochs(requestId);
    }

    function _redeemEpochShares(
        TrancheVault vault,
        uint256 requestId
    ) internal view returns (uint256 shares) {
        (shares,,,,,,,,,) = vault.redeemEpochs(requestId);
    }

}
