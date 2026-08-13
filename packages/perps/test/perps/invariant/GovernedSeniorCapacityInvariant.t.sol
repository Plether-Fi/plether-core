// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract GovernedSeniorCapacityHandler is Test {

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MIN_DEPOSIT_USDC = 1e6;
    uint256 internal constant MAX_ACTION_ASSETS_USDC = 25_000e6;
    uint256 internal constant MAX_TRACKED_EPOCHS = 8;

    MockUSDC public immutable usdc;
    HousePool public immutable pool;
    TrancheVault public immutable seniorVault;
    TrancheVault public immutable juniorVault;

    address[4] internal actors;
    uint256[MAX_TRACKED_EPOCHS] internal trackedEpochIds;
    uint256 public trackedEpochCount;

    bool public seniorAdmissionViolation;
    bool public juniorWithdrawalViolation;
    uint256 public successfulSeniorAdmissions;
    uint256 public successfulJuniorWithdrawals;

    constructor(
        MockUSDC _usdc,
        HousePool _pool,
        TrancheVault _seniorVault,
        TrancheVault _juniorVault
    ) {
        usdc = _usdc;
        pool = _pool;
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

    function depositSenior(
        uint256 actorIndex,
        uint256 assetsFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        uint256 maxAssets = seniorVault.maxDeposit(actor);
        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        if (upper < MIN_DEPOSIT_USDC) {
            return;
        }

        uint256 assets = bound(assetsFuzz, MIN_DEPOSIT_USDC, upper);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(seniorVault), assets);
        seniorVault.deposit(assets, actor);
        vm.stopPrank();

        _recordSuccessfulSeniorAdmission();
    }

    function depositJunior(
        uint256 actorIndex,
        uint256 assetsFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        uint256 maxAssets = juniorVault.maxDeposit(actor);
        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        if (upper < MIN_DEPOSIT_USDC) {
            return;
        }

        uint256 assets = bound(assetsFuzz, MIN_DEPOSIT_USDC, upper);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(juniorVault), assets);
        juniorVault.deposit(assets, actor);
        vm.stopPrank();
    }

    function requestSeniorDeposit(
        uint256 actorIndex,
        uint256 assetsFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        uint256 epochId = seniorVault.currentDepositEpoch() + seniorVault.DEPOSIT_ACTIVATION_EPOCH_DELAY();
        (bool tracked,) = _findTrackedEpoch(epochId);
        if (!tracked && trackedEpochCount == MAX_TRACKED_EPOCHS) {
            return;
        }

        uint256 maxAssets = seniorVault.maxRequestDeposit(actor);
        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        if (upper < MIN_DEPOSIT_USDC) {
            return;
        }

        uint256 assets = bound(assetsFuzz, MIN_DEPOSIT_USDC, upper);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(seniorVault), assets);
        uint256 requestedEpochId = seniorVault.requestDeposit(assets, actor);
        vm.stopPrank();

        if (!tracked) {
            trackedEpochIds[trackedEpochCount] = requestedEpochId;
            trackedEpochCount += 1;
        }
        _recordSuccessfulSeniorAdmission();
    }

    function cancelSeniorBeforeActivation(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        if (block.timestamp >= seniorVault.depositEpochStart(epochId)) {
            return;
        }

        address actor = actors[actorIndex % actors.length];
        if (seniorVault.pendingDepositAssets(actor, epochId) == 0) {
            return;
        }

        vm.prank(actor);
        seniorVault.cancelPendingDeposit(epochId);
    }

    function finalizeSeniorEpoch(
        uint256 epochIndex
    ) external {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        if (block.timestamp < seniorVault.depositEpochStart(epochId)) {
            return;
        }

        (uint256 assets,,,, bool finalized) = seniorVault.depositEpochs(epochId);
        if (assets == 0 || finalized) {
            return;
        }

        try seniorVault.finalizeDepositEpoch(epochId) returns (uint256) {
            _recordSuccessfulSeniorAdmission();
        } catch {}
    }

    function claimSeniorDeposit(
        uint256 epochIndex,
        uint256 actorIndex
    ) external {
        if (trackedEpochCount == 0) {
            return;
        }
        uint256 epochId = trackedEpochIds[epochIndex % trackedEpochCount];
        (,,,, bool finalized) = seniorVault.depositEpochs(epochId);
        if (!finalized) {
            return;
        }

        address actor = actors[actorIndex % actors.length];
        if (seniorVault.pendingDepositAssets(actor, epochId) == 0) {
            return;
        }

        vm.prank(actor);
        try seniorVault.claimDepositShares(epochId) returns (uint256) {} catch {}
    }

    function withdrawSenior(
        uint256 actorIndex,
        uint256 assetsFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        uint256 maxAssets = seniorVault.maxWithdraw(actor);
        if (maxAssets == 0) {
            return;
        }

        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        uint256 lower = upper >= MIN_DEPOSIT_USDC ? MIN_DEPOSIT_USDC : upper;
        uint256 assets = bound(assetsFuzz, lower, upper);
        vm.prank(actor);
        try seniorVault.withdraw(assets, actor, actor) returns (uint256) {} catch {}
    }

    function withdrawJunior(
        uint256 actorIndex,
        uint256 assetsFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        uint256 maxAssets = juniorVault.maxWithdraw(actor);
        if (maxAssets == 0) {
            return;
        }

        uint256 upper = maxAssets < MAX_ACTION_ASSETS_USDC ? maxAssets : MAX_ACTION_ASSETS_USDC;
        uint256 lower = upper >= MIN_DEPOSIT_USDC ? MIN_DEPOSIT_USDC : upper;
        uint256 assets = bound(assetsFuzz, lower, upper);
        vm.prank(actor);
        try juniorVault.withdraw(assets, actor, actor) returns (uint256) {
            successfulJuniorWithdrawals += 1;
            if (!_activeSeniorRatioWithinLimit()) {
                juniorWithdrawalViolation = true;
            }
        } catch {}
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 90 minutes));
    }

    function unfinalizedEpochAssets() public view returns (uint256 assets) {
        for (uint256 i = 0; i < trackedEpochCount; ++i) {
            (uint256 epochAssets,,,, bool finalized) = seniorVault.depositEpochs(trackedEpochIds[i]);
            if (!finalized) {
                assets += epochAssets;
            }
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
    uint256 internal constant SMOKE_JUNIOR_WITHDRAW_USDC = 1e6;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        _setSeniorCapacity(100_000e6, 7500);

        handler = new GovernedSeniorCapacityHandler(usdc, pool, seniorVault, juniorVault);

        // Make the postcondition counters non-vacuous in every invariant campaign. The fuzzer retains the full
        // selector set below and continues exploring additional transitions from this valid, exercised state.
        handler.depositSenior(0, SMOKE_SENIOR_DEPOSIT_USDC);
        handler.depositJunior(0, SMOKE_JUNIOR_DEPOSIT_USDC);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN());
        handler.withdrawJunior(0, SMOKE_JUNIOR_WITHDRAW_USDC);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.depositSenior.selector;
        selectors[1] = handler.depositJunior.selector;
        selectors[2] = handler.requestSeniorDeposit.selector;
        selectors[3] = handler.cancelSeniorBeforeActivation.selector;
        selectors[4] = handler.finalizeSeniorEpoch.selector;
        selectors[5] = handler.claimSeniorDeposit.selector;
        selectors[6] = handler.withdrawSenior.selector;
        selectors[7] = handler.withdrawJunior.selector;
        selectors[8] = handler.warpForward.selector;

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

    function invariant_ReservationCounterMatchesUnfinalizedSeniorEpochAssets() public view {
        assertEq(
            pool.reservedSeniorDepositAssetsUsdc(),
            handler.unfinalizedEpochAssets(),
            "pool reservation counter must equal aggregate unfinalized senior epoch assets"
        );
    }

    function invariant_SeniorEscrowMatchesUnfinalizedEpochAccounting() public view {
        uint256 expectedEscrowAssets = handler.unfinalizedEpochAssets();
        assertEq(
            usdc.balanceOf(address(seniorVault)),
            expectedEscrowAssets,
            "senior vault USDC escrow must equal aggregate unfinalized epoch assets"
        );

        for (uint256 i = 0; i < handler.trackedEpochCount(); ++i) {
            uint256 epochId = handler.trackedEpochIdAt(i);
            (uint256 epochAssets,,,, bool finalized) = seniorVault.depositEpochs(epochId);
            if (finalized) {
                continue;
            }

            uint256 pendingAssets;
            for (uint256 j = 0; j < handler.actorCount(); ++j) {
                pendingAssets += seniorVault.pendingDepositAssets(handler.actorAt(j), epochId);
            }
            assertEq(pendingAssets, epochAssets, "unfinalized epoch assets must equal tracked depositor balances");
        }
    }

}
