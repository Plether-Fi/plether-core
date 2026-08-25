// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpHousePoolLifecycleHandler is Test {

    struct LastTransfer {
        bool active;
        bool isSenior;
        address from;
        address to;
        uint256 senderTimestamp;
        uint256 receiverTimestampBefore;
    }

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    HousePool public immutable pool;
    TrancheVault public immutable seniorVault;
    TrancheVault public immutable juniorVault;
    address public immutable owner;

    address[4] internal actors;
    LastTransfer internal lastTransfer;

    uint256 public ghostHeldSettlementAttempts;
    uint256 public ghostHeldSettlementUnexpectedSuccesses;
    uint256 public ghostHeldSettlementWrongReverts;
    uint256 public ghostHeldSettlementAccountingMutations;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        TrancheVault _seniorVault,
        TrancheVault _juniorVault,
        address _owner
    ) {
        usdc = _usdc;
        engine = _engine;
        pool = _pool;
        seniorVault = _seniorVault;
        juniorVault = _juniorVault;
        owner = _owner;

        actors[0] = address(0x9101);
        actors[1] = address(0x9102);
        actors[2] = address(0x9103);
        actors[3] = address(0x9104);
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function seedReceiver() external view returns (address) {
        return actors[0];
    }

    function initializeSeed(
        bool toSenior,
        uint256 amountFuzz
    ) external {
        if (toSenior ? pool.seniorSeedInitialized() : pool.juniorSeedInitialized()) {
            return;
        }

        uint256 amount = bound(amountFuzz, 1000e6, 100_000e6);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(pool), amount);
        pool.initializeSeedPosition(toSenior, amount, actors[0]);
        vm.stopPrank();
    }

    function activateTrading() external {
        if (pool.isTradingActive() || !pool.isSeedLifecycleComplete()) {
            return;
        }

        vm.prank(owner);
        pool.activateTrading();
    }

    function pausePool() external {
        if (pool.paused()) {
            return;
        }

        vm.prank(owner);
        pool.pause();
    }

    function unpausePool() external {
        if (!pool.paused()) {
            return;
        }

        vm.prank(owner);
        pool.unpause();
    }

    function setLpEpochSettlementHold(
        bool held
    ) external {
        if (pool.lpEpochSettlementPaused() == held) {
            return;
        }

        vm.prank(owner);
        if (held) {
            pool.pauseLpEpochSettlement();
        } else {
            pool.unpauseLpEpochSettlement();
        }
    }

    function requestDeposit(
        bool isSenior,
        uint256 actorIndex,
        uint256 amountFuzz,
        bool cutoffWindow
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address actor = actors[actorIndex % actors.length];
        _warpToRequestWindowSide(vault, cutoffWindow);
        _refreshMark();
        uint256 expectedRequestId = _expectedRequestId(vault, cutoffWindow);
        uint256 maxRequest_ = vault.maxRequestDeposit(actor);
        uint256 minimum = pool.minTrancheDepositUsdc();
        if (maxRequest_ < minimum) {
            return;
        }

        uint256 upper = maxRequest_ < 250_000e6 ? maxRequest_ : 250_000e6;
        uint256 amount = bound(amountFuzz, minimum, upper);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        uint256 requestId = vault.requestDeposit(amount, actor, actor);
        vm.stopPrank();
        assertEq(requestId, expectedRequestId, "deposit request must use the advertised LP epoch");
    }

    function requestRedeem(
        bool isSenior,
        uint256 actorIndex,
        uint256 sharesFuzz,
        bool cutoffWindow
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address actor = actors[actorIndex % actors.length];
        _warpToRequestWindowSide(vault, cutoffWindow);
        uint256 expectedRequestId = _expectedRequestId(vault, cutoffWindow);
        uint256 maxRequest_ = vault.maxRequestRedeem(actor);
        if (maxRequest_ == 0) {
            return;
        }

        uint256 minimumShares = vault.estimateWithdrawShares(pool.minTrancheDepositUsdc());
        uint256 lower = minimumShares != 0 && minimumShares <= maxRequest_ ? minimumShares : maxRequest_;
        uint256 shares = bound(sharesFuzz, lower, maxRequest_);
        vm.prank(actor);
        uint256 requestId = vault.requestRedeem(shares, actor, actor);
        assertEq(requestId, expectedRequestId, "redeem request must use the advertised LP epoch");
    }

    function settleLpEpoch() external {
        if (pool.lpEpochSettlementPaused()) {
            return;
        }

        uint256 cutoffEpoch = pool.currentLpEpoch();
        (, uint256 seniorRedeemShares) = seniorVault.getMaturedRedeemHead(cutoffEpoch);
        (, uint256 juniorRedeemShares) = juniorVault.getMaturedRedeemHead(cutoffEpoch);
        (, uint256 seniorDepositAssets) = seniorVault.getMaturedDepositHead(cutoffEpoch);
        (, uint256 juniorDepositAssets) = juniorVault.getMaturedDepositHead(cutoffEpoch);
        bool hasMaturedRedeem = seniorRedeemShares != 0 || juniorRedeemShares != 0;
        bool hasMaturedDeposit = seniorDepositAssets != 0 || juniorDepositAssets != 0;
        if (!hasMaturedRedeem && (!hasMaturedDeposit || pool.paused())) {
            return;
        }

        _refreshMark();
        pool.settleLpEpoch(0, 0);
    }

    function attemptLpEpochSettlementWhileHeld() external {
        if (!pool.lpEpochSettlementPaused()) {
            return;
        }

        bytes32 accountingBefore = _epochAccountingDigest();
        (bool success, bytes memory revertData) = address(pool).call(abi.encodeCall(IHousePool.settleLpEpoch, (0, 0)));

        ghostHeldSettlementAttempts++;
        if (success) {
            ghostHeldSettlementUnexpectedSuccesses++;
        } else if (_revertSelector(revertData) != IHousePool.HousePool__LpEpochSettlementPaused.selector) {
            ghostHeldSettlementWrongReverts++;
        }
        if (_epochAccountingDigest() != accountingBefore) {
            ghostHeldSettlementAccountingMutations++;
        }
    }

    function claimDeposit(
        bool isSenior,
        uint256 actorIndex
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address actor = actors[actorIndex % actors.length];
        uint256 requestId = vault.controllerDepositHead(actor);
        if (requestId == 0) {
            return;
        }

        uint256 refundableAssets = vault.refundableDepositRequest(requestId, actor);
        if (refundableAssets != 0) {
            vm.prank(actor);
            vault.cancelPendingDeposit(requestId, actor, actor);
            return;
        }

        uint256 claimableAssets = vault.claimableDepositRequest(requestId, actor);
        if (claimableAssets == 0) {
            return;
        }

        vm.prank(actor);
        vault.claimDeposit(requestId, claimableAssets, actor, actor);
    }

    function claimRedeem(
        bool isSenior,
        uint256 actorIndex
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address actor = actors[actorIndex % actors.length];
        uint256 requestId = vault.controllerRedeemHead(actor);
        if (requestId == 0) {
            return;
        }

        uint256 claimableShares = vault.claimableRedeemRequest(requestId, actor);
        if (claimableShares != 0) {
            vm.prank(actor);
            vault.claimRedeem(requestId, claimableShares, actor, actor);
        }
        if (vault.redeemRefundPending(requestId, actor)) {
            vm.prank(actor);
            vault.claimRedeemRefund(requestId, actor, actor);
        }
    }

    function transferShares(
        bool isSenior,
        uint256 fromIndex,
        uint256 toIndex,
        uint256 sharesFuzz
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address from = actors[fromIndex % actors.length];
        address to = actors[toIndex % actors.length];
        if (from == to) {
            return;
        }

        if (block.timestamp < vault.lastDepositTime(from) + vault.DEPOSIT_COOLDOWN()) {
            return;
        }

        uint256 transferable = vault.balanceOf(from);
        if (from == vault.seedReceiver() && from != address(0)) {
            uint256 floor = vault.seedShareFloor();
            transferable = transferable > floor ? transferable - floor : 0;
        }
        if (transferable == 0) {
            return;
        }

        uint256 shares = bound(sharesFuzz, 1, transferable);
        uint256 senderTimestamp = vault.lastDepositTime(from);
        uint256 receiverTimestampBefore = vault.lastDepositTime(to);

        vm.prank(from);
        vault.transfer(to, shares);

        lastTransfer = LastTransfer({
            active: true,
            isSenior: isSenior,
            from: from,
            to: to,
            senderTimestamp: senderTimestamp,
            receiverTimestampBefore: receiverTimestampBefore
        });
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 3 days));
    }

    function mintExcess(
        uint256 amountFuzz
    ) external {
        uint256 amount = bound(amountFuzz, 1e6, 100_000e6);
        usdc.mint(address(pool), amount);
    }

    function accountExcess() external {
        if (pool.excessAssets() == 0) {
            return;
        }

        vm.prank(owner);
        pool.accountExcess();
    }

    function sweepExcess(
        uint256 amountFuzz
    ) external {
        uint256 excess = pool.excessAssets();
        if (excess == 0) {
            return;
        }

        uint256 amount = bound(amountFuzz, 1, excess);
        vm.prank(owner);
        pool.sweepExcess(owner, amount);
    }

    function lastTransferSnapshot() external view returns (LastTransfer memory) {
        return lastTransfer;
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
    ) internal view returns (uint256 expectedRequestId) {
        uint256 nextCutoffTime;
        (expectedRequestId, nextCutoffTime) = vault.getRequestEpochWindow();
        assertEq(
            expectedRequestId,
            vault.currentLpEpoch() + (cutoffWindow ? 2 : 1),
            "request action must reach the selected side of the cutoff"
        );
        assertGt(nextCutoffTime, block.timestamp, "next advertised request cutoff must remain in the future");
    }

    function _refreshMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(engine.orderRouter());
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

    function _epochAccountingDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                pool.currentLpEpoch(),
                pool.lastReconcileTime(),
                pool.lastSeniorCouponCheckpointTime(),
                pool.seniorPrincipal(),
                pool.juniorPrincipal(),
                pool.seniorHighWaterMark(),
                pool.accountedAssets(),
                pool.unassignedAssets(),
                pool.pendingRecapitalizationUsdc(),
                pool.pendingTradingRevenueUsdc(),
                pool.reservedSeniorDepositAssetsUsdc(),
                pool.terminalDeficitUsdc(),
                usdc.balanceOf(address(pool)),
                _vaultEpochAccountingDigest(seniorVault),
                _vaultEpochAccountingDigest(juniorVault)
            )
        );
    }

    function _vaultEpochAccountingDigest(
        TrancheVault vault
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.totalSupply(),
                vault.balanceOf(address(vault)),
                usdc.balanceOf(address(vault)),
                vault.pendingDepositEscrowAssets(),
                vault.pendingRedeemEscrowShares(),
                vault.depositClaimEscrowShares(),
                vault.withdrawalEscrowAssets(),
                vault.depositQueueHead(),
                vault.depositQueueTail(),
                vault.redeemQueueHead(),
                vault.redeemQueueTail(),
                _depositHeadDigest(vault),
                _redeemHeadDigest(vault)
            )
        );
    }

    function _depositHeadDigest(
        TrancheVault vault
    ) internal view returns (bytes32 digest) {
        uint256 epochId = vault.depositQueueHead();
        if (epochId == 0) {
            return bytes32(0);
        }

        (bool epochRead, bytes memory epochData) =
            address(vault).staticcall(abi.encodeWithSignature("depositEpochs(uint256)", epochId));
        (bool queueRead, bytes memory queueData) =
            address(vault).staticcall(abi.encodeWithSignature("depositEpochQueueState(uint256)", epochId));
        require(epochRead && queueRead, "deposit epoch digest read failed");
        return keccak256(abi.encode(epochId, epochData, queueData));
    }

    function _redeemHeadDigest(
        TrancheVault vault
    ) internal view returns (bytes32 digest) {
        uint256 epochId = vault.redeemQueueHead();
        if (epochId == 0) {
            return bytes32(0);
        }

        (bool epochRead, bytes memory epochData) =
            address(vault).staticcall(abi.encodeWithSignature("redeemEpochs(uint256)", epochId));
        (bool queueRead, bytes memory queueData) =
            address(vault).staticcall(abi.encodeWithSignature("redeemEpochQueueState(uint256)", epochId));
        require(epochRead && queueRead, "redeem epoch digest read failed");
        return keccak256(abi.encode(epochId, epochData, queueData));
    }

    function _revertSelector(
        bytes memory revertData
    ) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) {
            return bytes4(0);
        }
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }

}

