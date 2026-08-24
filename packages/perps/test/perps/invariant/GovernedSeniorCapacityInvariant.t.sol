// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract GovernedSeniorCapacityHandler is Test {

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MIN_DEPOSIT_USDC = 1e6;
    uint256 internal constant MAX_ACTION_ASSETS_USDC = 25_000e6;
    uint256 internal constant MAX_TRACKED_EPOCHS = 8;

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    HousePool public immutable pool;
    OrderRouter public immutable router;
    TrancheVault public immutable seniorVault;
    TrancheVault public immutable juniorVault;

    address[4] internal actors;
    uint256[MAX_TRACKED_EPOCHS] internal trackedEpochIds;
    uint256 public trackedEpochCount;

    bool public seniorAdmissionViolation;
    bool public juniorWithdrawalViolation;
    uint256 public successfulSeniorAdmissions;
    uint256 public successfulJuniorWithdrawals;
    uint256 public successfulPreCutoffDepositRequests;
    uint256 public successfulCutoffWindowDepositRequests;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        OrderRouter _router,
        TrancheVault _seniorVault,
        TrancheVault _juniorVault
    ) {
        usdc = _usdc;
        engine = _engine;
        pool = _pool;
        router = _router;
        seniorVault = _seniorVault;
        juniorVault = _juniorVault;

        actors[0] = address(0xCA01);
        actors[1] = address(0xCA02);
        actors[2] = address(0xCA03);
        actors[3] = address(0xCA04);
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function trackedEpochIdAt(
        uint256 index
    ) external view returns (uint256) {
        return trackedEpochIds[index];
    }

    function requestSeniorDeposit(
        uint256 actorIndex,
        uint256 assetsFuzz,
        bool cutoffWindow
    ) external {
        _requestDeposit(seniorVault, actorIndex, assetsFuzz, true, cutoffWindow);
    }

    function requestJuniorDeposit(
        uint256 actorIndex,
        uint256 assetsFuzz,
        bool cutoffWindow
    ) external {
        _requestDeposit(juniorVault, actorIndex, assetsFuzz, false, cutoffWindow);
    }

    function cancelSeniorDeposit(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _cancelDeposit(seniorVault, epochIndex, actorIndex);
    }

    function cancelJuniorDeposit(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _cancelDeposit(juniorVault, epochIndex, actorIndex);
    }

    function settleLpEpoch() external {
        _refreshMark();
        if (!_hasSettleableMaturedWork()) {
            return;
        }
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);
        if (result.seniorDepositAssets != 0) {
            _recordSuccessfulSeniorAdmission();
        }
        if (result.juniorFundedAssets != 0) {
            successfulJuniorWithdrawals += 1;
            if (!_activeSeniorRatioWithinLimit()) {
                juniorWithdrawalViolation = true;
            }
        }
    }

    function claimSeniorDeposit(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimDeposit(seniorVault, epochIndex, actorIndex);
    }

    function claimJuniorDeposit(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimDeposit(juniorVault, epochIndex, actorIndex);
    }

    function requestSeniorRedeem(
        uint256 actorIndex,
        uint256 sharesFuzz,
        bool cutoffWindow
    ) external {
        _requestRedeem(seniorVault, actorIndex, sharesFuzz, cutoffWindow);
    }

    function requestJuniorRedeem(
        uint256 actorIndex,
        uint256 sharesFuzz,
        bool cutoffWindow
    ) external {
        _requestRedeem(juniorVault, actorIndex, sharesFuzz, cutoffWindow);
    }

    function cancelSeniorRedeem(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _cancelRedeem(seniorVault, epochIndex, actorIndex);
    }

    function cancelJuniorRedeem(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _cancelRedeem(juniorVault, epochIndex, actorIndex);
    }

    function claimSeniorRedeem(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimRedeem(seniorVault, epochIndex, actorIndex);
    }

    function claimJuniorRedeem(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimRedeem(juniorVault, epochIndex, actorIndex);
    }

    function claimSeniorRedeemRefund(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimRedeemRefund(seniorVault, epochIndex, actorIndex);
    }

    function claimJuniorRedeemRefund(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        _claimRedeemRefund(juniorVault, epochIndex, actorIndex);
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 90 minutes));
        _refreshMark();
    }

    function reservedSeniorEpochAssets() public view returns (uint256 assets) {
        for (uint256 i = 0; i < trackedEpochCount; ++i) {
            uint256 epochId = trackedEpochIds[i];
            (uint256 epochAssets,,,, bool finalized) = seniorVault.depositEpochs(epochId);
            (,,, bool rejected) = seniorVault.depositEpochQueueState(epochId);
            if (!finalized && !rejected) {
                assets += epochAssets;
            }
        }
    }

    function _requestDeposit(
        TrancheVault vault,
        uint256 actorIndex,
        uint256 assetsFuzz,
        bool isSenior,
        bool cutoffWindow
    ) internal {
        _warpToRequestWindowSide(vault, cutoffWindow);
        _refreshMark();
        uint256 expectedEpochId = _expectedRequestId(vault, cutoffWindow);
        if (!_canTrackEpoch(expectedEpochId)) {
            return;
        }

        address actor = actors[actorIndex % actors.length];
        uint256 maxAssets = vault.maxRequestDeposit(actor);
        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        if (upper < MIN_DEPOSIT_USDC) {
            return;
        }

        uint256 assets = bound(assetsFuzz, MIN_DEPOSIT_USDC, upper);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        uint256 requestId = vault.requestDeposit(assets, actor, actor);
        vm.stopPrank();

        assertEq(requestId, expectedEpochId, "deposit request must use the synchronized LP epoch");
        _trackEpoch(requestId);
        if (requestId == vault.currentLpEpoch() + 1) {
            successfulPreCutoffDepositRequests += 1;
        } else {
            successfulCutoffWindowDepositRequests += 1;
        }
        if (isSenior) {
            _recordSuccessfulSeniorAdmission();
        }
    }

    function _cancelDeposit(
        TrancheVault vault,
        uint256 epochIndex,
        uint256 actorIndex
    ) internal {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        address actor = actors[actorIndex % actors.length];
        uint256 refundable = vault.refundableDepositRequest(epochId, actor);
        uint256 pending = vault.pendingDepositRequest(epochId, actor);
        if (refundable == 0 && (pending == 0 || vault.currentLpEpoch() >= epochId)) {
            return;
        }

        vm.prank(actor);
        vault.cancelPendingDeposit(epochId, actor, actor);
    }

    function _claimDeposit(
        TrancheVault vault,
        uint256 epochIndex,
        uint256 actorIndex
    ) internal {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        address actor = actors[actorIndex % actors.length];
        uint256 assets = vault.claimableDepositRequest(epochId, actor);
        if (assets == 0) {
            return;
        }

        vm.prank(actor);
        vault.claimDeposit(epochId, assets, actor, actor);
    }

    function _requestRedeem(
        TrancheVault vault,
        uint256 actorIndex,
        uint256 sharesFuzz,
        bool cutoffWindow
    ) internal {
        _warpToRequestWindowSide(vault, cutoffWindow);
        _refreshMark();
        uint256 expectedEpochId = _expectedRequestId(vault, cutoffWindow);
        if (!_canTrackEpoch(expectedEpochId)) {
            return;
        }

        address actor = actors[actorIndex % actors.length];
        uint256 maxShares = vault.maxRequestRedeem(actor);
        if (maxShares == 0) {
            return;
        }
        uint256 shares = bound(sharesFuzz, 1, maxShares);
        if (vault.estimateRedeemAssets(shares) < MIN_DEPOSIT_USDC && shares < maxShares) {
            shares = maxShares;
        }

        vm.prank(actor);
        uint256 requestId = vault.requestRedeem(shares, actor, actor);
        assertEq(requestId, expectedEpochId, "redeem request must use the synchronized LP epoch");
        _trackEpoch(requestId);
    }

    function _warpToRequestWindowSide(
        TrancheVault vault,
        bool cutoffWindow
    ) internal {
        (, uint256 nextCutoffTime) = vault.getRequestEpochWindow();
        assertGt(nextCutoffTime, block.timestamp, "advertised request cutoff must be in the future");
        vm.warp(cutoffWindow ? nextCutoffTime : nextCutoffTime - 1);
    }

    function _expectedRequestId(
        TrancheVault vault,
        bool cutoffWindow
    ) internal view returns (uint256 expectedEpochId) {
        uint256 nextCutoffTime;
        (expectedEpochId, nextCutoffTime) = vault.getRequestEpochWindow();
        uint256 currentEpoch = vault.currentLpEpoch();
        assertEq(
            expectedEpochId,
            currentEpoch + (cutoffWindow ? 2 : 1),
            "request action must reach the selected side of the cutoff"
        );
        assertGt(nextCutoffTime, block.timestamp, "next advertised request cutoff must remain in the future");
    }

    function _cancelRedeem(
        TrancheVault vault,
        uint256 epochIndex,
        uint256 actorIndex
    ) internal {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        if (vault.currentLpEpoch() >= epochId) {
            return;
        }
        address actor = actors[actorIndex % actors.length];
        if (vault.pendingRedeemRequest(epochId, actor) == 0) {
            return;
        }

        vm.prank(actor);
        vault.cancelRedeemRequest(epochId, actor, actor);
    }

    function _claimRedeem(
        TrancheVault vault,
        uint256 epochIndex,
        uint256 actorIndex
    ) internal {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        address actor = actors[actorIndex % actors.length];
        uint256 shares = vault.claimableRedeemRequest(epochId, actor);
        if (shares == 0) {
            return;
        }

        vm.prank(actor);
        vault.claimRedeem(epochId, shares, actor, actor);
    }

    function _claimRedeemRefund(
        TrancheVault vault,
        uint256 epochIndex,
        uint256 actorIndex
    ) internal {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        address actor = actors[actorIndex % actors.length];
        if (!vault.redeemRefundPending(epochId, actor)) {
            return;
        }

        vm.prank(actor);
        vault.claimRedeemRefund(epochId, actor, actor);
    }

    function _refreshMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

    function _hasSettleableMaturedWork() internal view returns (bool) {
        uint256 cutoffEpoch = pool.currentLpEpoch();
        (, uint256 seniorRedeemShares) = seniorVault.getMaturedRedeemHead(cutoffEpoch);
        (, uint256 juniorRedeemShares) = juniorVault.getMaturedRedeemHead(cutoffEpoch);
        if ((seniorRedeemShares != 0 || juniorRedeemShares != 0) && pool.getFreeUSDC() != 0) {
            return true;
        }

        (, uint256 seniorDepositAssets) = seniorVault.getMaturedDepositHead(cutoffEpoch);
        (, uint256 juniorDepositAssets) = juniorVault.getMaturedDepositHead(cutoffEpoch);
        return (seniorDepositAssets != 0 || juniorDepositAssets != 0) && !pool.paused()
            && pool.canAcceptTrancheDeposits(false);
    }

    function _canTrackEpoch(
        uint256 epochId
    ) internal view returns (bool) {
        (bool tracked,) = _findTrackedEpoch(epochId);
        return tracked || trackedEpochCount < MAX_TRACKED_EPOCHS;
    }

    function _trackEpoch(
        uint256 epochId
    ) internal {
        (bool tracked,) = _findTrackedEpoch(epochId);
        if (!tracked) {
            trackedEpochIds[trackedEpochCount] = epochId;
            trackedEpochCount += 1;
        }
    }

    function _recordSuccessfulSeniorAdmission() internal {
        successfulSeniorAdmissions += 1;
        if (!_seniorCommitmentsWithinIndependentLimits()) {
            seniorAdmissionViolation = true;
        }
    }

    /// @dev Independent capacity oracle for the invariant. It deliberately does not call the pool's capacity
    ///      predicate, pending-state views, or capacity/accounting libraries. This handler cannot create positions,
    ///      claimant buckets, unassigned assets, or governance changes, so elapsed senior coupon is its only pending
    ///      reconcile transition.
    function _seniorCommitmentsWithinIndependentLimits() internal view returns (bool) {
        (uint256 projectedSenior, uint256 projectedJunior, uint256 projectedHighWaterMark) =
            _projectStoredWaterfallAfterCoupon();
        uint256 projectedExposure = projectedSenior > projectedHighWaterMark ? projectedSenior : projectedHighWaterMark;
        uint256 reservations = pool.reservedSeniorDepositAssetsUsdc();

        if (reservations > type(uint256).max - projectedExposure) {
            return false;
        }
        uint256 committedExposure = projectedExposure + reservations;
        if (committedExposure > pool.maxSeniorExposureUsdc()) {
            return false;
        }

        return _withinRatio(committedExposure, projectedJunior);
    }

    /// @dev Reproduces coupon transfer from raw stored state using quotient/remainder arithmetic rather than the
    ///      production waterfall implementation. Paid coupon restores an impaired senior claim first; any remainder
    ///      raises senior principal and its high-water mark in lockstep.
    function _projectStoredWaterfallAfterCoupon()
        internal
        view
        returns (uint256 seniorPrincipal, uint256 juniorPrincipal, uint256 seniorHighWaterMark)
    {
        seniorPrincipal = pool.seniorPrincipal();
        juniorPrincipal = pool.juniorPrincipal();
        seniorHighWaterMark = pool.seniorHighWaterMark();

        uint256 checkpoint = pool.lastSeniorCouponCheckpointTime();
        uint256 elapsed = block.timestamp > checkpoint ? block.timestamp - checkpoint : 0;
        if (elapsed == 0 || seniorPrincipal == 0 || juniorVault.totalSupply() == 0) {
            return (seniorPrincipal, juniorPrincipal, seniorHighWaterMark);
        }

        uint256 denominator = BPS * SECONDS_PER_YEAR;
        uint256 rateElapsed = pool.seniorRateBps() * elapsed;
        uint256 couponDue = (seniorPrincipal / denominator) * rateElapsed
            + ((seniorPrincipal % denominator) * rateElapsed) / denominator;
        uint256 couponPaid = couponDue < juniorPrincipal ? couponDue : juniorPrincipal;
        juniorPrincipal -= couponPaid;

        uint256 remaining = couponPaid;
        if (seniorPrincipal < seniorHighWaterMark) {
            uint256 impairment = seniorHighWaterMark - seniorPrincipal;
            uint256 restored = remaining < impairment ? remaining : impairment;
            seniorPrincipal += restored;
            remaining -= restored;
        }
        if (remaining > 0) {
            seniorPrincipal += remaining;
            seniorHighWaterMark += remaining;
        }
    }

    function _activeSeniorRatioWithinLimit() internal view returns (bool) {
        uint256 principal = pool.seniorPrincipal();
        uint256 highWaterMark = pool.seniorHighWaterMark();
        uint256 exposure = principal > highWaterMark ? principal : highWaterMark;
        return _withinRatio(exposure, pool.juniorPrincipal());
    }

    function _withinRatio(
        uint256 exposure,
        uint256 juniorPrincipal
    ) internal view returns (bool) {
        uint256 maxShareBps = pool.maxSeniorShareBps();
        if (maxShareBps >= BPS) {
            return true;
        }
        if (maxShareBps == 0) {
            return exposure == 0;
        }
        uint256 ratioLimit = _independentSaturatingMulDiv(juniorPrincipal, maxShareBps, BPS - maxShareBps);
        return exposure <= ratioLimit;
    }

    /// @dev Computes `floor(x * y / denominator)` by quotient/remainder decomposition and saturates at uint256 max.
    ///      This is intentionally structurally different from the production full-precision mulDiv implementation.
    ///      Here `y` and `denominator` are basis-point values, so the remainder product cannot overflow.
    function _independentSaturatingMulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256) {
        if (x == 0 || y == 0) {
            return 0;
        }

        uint256 wholeMultiplier = x / denominator;
        if (wholeMultiplier > type(uint256).max / y) {
            return type(uint256).max;
        }
        uint256 whole = wholeMultiplier * y;
        uint256 remainderTerm = ((x % denominator) * y) / denominator;
        if (remainderTerm > type(uint256).max - whole) {
            return type(uint256).max;
        }
        return whole + remainderTerm;
    }

    function _findTrackedEpoch(
        uint256 epochId
    ) internal view returns (bool tracked, uint256 index) {
        for (uint256 i = 0; i < trackedEpochCount; ++i) {
            if (trackedEpochIds[i] == epochId) {
                return (true, i);
            }
        }
    }

}

