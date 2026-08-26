// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

    struct JuniorFeeSnapshot {
        uint256 rawSupply;
        uint256 effectiveSupply;
        uint256 pendingShares;
        uint256 recipientShares;
        uint256 checkpointBoundary;
    }

    struct JuniorSettlementPricingSnapshot {
        uint256 principal;
        uint256 rawSupply;
        uint256 effectiveSupply;
        uint256 feeBps;
    }

    struct RedeemEpochPricingSnapshot {
        uint256 epochId;
        uint256 fundedShares;
        uint256 fundedAssets;
    }

    struct DepositEpochPricingSnapshot {
        uint256 epochId;
        uint256 assets;
        uint256 shares;
        bool finalized;
    }

    struct JuniorSettlementSnapshot {
        JuniorFeeSnapshot fee;
        JuniorSettlementPricingSnapshot pricing;
        RedeemEpochPricingSnapshot[] redeemEpochs;
        DepositEpochPricingSnapshot[] depositEpochs;
    }

    struct DepositPricingState {
        uint256 postRedemptionSupply;
        uint256 postRedemptionPrincipal;
        uint256 observedAssets;
        uint256 observedShares;
        uint256 expectedCumulativeShares;
    }

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    HousePool public immutable pool;
    TrancheVault public immutable seniorVault;
    TrancheVault public immutable juniorVault;
    address public immutable owner;
    address public immutable feeRecipient;
    uint256 public immutable initialFeeRecipientShares;

    address[4] internal actors;
    LastTransfer internal lastTransfer;

    uint256 public ghostHeldSettlementAttempts;
    uint256 public ghostHeldSettlementUnexpectedSuccesses;
    uint256 public ghostHeldSettlementWrongReverts;
    uint256 public ghostHeldSettlementAccountingMutations;
    uint256 public ghostHeldSettlementFeeMutations;
    uint256 public ghostHeldFeeAccrualChecks;
    uint256 public ghostHeldFeeAccrualIncreases;
    uint256 public ghostHeldFeeAccrualRegressions;

    uint256 public ghostFeeMaterializationAttempts;
    uint256 public ghostFeeSettlementMaterializations;
    uint256 public ghostFeeSharesMaterialized;
    uint256 public ghostFeeRecipientMismatches;
    uint256 public ghostFeeRawSupplyMismatches;
    uint256 public ghostFeeEffectiveSupplyMismatches;
    uint256 public ghostFeeIsolationAttempts;
    uint256 public ghostFeeIsolationAccountingMutations;

    uint256 public ghostJuniorRedemptionPricingChecks;
    uint256 public ghostJuniorRedemptionPricingMismatches;
    uint256 public ghostJuniorRedemptionEffectiveSupplyChecks;
    uint256 public ghostJuniorRedemptionRawSupplyQuoteDivergences;
    uint256 public ghostJuniorDepositPricingChecks;
    uint256 public ghostJuniorDepositPricingMismatches;
    uint256 public ghostJuniorDepositEffectiveSupplyChecks;
    uint256 public ghostJuniorDepositRawSupplyQuoteDivergences;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        TrancheVault _seniorVault,
        TrancheVault _juniorVault,
        address _owner,
        address _feeRecipient
    ) {
        usdc = _usdc;
        engine = _engine;
        pool = _pool;
        seniorVault = _seniorVault;
        juniorVault = _juniorVault;
        owner = _owner;
        feeRecipient = _feeRecipient;
        initialFeeRecipientShares = _juniorVault.balanceOf(_feeRecipient);

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
        if (!_hasSettleableLpEpoch(cutoffEpoch)) {
            return;
        }

        _refreshMark();
        JuniorSettlementSnapshot memory before_;
        before_.fee = _juniorFeeSnapshot();
        before_.pricing = _juniorSettlementPricingSnapshot(before_.fee);
        before_.redeemEpochs = _maturedJuniorRedeemSnapshots(cutoffEpoch);
        before_.depositEpochs = _maturedJuniorDepositSnapshots(cutoffEpoch);
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);
        _recordJuniorSettlementPricing(before_.pricing, before_.redeemEpochs, before_.depositEpochs, result);
        bool juniorSupplyMutated = result.juniorDepositShares != 0 || result.juniorFundedShares != 0;
        _recordJuniorFeeMutation(
            before_.fee, result.juniorDepositShares, result.juniorFundedShares, juniorSupplyMutated
        );
        if (juniorSupplyMutated && juniorVault.balanceOf(feeRecipient) > before_.fee.recipientShares) {
            ghostFeeSettlementMaterializations++;
        }
    }

    function _hasSettleableLpEpoch(
        uint256 cutoffEpoch
    ) private view returns (bool) {
        (, uint256 seniorRedeemShares) = seniorVault.getMaturedRedeemHead(cutoffEpoch);
        (, uint256 juniorRedeemShares) = juniorVault.getMaturedRedeemHead(cutoffEpoch);
        (, uint256 seniorDepositAssets) = seniorVault.getMaturedDepositHead(cutoffEpoch);
        (, uint256 juniorDepositAssets) = juniorVault.getMaturedDepositHead(cutoffEpoch);
        bool hasMaturedRedeem = seniorRedeemShares != 0 || juniorRedeemShares != 0;
        bool hasMaturedDeposit = seniorDepositAssets != 0 || juniorDepositAssets != 0;
        return hasMaturedRedeem || (hasMaturedDeposit && !pool.paused());
    }

    function attemptLpEpochSettlementWhileHeld() external {
        if (!pool.lpEpochSettlementPaused()) {
            return;
        }

        bytes32 accountingBefore = _epochAccountingDigest();
        JuniorFeeSnapshot memory feeBefore = _juniorFeeSnapshot();
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
        JuniorFeeSnapshot memory feeAfter = _juniorFeeSnapshot();
        if (
            feeAfter.rawSupply != feeBefore.rawSupply || feeAfter.effectiveSupply != feeBefore.effectiveSupply
                || feeAfter.pendingShares != feeBefore.pendingShares
                || feeAfter.recipientShares != feeBefore.recipientShares
                || feeAfter.checkpointBoundary != feeBefore.checkpointBoundary
        ) {
            ghostHeldSettlementFeeMutations++;
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

        JuniorFeeSnapshot memory feeBefore;
        uint256 depositClaimEscrowBefore;
        if (!isSenior) {
            feeBefore = _juniorFeeSnapshot();
            depositClaimEscrowBefore = vault.depositClaimEscrowShares();
        }
        vm.prank(actor);
        uint256 claimedShares = vault.claimDeposit(requestId, claimableAssets, actor, actor);
        if (!isSenior) {
            uint256 depositClaimEscrowAfter = vault.depositClaimEscrowShares();
            uint256 escrowDecrease = depositClaimEscrowBefore - depositClaimEscrowAfter;
            uint256 burnedShareDust = escrowDecrease - claimedShares;
            _recordJuniorFeeMutation(feeBefore, 0, burnedShareDust, burnedShareDust != 0);
        }
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
        bool checkHeldAccrual =
            pool.lpEpochSettlementPaused() && juniorVault.maintenanceFeeAprBps() != 0 && juniorVault.totalSupply() != 0;
        uint256 pendingBefore = checkHeldAccrual ? juniorVault.pendingMaintenanceFeeShares() : 0;
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 3 days));
        if (checkHeldAccrual) {
            uint256 pendingAfter = juniorVault.pendingMaintenanceFeeShares();
            ghostHeldFeeAccrualChecks++;
            if (pendingAfter < pendingBefore) {
                ghostHeldFeeAccrualRegressions++;
            } else if (pendingAfter > pendingBefore) {
                ghostHeldFeeAccrualIncreases++;
            }
        }
    }

    /// @notice Materializes accrued fees through the real timelocked configuration finalization path.
    /// @dev Re-proposes the active configuration so the only lasting mutation is the old-rate fee checkpoint.
    function materializeJuniorMaintenanceFee() external {
        uint256 aprBps = juniorVault.maintenanceFeeAprBps();
        if (aprBps == 0 || juniorVault.maintenanceFeeRecipient() != feeRecipient || juniorVault.totalSupply() == 0) {
            return;
        }

        vm.prank(owner);
        juniorVault.proposeMaintenanceFeeConfig(aprBps, feeRecipient);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());

        JuniorFeeSnapshot memory feeBefore = _juniorFeeSnapshot();
        bytes32 accountingBefore = _feeIndependentAccountingDigest();
        vm.prank(owner);
        juniorVault.finalizeMaintenanceFeeConfig();

        ghostFeeIsolationAttempts++;
        _recordJuniorFeeMutation(feeBefore, 0, 0, true);
        if (_feeIndependentAccountingDigest() != accountingBefore) {
            ghostFeeIsolationAccountingMutations++;
        }
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

    function _recordJuniorFeeMutation(
        JuniorFeeSnapshot memory feeBefore,
        uint256 ordinaryMintedShares,
        uint256 ordinaryBurnedShares,
        bool shouldCheckpoint
    ) internal {
        JuniorFeeSnapshot memory feeAfter = _juniorFeeSnapshot();
        if (feeBefore.effectiveSupply != feeBefore.rawSupply + feeBefore.pendingShares) {
            ghostFeeEffectiveSupplyMismatches++;
        }
        if (feeAfter.effectiveSupply != feeAfter.rawSupply + feeAfter.pendingShares) {
            ghostFeeEffectiveSupplyMismatches++;
        }

        if (feeAfter.recipientShares < feeBefore.recipientShares) {
            ghostFeeRecipientMismatches++;
            return;
        }
        uint256 recipientDelta = feeAfter.recipientShares - feeBefore.recipientShares;
        uint256 expectedFeeShares = shouldCheckpoint ? feeBefore.pendingShares : 0;
        if (recipientDelta != expectedFeeShares) {
            ghostFeeRecipientMismatches++;
        }
        if (shouldCheckpoint && feeAfter.pendingShares != 0) {
            ghostFeeEffectiveSupplyMismatches++;
        }

        uint256 grossExpectedSupply = feeBefore.rawSupply + recipientDelta + ordinaryMintedShares;
        if (
            ordinaryBurnedShares > grossExpectedSupply
                || feeAfter.rawSupply != grossExpectedSupply - ordinaryBurnedShares
        ) {
            ghostFeeRawSupplyMismatches++;
        }

        if (recipientDelta != 0) {
            ghostFeeMaterializationAttempts++;
            ghostFeeSharesMaterialized += recipientDelta;
        }
    }

    function _juniorFeeSnapshot() internal view returns (JuniorFeeSnapshot memory snapshot) {
        snapshot.rawSupply = juniorVault.totalSupply();
        snapshot.effectiveSupply = juniorVault.accruedTotalSupply();
        snapshot.pendingShares = juniorVault.pendingMaintenanceFeeShares();
        snapshot.recipientShares = juniorVault.balanceOf(feeRecipient);
        snapshot.checkpointBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
    }

    function _juniorSettlementPricingSnapshot(
        JuniorFeeSnapshot memory feeSnapshot
    ) internal view returns (JuniorSettlementPricingSnapshot memory snapshot) {
        (, snapshot.principal) = pool.getPendingDepositTrancheState();
        snapshot.rawSupply = feeSnapshot.rawSupply;
        snapshot.effectiveSupply = feeSnapshot.effectiveSupply;
        snapshot.feeBps = pool.frozenLpFeeBps(false);
    }

    function _maturedJuniorRedeemSnapshots(
        uint256 cutoffEpoch
    ) internal view returns (RedeemEpochPricingSnapshot[] memory snapshots) {
        snapshots = new RedeemEpochPricingSnapshot[](pool.MAX_LP_EPOCHS_PER_PHASE());
        uint256 epochId = juniorVault.redeemQueueHead();
        for (uint256 i = 0; i < snapshots.length && epochId != 0 && epochId <= cutoffEpoch; ++i) {
            (uint256 fundedShares, uint256 fundedAssets) = _juniorRedeemFundingState(epochId);
            snapshots[i] =
                RedeemEpochPricingSnapshot({epochId: epochId, fundedShares: fundedShares, fundedAssets: fundedAssets});
            epochId = _nextJuniorRedeemEpoch(epochId);
        }
    }

    function _maturedJuniorDepositSnapshots(
        uint256 cutoffEpoch
    ) internal view returns (DepositEpochPricingSnapshot[] memory snapshots) {
        snapshots = new DepositEpochPricingSnapshot[](pool.MAX_LP_EPOCHS_PER_PHASE());
        uint256 epochId = juniorVault.depositQueueHead();
        for (uint256 i = 0; i < snapshots.length && epochId != 0 && epochId <= cutoffEpoch; ++i) {
            (uint256 assets, uint256 shares, bool finalized) = _juniorDepositEpochState(epochId);
            snapshots[i] =
                DepositEpochPricingSnapshot({epochId: epochId, assets: assets, shares: shares, finalized: finalized});
            epochId = _nextJuniorDepositEpoch(epochId);
        }
    }

    function _recordJuniorSettlementPricing(
        JuniorSettlementPricingSnapshot memory pricingBefore,
        RedeemEpochPricingSnapshot[] memory redeemEpochsBefore,
        DepositEpochPricingSnapshot[] memory depositEpochsBefore,
        IHousePool.LpEpochSettlementResult memory result
    ) internal {
        _recordJuniorRedemptionPricing(pricingBefore, redeemEpochsBefore, result);
        _recordJuniorDepositPricing(pricingBefore, depositEpochsBefore, result);
    }

    function _recordJuniorRedemptionPricing(
        JuniorSettlementPricingSnapshot memory pricingBefore,
        RedeemEpochPricingSnapshot[] memory epochsBefore,
        IHousePool.LpEpochSettlementResult memory result
    ) internal {
        uint256 observedFundedShares;
        uint256 observedFundedAssets;
        for (uint256 i = 0; i < epochsBefore.length; ++i) {
            RedeemEpochPricingSnapshot memory epochBefore = epochsBefore[i];
            if (epochBefore.epochId == 0) {
                break;
            }

            (uint256 fundedSharesAfter, uint256 fundedAssetsAfter) = _juniorRedeemFundingState(epochBefore.epochId);
            if (fundedSharesAfter < epochBefore.fundedShares || fundedAssetsAfter < epochBefore.fundedAssets) {
                ghostJuniorRedemptionPricingMismatches++;
                continue;
            }

            uint256 fundedShares = fundedSharesAfter - epochBefore.fundedShares;
            uint256 fundedAssets = fundedAssetsAfter - epochBefore.fundedAssets;
            if (fundedShares == 0 && fundedAssets == 0) {
                continue;
            }

            ghostJuniorRedemptionPricingChecks++;
            uint256 expectedAssets = _referenceJuniorRedeemAssets(
                fundedShares, pricingBefore.principal, pricingBefore.effectiveSupply, pricingBefore.feeBps
            );
            if (pricingBefore.effectiveSupply > pricingBefore.rawSupply) {
                ghostJuniorRedemptionEffectiveSupplyChecks++;
                if (
                    expectedAssets
                        != _referenceJuniorRedeemAssets(
                            fundedShares, pricingBefore.principal, pricingBefore.rawSupply, pricingBefore.feeBps
                        )
                ) {
                    ghostJuniorRedemptionRawSupplyQuoteDivergences++;
                }
            }
            observedFundedShares += fundedShares;
            observedFundedAssets += fundedAssets;
            if (fundedShares == 0 || fundedAssets != expectedAssets) {
                ghostJuniorRedemptionPricingMismatches++;
            }
        }

        if (observedFundedShares != result.juniorFundedShares || observedFundedAssets != result.juniorFundedAssets) {
            ghostJuniorRedemptionPricingMismatches++;
        }
    }

    function _recordJuniorDepositPricing(
        JuniorSettlementPricingSnapshot memory pricingBefore,
        DepositEpochPricingSnapshot[] memory epochsBefore,
        IHousePool.LpEpochSettlementResult memory result
    ) internal {
        if (
            result.juniorFundedShares > pricingBefore.effectiveSupply
                || result.juniorFundedAssets > pricingBefore.principal
        ) {
            ghostJuniorDepositPricingMismatches++;
            return;
        }

        DepositPricingState memory state;
        state.postRedemptionSupply = pricingBefore.effectiveSupply - result.juniorFundedShares;
        state.postRedemptionPrincipal = pricingBefore.principal - result.juniorFundedAssets;
        for (uint256 i = 0; i < epochsBefore.length; ++i) {
            DepositEpochPricingSnapshot memory epochBefore = epochsBefore[i];
            if (epochBefore.epochId == 0) {
                break;
            }
            state = _recordJuniorDepositEpoch(pricingBefore, epochBefore, result.juniorFundedShares, state);
        }

        if (state.observedAssets != result.juniorDepositAssets || state.observedShares != result.juniorDepositShares) {
            ghostJuniorDepositPricingMismatches++;
        }
    }

    function _recordJuniorDepositEpoch(
        JuniorSettlementPricingSnapshot memory pricingBefore,
        DepositEpochPricingSnapshot memory epochBefore,
        uint256 juniorFundedShares,
        DepositPricingState memory state
    ) private returns (DepositPricingState memory) {
        (uint256 assetsAfter, uint256 sharesAfter, bool finalizedAfter) = _juniorDepositEpochState(epochBefore.epochId);
        if (epochBefore.finalized || !finalizedAfter) {
            return state;
        }

        ghostJuniorDepositPricingChecks++;
        if (pricingBefore.effectiveSupply > pricingBefore.rawSupply) {
            ghostJuniorDepositEffectiveSupplyChecks++;
        }
        state.observedAssets += epochBefore.assets;
        uint256 nextExpectedCumulativeShares = _referenceJuniorDepositShares(
            state.observedAssets, state.postRedemptionPrincipal, state.postRedemptionSupply
        );
        uint256 expectedEpochShares = nextExpectedCumulativeShares - state.expectedCumulativeShares;
        state.expectedCumulativeShares = nextExpectedCumulativeShares;
        if (
            pricingBefore.effectiveSupply > pricingBefore.rawSupply && juniorFundedShares == 0
                && nextExpectedCumulativeShares
                    != _referenceJuniorDepositShares(
                        state.observedAssets, state.postRedemptionPrincipal, pricingBefore.rawSupply
                    )
        ) {
            ghostJuniorDepositRawSupplyQuoteDivergences++;
        }
        state.observedShares += sharesAfter;
        if (
            assetsAfter != epochBefore.assets || sharesAfter < epochBefore.shares
                || sharesAfter - epochBefore.shares != expectedEpochShares
        ) {
            ghostJuniorDepositPricingMismatches++;
        }
        return state;
    }

    function _referenceJuniorRedeemAssets(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (shares == 0 || feeBps >= 10_000) {
            return 0;
        }
        uint256 grossAssets = Math.mulDiv(shares, principal + 1, supply + 1000, Math.Rounding.Floor);
        return Math.mulDiv(grossAssets, 10_000 - feeBps, 10_000, Math.Rounding.Floor);
    }

    function _referenceJuniorDepositShares(
        uint256 assets,
        uint256 principal,
        uint256 supply
    ) internal pure returns (uint256) {
        return Math.mulDiv(assets, supply + 1000, principal + 1, Math.Rounding.Floor);
    }

    function _juniorRedeemFundingState(
        uint256 epochId
    ) internal view returns (uint256 fundedShares, uint256 fundedAssets) {
        (, fundedShares, fundedAssets,,,,,,,) = juniorVault.redeemEpochs(epochId);
    }

    function _juniorDepositEpochState(
        uint256 epochId
    ) internal view returns (uint256 assets, uint256 shares, bool finalized) {
        (assets, shares,,, finalized) = juniorVault.depositEpochs(epochId);
    }

    function _nextJuniorRedeemEpoch(
        uint256 epochId
    ) internal view returns (uint256 nextEpoch) {
        (, nextEpoch,,) = juniorVault.redeemEpochQueueState(epochId);
    }

    function _nextJuniorDepositEpoch(
        uint256 epochId
    ) internal view returns (uint256 nextEpoch) {
        (, nextEpoch,,) = juniorVault.depositEpochQueueState(epochId);
    }

    function _feeIndependentAccountingDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolFeeIndependentDigest(),
                usdc.totalSupply(),
                usdc.balanceOf(address(pool)),
                _vaultFeeIndependentDigest(seniorVault),
                _vaultFeeIndependentDigest(juniorVault),
                _knownActorShareBalancesDigest(seniorVault),
                _knownActorShareBalancesDigest(juniorVault)
            )
        );
    }

    function _poolFeeIndependentDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
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
                pool.terminalDeficitUsdc()
            )
        );
    }

    function _vaultFeeIndependentDigest(
        TrancheVault vault
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.balanceOf(address(vault)),
                usdc.balanceOf(address(vault)),
                vault.pendingDepositEscrowAssets(),
                vault.pendingRedeemEscrowShares(),
                vault.depositClaimEscrowShares(),
                vault.withdrawalEscrowAssets()
            )
        );
    }

    function _knownActorShareBalancesDigest(
        TrancheVault vault
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.balanceOf(actors[0]),
                vault.balanceOf(actors[1]),
                vault.balanceOf(actors[2]),
                vault.balanceOf(actors[3])
            )
        );
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
                _poolEpochAccountingDigest(),
                usdc.balanceOf(address(pool)),
                _vaultEpochAccountingDigest(seniorVault),
                _vaultEpochAccountingDigest(juniorVault)
            )
        );
    }

    function _poolEpochAccountingDigest() private view returns (bytes32) {
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
                pool.terminalDeficitUsdc()
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
                _vaultQueueAccountingDigest(vault)
            )
        );
    }

    function _vaultQueueAccountingDigest(
        TrancheVault vault
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
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

        handler =
            new PerpHousePoolLifecycleHandler(usdc, engine, pool, seniorVault, juniorVault, address(this), address(0));

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

    function _assertInvariant_SeedLifecycleFlagsStayConsistent() internal view {
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

    function _assertInvariant_SeedFloorsRemainPreserved() internal view {
        _assertSeedFloorPreserved(seniorVault);
        _assertSeedFloorPreserved(juniorVault);
    }

    function _assertInvariant_PositiveRequestDepositCapacityRequiresActiveLifecycle() internal view {
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

    function _assertInvariant_AsyncRequestAndClaimLimitsMatchQueueState() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            _assertVaultAsyncLimits(seniorVault, actor);
            _assertVaultAsyncLimits(juniorVault, actor);
        }
    }

    function _assertInvariant_RawAssetsSplitIntoCanonicalAssetsAndExcess() internal view {
        assertEq(
            pool.rawAssets(),
            pool.totalAssets() + pool.excessAssets(),
            "raw pool assets must split into canonical assets plus excess"
        );
    }

    function _assertInvariant_AsyncEscrowsConserveVaultCustody() internal view {
        _assertEscrowConservation(seniorVault);
        _assertEscrowConservation(juniorVault);
    }

    function _assertInvariant_HeldLpEpochSettlementAttemptsRevertWithoutAccountingMutation() internal view {
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

    function _assertInvariant_ShareTransfersPropagateCooldownTimestamp() internal view {
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

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_SeedLifecycleFlagsStayConsistent();
        _assertInvariant_SeedFloorsRemainPreserved();
        _assertInvariant_PositiveRequestDepositCapacityRequiresActiveLifecycle();
        _assertInvariant_AsyncRequestAndClaimLimitsMatchQueueState();
        _assertInvariant_RawAssetsSplitIntoCanonicalAssetsAndExcess();
        _assertInvariant_AsyncEscrowsConserveVaultCustody();
        _assertInvariant_HeldLpEpochSettlementAttemptsRevertWithoutAccountingMutation();
        _assertInvariant_ShareTransfersPropagateCooldownTimestamp();
    }

}

/// @notice Fee-enabled companion campaign that preserves the original lifecycle campaign's seed-order state space.
contract PerpHousePoolMaintenanceFeeInvariantTest is BasePerpTest {

    address internal constant FEE_RECIPIENT = address(0xFEE1);

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

        handler = new PerpHousePoolLifecycleHandler(
            usdc, engine, pool, seniorVault, juniorVault, address(this), FEE_RECIPIENT
        );

        // Give the fee real backing supply; the original companion contract retains the unconstrained seed ordering.
        handler.initializeSeed(false, 1000e6);
        juniorVault.proposeMaintenanceFeeConfig(1000, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();

        // Make fee minting and its isolation checks non-vacuously reachable in every campaign.
        handler.materializeJuniorMaintenanceFee();

        // Complete only this companion campaign's lifecycle so a real epoch settlement can crystallize the fee.
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(engine.orderRouter());
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        handler.initializeSeed(true, 1000e6);
        handler.activateTrading();

        bytes4[] memory selectors = new bytes4[](17);
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
        selectors[16] = handler.materializeJuniorMaintenanceFee.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        // A held period accrues virtually, while a settlement attempt cannot crystallize or advance the fee.
        handler.setLpEpochSettlementHold(true);
        handler.warpForward(2 hours);
        handler.attemptLpEpochSettlementWhileHeld();
        handler.setLpEpochSettlementHold(false);

        handler.requestDeposit(false, 1, 1000e6, false);
        handler.warpForward(2 hours);
        handler.settleLpEpoch();

        // Exercise the other side of the same pricing snapshot with virtual fee dilution outstanding.
        handler.claimDeposit(false, 1);
        handler.warpForward(2 hours);
        uint256 actorShares = juniorVault.balanceOf(handler.actorAt(1));
        handler.requestRedeem(false, 1, actorShares, false);
        handler.warpForward(2 hours);
        handler.settleLpEpoch();
    }

    function _assertInvariant_EffectiveSupplySeparatesPendingFeeFromRawErc20Supply() internal view {
        uint256 rawJuniorSupply = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();

        assertEq(
            juniorVault.accruedTotalSupply(),
            rawJuniorSupply + pendingFeeShares,
            "Junior effective supply must include unmaterialized dilution"
        );
        assertEq(
            seniorVault.accruedTotalSupply(),
            seniorVault.totalSupply(),
            "Senior effective supply must remain raw supply"
        );
        assertEq(seniorVault.pendingMaintenanceFeeShares(), 0, "Senior must never accrue maintenance-fee shares");

        uint256 completedBoundary = block.timestamp - (block.timestamp % 1 hours);
        if (rawJuniorSupply != 0 && completedBoundary > juniorVault.maintenanceFeeCheckpointBoundary()) {
            assertGt(pendingFeeShares, 0, "elapsed Junior fee hours must accrue independently of tranche NAV");
        }
    }

    function _assertInvariant_MaterializedFeeSharesOnlyIncreaseRawSupplyAndRecipientBalance() internal view {
        assertGt(handler.ghostFeeMaterializationAttempts(), 0, "fee materialization must remain reachable");
        assertGt(handler.ghostFeeSettlementMaterializations(), 0, "epoch settlement must materialize accrued fees");
        assertGt(handler.ghostFeeSharesMaterialized(), 0, "fee campaign must mint nonzero fee shares");
        assertEq(handler.ghostFeeRecipientMismatches(), 0, "fee shares must credit only the configured recipient");
        assertEq(handler.ghostFeeRawSupplyMismatches(), 0, "raw Junior supply delta must isolate fee minting");
        assertEq(
            handler.ghostFeeEffectiveSupplyMismatches(),
            0,
            "effective and raw Junior supply must reconcile at checkpoints"
        );
        assertEq(
            juniorVault.balanceOf(FEE_RECIPIENT),
            handler.initialFeeRecipientShares() + handler.ghostFeeSharesMaterialized(),
            "recipient balance must equal cumulatively observed fee mints"
        );
    }

    function _assertInvariant_FeeCheckpointDoesNotMutatePoolEconomicsOrEscrows() internal view {
        assertGt(handler.ghostFeeIsolationAttempts(), 0, "isolated configuration checkpoint must remain reachable");
        assertEq(
            handler.ghostFeeIsolationAccountingMutations(),
            0,
            "fee-only checkpoint must not mutate principal, HWM, assets, USDC, or escrows"
        );
    }

    function _assertInvariant_JuniorSettlementPricingUsesEffectiveSupplyAndRedemptionFirstOrdering() internal view {
        assertGt(handler.ghostJuniorDepositPricingChecks(), 0, "Junior deposit pricing must remain reachable");
        assertGt(handler.ghostJuniorRedemptionPricingChecks(), 0, "Junior redemption pricing must remain reachable");
        assertGt(
            handler.ghostJuniorDepositEffectiveSupplyChecks(),
            0,
            "Junior deposit pricing must be checked while pending dilution exists"
        );
        assertGt(
            handler.ghostJuniorRedemptionEffectiveSupplyChecks(),
            0,
            "Junior redemption pricing must be checked while pending dilution exists"
        );
        assertGt(
            handler.ghostJuniorDepositRawSupplyQuoteDivergences(),
            0,
            "the exercised Junior deposit quote must distinguish effective from raw supply"
        );
        assertGt(
            handler.ghostJuniorRedemptionRawSupplyQuoteDivergences(),
            0,
            "the exercised Junior redemption quote must distinguish effective from raw supply"
        );
        assertEq(
            handler.ghostJuniorDepositPricingMismatches(),
            0,
            "accepted Junior deposits must use exact post-redemption effective-supply pricing"
        );
        assertEq(
            handler.ghostJuniorRedemptionPricingMismatches(),
            0,
            "funded Junior redemptions must use pre-mutation effective-supply pricing"
        );
    }

    function _assertInvariant_HeldSettlementAccruesButCannotMaterializeMaintenanceFee() internal view {
        assertGt(handler.ghostHeldFeeAccrualChecks(), 0, "held-period accrual check must remain reachable");
        assertGt(handler.ghostHeldFeeAccrualIncreases(), 0, "maintenance fee must accrue during a settlement hold");
        assertEq(handler.ghostHeldFeeAccrualRegressions(), 0, "held time must not reduce pending fee accrual");
        assertGt(handler.ghostHeldSettlementAttempts(), 0, "held settlement attempt must remain reachable");
        assertEq(handler.ghostHeldSettlementUnexpectedSuccesses(), 0, "held settlement must not succeed");
        assertEq(handler.ghostHeldSettlementWrongReverts(), 0, "held settlement must use its dedicated error");
        assertEq(handler.ghostHeldSettlementAccountingMutations(), 0, "held settlement must not mutate LP accounting");
        assertEq(
            handler.ghostHeldSettlementFeeMutations(),
            0,
            "held settlement must not mint fees or advance the fee checkpoint"
        );
    }

    function _assertInvariant_RawShareSupplyIsConservedAcrossKnownHolders() internal view {
        uint256 seniorKnownShares = seniorVault.balanceOf(address(seniorVault));
        uint256 juniorKnownShares = juniorVault.balanceOf(address(juniorVault)) + juniorVault.balanceOf(FEE_RECIPIENT);

        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address actor = handler.actorAt(i);
            seniorKnownShares += seniorVault.balanceOf(actor);
            juniorKnownShares += juniorVault.balanceOf(actor);
        }

        assertEq(seniorVault.totalSupply(), seniorKnownShares, "raw Senior supply must equal known holder balances");
        assertEq(juniorVault.totalSupply(), juniorKnownShares, "raw Junior supply must equal known holder balances");
    }

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_EffectiveSupplySeparatesPendingFeeFromRawErc20Supply();
        _assertInvariant_MaterializedFeeSharesOnlyIncreaseRawSupplyAndRecipientBalance();
        _assertInvariant_FeeCheckpointDoesNotMutatePoolEconomicsOrEscrows();
        _assertInvariant_JuniorSettlementPricingUsesEffectiveSupplyAndRedemptionFirstOrdering();
        _assertInvariant_HeldSettlementAccruesButCannotMaterializeMaintenanceFee();
        _assertInvariant_RawShareSupplyIsConservedAcrossKnownHolders();
    }

}