contract PerpHousePoolLifecycleInvariantTest is BasePerpTest {

    PerpHousePoolLifecycleHandler internal handler;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpHousePoolLifecycleHandler(usdc, engine, pool, seniorVault, juniorVault, address(this));

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.initializeSeed.selector;
        selectors[1] = handler.activateTrading.selector;
        selectors[2] = handler.pausePool.selector;
        selectors[3] = handler.unpausePool.selector;
        selectors[4] = handler.setLpEpochSettlementHold.selector;
        selectors[5] = handler.attemptLpEpochSettlementWhileHeld.selector;
        selectors[6] = handler.requestDeposit.selector;
        selectors[7] = handler.requestRedeem.selector;
        selectors[8] = handler.settleLpEpoch.selector;
        selectors[9] = handler.claimDeposit.selector;
        selectors[10] = handler.claimRedeem.selector;
        selectors[11] = handler.transferShares.selector;
        selectors[12] = handler.warpForward.selector;
        selectors[13] = handler.mintExcess.selector;
        selectors[14] = handler.accountExcess.selector;
        selectors[15] = handler.sweepExcess.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        handler.setLpEpochSettlementHold(true);
        handler.attemptLpEpochSettlementWhileHeld();
        handler.setLpEpochSettlementHold(false);
    }

    function invariant_SeedLifecycleFlagsStayConsistent() public view {
        bool seniorSeeded = pool.seniorSeedInitialized();
        bool juniorSeeded = pool.juniorSeedInitialized();
        bool lifecycleComplete = seniorSeeded && juniorSeeded;

        assertEq(pool.hasSeedLifecycleStarted(), seniorSeeded || juniorSeeded, "seed lifecycle started mismatch");
        assertEq(pool.isSeedLifecycleComplete(), lifecycleComplete, "seed lifecycle complete mismatch");
        assertEq(
            pool.canAcceptOrdinaryDeposits(),
            lifecycleComplete && pool.isTradingActive(),
            "ordinary deposit gate mismatch"
        );
        assertEq(pool.canIncreaseRisk(), lifecycleComplete && pool.isTradingActive(), "risk-increase gate mismatch");
        if (pool.isTradingActive()) {
            assertTrue(lifecycleComplete, "trading cannot be active before both seeds initialize");
        }
    }

    function invariant_SeedFloorsRemainPreserved() public view {
        _assertSeedFloorPreserved(seniorVault);
        _assertSeedFloorPreserved(juniorVault);
    }

    function invariant_PositiveRequestDepositCapacityRequiresActiveLifecycle() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);

            if (seniorVault.maxRequestDeposit(actor) > 0) {
                assertTrue(pool.canAcceptOrdinaryDeposits(), "senior deposits require active lifecycle");
                assertFalse(pool.paused(), "senior deposits must be paused when pool is paused");
            }
            if (juniorVault.maxRequestDeposit(actor) > 0) {
                assertTrue(pool.canAcceptOrdinaryDeposits(), "junior deposits require active lifecycle");
                assertFalse(pool.paused(), "junior deposits must be paused when pool is paused");
            }
        }
    }

    function invariant_AsyncRequestAndClaimLimitsMatchQueueState() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            _assertVaultAsyncLimits(seniorVault, actor);
            _assertVaultAsyncLimits(juniorVault, actor);
        }
    }

    function invariant_RawAssetsSplitIntoCanonicalAssetsAndExcess() public view {
        assertEq(
            pool.rawAssets(),
            pool.totalAssets() + pool.excessAssets(),
            "raw pool assets must split into canonical assets plus excess"
        );
    }

    function invariant_AsyncEscrowsConserveVaultCustody() public view {
        _assertEscrowConservation(seniorVault);
        _assertEscrowConservation(juniorVault);
    }

    function invariant_HeldLpEpochSettlementAttemptsRevertWithoutAccountingMutation() public view {
        assertGt(handler.ghostHeldSettlementAttempts(), 0, "held settlement action must remain reachable");
        assertEq(handler.ghostHeldSettlementUnexpectedSuccesses(), 0, "held LP epoch settlement must never succeed");
        assertEq(
            handler.ghostHeldSettlementWrongReverts(), 0, "held LP epoch settlement must use the dedicated hold error"
        );
        assertEq(
            handler.ghostHeldSettlementAccountingMutations(),
            0,
            "held LP epoch settlement must not mutate epoch accounting"
        );
    }

    function invariant_ShareTransfersPropagateCooldownTimestamp() public view {
        PerpHousePoolLifecycleHandler.LastTransfer memory lastTransfer = handler.lastTransferSnapshot();
        if (!lastTransfer.active) {
            return;
        }

        TrancheVault vault = lastTransfer.isSenior ? seniorVault : juniorVault;
        uint256 expectedTimestamp = lastTransfer.receiverTimestampBefore > lastTransfer.senderTimestamp
            ? lastTransfer.receiverTimestampBefore
            : lastTransfer.senderTimestamp;

        assertGe(
            vault.lastDepositTime(lastTransfer.to),
            expectedTimestamp,
            "share transfer must preserve or tighten the receiver cooldown timestamp"
        );
    }

    function _assertSeedFloorPreserved(
        TrancheVault vault
    ) internal view {
        address seedReceiver_ = vault.seedReceiver();
        uint256 seedShareFloor_ = vault.seedShareFloor();
        if (seedReceiver_ == address(0) || seedShareFloor_ == 0) {
            return;
        }

        assertGe(vault.balanceOf(seedReceiver_), seedShareFloor_, "seed receiver must retain the configured floor");
        assertGe(vault.totalSupply(), seedShareFloor_, "total supply must always cover the seed floor");
    }

    function _assertEscrowConservation(
        TrancheVault vault
    ) internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.pendingDepositEscrowAssets() + vault.withdrawalEscrowAssets(),
            "vault USDC must equal pending-deposit plus withdrawal-claim escrow"
        );
        assertEq(
            vault.balanceOf(address(vault)),
            vault.pendingRedeemEscrowShares() + vault.depositClaimEscrowShares(),
            "vault shares must equal pending-redeem plus deposit-claim escrow"
        );
    }

    function _assertVaultAsyncLimits(
        TrancheVault vault,
        address actor
    ) internal view {
        uint256 depositHead = vault.controllerDepositHead(actor);
        uint256 expectedClaimableDepositAssets =
            depositHead == 0 ? 0 : vault.claimableDepositRequest(depositHead, actor);
        uint256 expectedClaimableDepositShares = depositHead == 0 ? 0 : vault.claimableDepositShares(depositHead, actor);
        assertEq(vault.maxDeposit(actor), expectedClaimableDepositAssets, "maxDeposit must match deposit claim head");
        assertEq(vault.maxMint(actor), expectedClaimableDepositShares, "maxMint must match deposit claim head");

        uint256 redeemHead = vault.controllerRedeemHead(actor);
        uint256 expectedClaimableRedeemAssets = redeemHead == 0 ? 0 : vault.claimableRedeemAssets(redeemHead, actor);
        uint256 expectedClaimableRedeemShares = redeemHead == 0 ? 0 : vault.claimableRedeemRequest(redeemHead, actor);
        uint256 maxWithdraw_ = vault.maxWithdraw(actor);
        uint256 maxRedeem_ = vault.maxRedeem(actor);
        assertEq(maxWithdraw_, expectedClaimableRedeemAssets, "maxWithdraw must match redeem claim head");
        assertEq(maxRedeem_, expectedClaimableRedeemShares, "maxRedeem must match redeem claim head");

        uint256 unlockedShares = _unlockedShares(vault, actor);
        bool coolingDown = block.timestamp < vault.lastDepositTime(actor) + vault.DEPOSIT_COOLDOWN();

        if (coolingDown) {
            assertEq(vault.maxRequestRedeem(actor), 0, "cooldown must zero maxRequestRedeem");
            return;
        }

        assertLe(vault.maxRequestRedeem(actor), unlockedShares, "redeem requests cannot exceed unlocked shares");
    }

    function _unlockedShares(
        TrancheVault vault,
        address actor
    ) internal view returns (uint256 unlockedShares) {
        unlockedShares = vault.balanceOf(actor);
        if (actor == vault.seedReceiver() && actor != address(0)) {
            uint256 floor = vault.seedShareFloor();
            unlockedShares = unlockedShares > floor ? unlockedShares - floor : 0;
        }
    }

}