contract GovernedSeniorCapacityInvariantTest is BasePerpTest {

    GovernedSeniorCapacityHandler internal handler;

    uint256 internal constant SMOKE_SENIOR_DEPOSIT_USDC = 1e6;
    uint256 internal constant SMOKE_JUNIOR_DEPOSIT_USDC = 2e6;
    uint256 internal constant SMOKE_REDEEM_SHARES_FUZZ = 1e6;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        _setSeniorCapacity(100_000e6, 7500);

        handler = new GovernedSeniorCapacityHandler(usdc, engine, pool, router, seniorVault, juniorVault);

        // Make the postcondition counters non-vacuous in every invariant campaign. The fuzzer retains the full
        // selector set below and continues exploring additional transitions from this valid, exercised state.
        handler.requestSeniorDeposit(0, SMOKE_SENIOR_DEPOSIT_USDC, false);
        uint256 seniorDepositEpochIndex = handler.trackedEpochCount() - 1;
        uint256 seniorDepositEpochId = handler.trackedEpochIdAt(seniorDepositEpochIndex);

        handler.requestJuniorDeposit(0, SMOKE_JUNIOR_DEPOSIT_USDC, true);
        uint256 juniorDepositEpochIndex = handler.trackedEpochCount() - 1;
        uint256 juniorDepositEpochId = handler.trackedEpochIdAt(juniorDepositEpochIndex);

        vm.warp(pool.lpEpochStart(seniorDepositEpochId));
        handler.settleLpEpoch();
        handler.claimSeniorDeposit(seniorDepositEpochIndex, 0);

        vm.warp(pool.lpEpochStart(juniorDepositEpochId));
        handler.settleLpEpoch();
        handler.claimJuniorDeposit(juniorDepositEpochIndex, 0);

        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN());
        handler.requestJuniorRedeem(0, SMOKE_REDEEM_SHARES_FUZZ, false);
        uint256 redeemEpochIndex = handler.trackedEpochCount() - 1;
        uint256 redeemEpochId = handler.trackedEpochIdAt(redeemEpochIndex);
        vm.warp(pool.lpEpochStart(redeemEpochId));
        handler.settleLpEpoch();
        handler.claimJuniorRedeem(redeemEpochIndex, 0);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.requestSeniorDeposit.selector;
        selectors[1] = handler.requestJuniorDeposit.selector;
        selectors[2] = handler.cancelSeniorDeposit.selector;
        selectors[3] = handler.cancelJuniorDeposit.selector;
        selectors[4] = handler.settleLpEpoch.selector;
        selectors[5] = handler.claimSeniorDeposit.selector;
        selectors[6] = handler.claimJuniorDeposit.selector;
        selectors[7] = handler.requestSeniorRedeem.selector;
        selectors[8] = handler.requestJuniorRedeem.selector;
        selectors[9] = handler.cancelSeniorRedeem.selector;
        selectors[10] = handler.cancelJuniorRedeem.selector;
        selectors[11] = handler.claimSeniorRedeem.selector;
        selectors[12] = handler.claimJuniorRedeem.selector;
        selectors[13] = handler.claimSeniorRedeemRefund.selector;
        selectors[14] = handler.claimJuniorRedeemRefund.selector;
        selectors[15] = handler.warpForward.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SuccessfulSeniorAdmissionsPreserveCapacityLimits() public view {
        assertGt(handler.successfulSeniorAdmissions(), 0, "campaign must exercise a successful senior admission");
        assertFalse(
            handler.seniorAdmissionViolation(),
            "successful senior admission or finalization must leave active exposure plus reservations within limits"
        );
    }

    function invariant_SuccessfulJuniorWithdrawalsPreserveActiveSeniorRatio() public view {
        assertGt(handler.successfulJuniorWithdrawals(), 0, "campaign must exercise a successful junior withdrawal");
        assertFalse(
            handler.juniorWithdrawalViolation(),
            "successful junior withdrawal must leave active protected senior exposure within the share limit"
        );
    }

    function invariant_RequestGenerationExercisesBothCutoffSides() public view {
        assertGt(
            handler.successfulPreCutoffDepositRequests(),
            0,
            "campaign must exercise a successful pre-cutoff deposit request"
        );
        assertGt(
            handler.successfulCutoffWindowDepositRequests(),
            0,
            "campaign must exercise a successful cutoff-window deposit request"
        );
    }

    function invariant_ReservationCounterMatchesReservedSeniorEpochAssets() public view {
        assertEq(
            pool.reservedSeniorDepositAssetsUsdc(),
            handler.reservedSeniorEpochAssets(),
            "pool reservation counter must equal aggregate pending, non-rejected senior epoch assets"
        );
    }

    function invariant_VaultCustodyMatchesAsyncEscrowLedgers() public view {
        _assertVaultCustody(seniorVault);
        _assertVaultCustody(juniorVault);
    }

    function invariant_DepositEpochsMatchControllerAccounting() public view {
        _assertDepositEpochAccounting(seniorVault);
        _assertDepositEpochAccounting(juniorVault);
    }

    function _assertVaultCustody(
        TrancheVault vault
    ) internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.pendingDepositEscrowAssets() + vault.withdrawalEscrowAssets(),
            "vault USDC custody must equal pending deposit plus funded withdrawal escrow"
        );
        assertEq(
            vault.balanceOf(address(vault)),
            vault.pendingRedeemEscrowShares() + vault.depositClaimEscrowShares(),
            "vault share custody must equal pending redeem plus finalized deposit claim escrow"
        );
    }

    function _assertDepositEpochAccounting(
        TrancheVault vault
    ) internal view {
        for (uint256 i = 0; i < handler.trackedEpochCount(); ++i) {
            uint256 epochId = handler.trackedEpochIdAt(i);
            (uint256 epochAssets,, uint256 claimedAssets,, bool finalized) = vault.depositEpochs(epochId);
            (,,, bool rejected) = vault.depositEpochQueueState(epochId);

            uint256 controllerAssets;
            for (uint256 j = 0; j < handler.actorCount(); ++j) {
                address actor = handler.actorAt(j);
                if (finalized) {
                    controllerAssets += vault.claimableDepositRequest(epochId, actor);
                } else if (rejected) {
                    controllerAssets += vault.refundableDepositRequest(epochId, actor);
                } else {
                    controllerAssets += vault.pendingDepositRequest(epochId, actor);
                }
            }
            uint256 expectedAssets = finalized ? epochAssets - claimedAssets : epochAssets;
            assertEq(controllerAssets, expectedAssets, "epoch assets must equal tracked controller accounting");
        }
    }

}
