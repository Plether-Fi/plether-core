// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

contract JuniorMaintenanceFeeTest is BasePerpTest {

    event MaintenanceFeeConfigProposed(uint256 aprBps, address indexed recipient, uint256 activationTime);
    event MaintenanceFeeConfigFinalized(
        uint256 previousAprBps,
        address indexed previousRecipient,
        uint256 newAprBps,
        address indexed newRecipient,
        uint256 checkpointBoundary
    );
    event MaintenanceFeeConfigProposalCancelled(uint256 aprBps, address indexed recipient, uint256 activationTime);
    event MaintenanceFeeCheckpointed(
        uint256 indexed previousBoundary,
        uint256 indexed newBoundary,
        address indexed recipient,
        uint256 aprBps,
        uint256 mintedShares,
        uint256 chargedHours,
        uint256 forgivenHours
    );

    struct EconomicSnapshot {
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 seniorHighWaterMark;
        uint256 seniorTotalSupply;
        uint256 accountedAssets;
        uint256 poolUsdc;
        uint256 vaultUsdc;
        uint256 pendingDepositEscrowAssets;
        uint256 pendingRedeemEscrowShares;
        uint256 depositClaimEscrowShares;
        uint256 withdrawalEscrowAssets;
    }

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HOURS_PER_YEAR = 8760;
    uint256 internal constant VIRTUAL_SHARES = 1000;
    uint256 internal constant SATURDAY_ORACLE_FREEZE = 1_710_021_600;

    address internal constant FEE_RECIPIENT = address(0xFEE1);
    address internal constant ROTATED_FEE_RECIPIENT = address(0xFEE2);
    address internal constant NEW_POOL_OWNER = address(0xA11CE);
    address internal constant NON_OWNER = address(0xBAD);
    address internal constant LP = address(0xB0B);
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant TRADER = address(0x7A0E2);

    function test_DefaultsToZeroAndSeniorNeverAccrues() public view {
        assertEq(juniorVault.maintenanceFeeAprBps(), 0);
        assertEq(juniorVault.maintenanceFeeRecipient(), address(0));
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(juniorVault.accruedTotalSupply(), juniorVault.totalSupply());
        assertEq(juniorVault.maintenanceFeeConfigActivationTime(), 0);

        (uint256 pendingAprBps, address pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 0);
        assertEq(pendingRecipient, address(0));

        assertEq(seniorVault.maintenanceFeeAprBps(), 0);
        assertEq(seniorVault.maintenanceFeeRecipient(), address(0));
        assertEq(seniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(seniorVault.accruedTotalSupply(), seniorVault.totalSupply());
    }

    function test_MaintenanceFeeAdministrationIsJuniorOnlyAndTracksCurrentPoolOwner() public {
        vm.expectRevert(TrancheVault.TrancheVault__NotPoolOwner.selector);
        vm.prank(NON_OWNER);
        juniorVault.proposeMaintenanceFeeConfig(200, FEE_RECIPIENT);

        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeSeniorUnsupported.selector);
        seniorVault.proposeMaintenanceFeeConfig(200, FEE_RECIPIENT);

        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeSeniorUnsupported.selector);
        seniorVault.finalizeMaintenanceFeeConfig();

        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeSeniorUnsupported.selector);
        seniorVault.cancelMaintenanceFeeConfigProposal();

        juniorVault.proposeMaintenanceFeeConfig(200, FEE_RECIPIENT);
        pool.transferOwnership(NEW_POOL_OWNER);
        vm.prank(NEW_POOL_OWNER);
        pool.acceptOwnership();

        vm.expectRevert(TrancheVault.TrancheVault__NotPoolOwner.selector);
        juniorVault.cancelMaintenanceFeeConfigProposal();

        vm.prank(NEW_POOL_OWNER);
        juniorVault.cancelMaintenanceFeeConfigProposal();
        assertEq(juniorVault.maintenanceFeeConfigActivationTime(), 0);

        vm.prank(NEW_POOL_OWNER);
        juniorVault.proposeMaintenanceFeeConfig(300, ROTATED_FEE_RECIPIENT);
        (uint256 pendingAprBps, address pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 300);
        assertEq(pendingRecipient, ROTATED_FEE_RECIPIENT);

        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        vm.expectRevert(TrancheVault.TrancheVault__NotPoolOwner.selector);
        juniorVault.finalizeMaintenanceFeeConfig();

        vm.prank(NEW_POOL_OWNER);
        juniorVault.finalizeMaintenanceFeeConfig();
        assertEq(juniorVault.maintenanceFeeAprBps(), 300);
        assertEq(juniorVault.maintenanceFeeRecipient(), ROTATED_FEE_RECIPIENT);
    }

    function test_MaintenanceFeeGovernanceRequiresTheCompleteCanonicalVaultPair() public {
        (HousePool deploymentPool, TrancheVault futureSenior, TrancheVault candidateJunior) =
            _deployUnregisteredVaultPair();

        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        candidateJunior.proposeMaintenanceFeeConfig(200, address(futureSenior));
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        candidateJunior.finalizeMaintenanceFeeConfig();
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        candidateJunior.cancelMaintenanceFeeConfigProposal();

        deploymentPool.setJuniorVault(address(candidateJunior));
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        candidateJunior.proposeMaintenanceFeeConfig(200, address(futureSenior));

        deploymentPool.setSeniorVault(address(futureSenior));
        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRecipient.selector);
        candidateJunior.proposeMaintenanceFeeConfig(200, address(futureSenior));

        TrancheVault imposterJunior = new TrancheVault(
            IERC20(address(usdc)), address(deploymentPool), false, "Imposter Junior LP", "imposterJuniorUSDC"
        );
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        imposterJunior.proposeMaintenanceFeeConfig(200, FEE_RECIPIENT);
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        imposterJunior.finalizeMaintenanceFeeConfig();
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeVaultPairNotReady.selector);
        imposterJunior.cancelMaintenanceFeeConfigProposal();

        candidateJunior.proposeMaintenanceFeeConfig(200, FEE_RECIPIENT);
        candidateJunior.cancelMaintenanceFeeConfigProposal();
    }

    function test_RateCapAndRecipientPolicy() public {
        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRate.selector);
        juniorVault.proposeMaintenanceFeeConfig(1001, FEE_RECIPIENT);

        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRecipient.selector);
        juniorVault.proposeMaintenanceFeeConfig(1, address(0));

        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRecipient.selector);
        juniorVault.proposeMaintenanceFeeConfig(1, address(pool));

        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRecipient.selector);
        juniorVault.proposeMaintenanceFeeConfig(1, address(seniorVault));

        vm.expectRevert(TrancheVault.TrancheVault__InvalidMaintenanceFeeRecipient.selector);
        juniorVault.proposeMaintenanceFeeConfig(1, address(juniorVault));

        juniorVault.proposeMaintenanceFeeConfig(1000, FEE_RECIPIENT);
        (uint256 pendingAprBps, address pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 1000);
        assertEq(pendingRecipient, FEE_RECIPIENT);

        juniorVault.proposeMaintenanceFeeConfig(100, address(usdc));
        (pendingAprBps, pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 100, "asset recipient is intentionally permitted");
        assertEq(pendingRecipient, address(usdc));

        juniorVault.proposeMaintenanceFeeConfig(0, FEE_RECIPIENT);
        (pendingAprBps, pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 0, "zero rate need not clear the recipient");
        assertEq(pendingRecipient, FEE_RECIPIENT);
    }

    function test_ProposalRequiresFull48HoursAndFinalizesAtEquality() public {
        uint256 proposedAt = block.timestamp;
        juniorVault.proposeMaintenanceFeeConfig(250, FEE_RECIPIENT);
        uint256 activationTime = juniorVault.maintenanceFeeConfigActivationTime();

        assertEq(activationTime, proposedAt + 48 hours);
        assertEq(juniorVault.maintenanceFeeAprBps(), 0);

        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeTimelockNotReady.selector);
        juniorVault.finalizeMaintenanceFeeConfig();

        vm.warp(activationTime - 1);
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeTimelockNotReady.selector);
        juniorVault.finalizeMaintenanceFeeConfig();

        vm.warp(activationTime);
        juniorVault.finalizeMaintenanceFeeConfig();

        assertEq(juniorVault.maintenanceFeeAprBps(), 250);
        assertEq(juniorVault.maintenanceFeeRecipient(), FEE_RECIPIENT);
        assertEq(juniorVault.maintenanceFeeConfigActivationTime(), 0);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), _nextHourBoundary(block.timestamp));
        (uint256 pendingAprBps, address pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 0);
        assertEq(pendingRecipient, address(0));

        vm.expectRevert(TrancheVault.TrancheVault__NoMaintenanceFeeProposal.selector);
        juniorVault.finalizeMaintenanceFeeConfig();
    }

    function test_ProposalCanBeReplacedAndCancelled() public {
        juniorVault.proposeMaintenanceFeeConfig(100, FEE_RECIPIENT);
        uint256 firstActivation = juniorVault.maintenanceFeeConfigActivationTime();

        vm.warp(block.timestamp + 12 hours);
        juniorVault.proposeMaintenanceFeeConfig(300, ROTATED_FEE_RECIPIENT);
        uint256 replacementActivation = juniorVault.maintenanceFeeConfigActivationTime();
        (uint256 pendingAprBps, address pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();

        assertEq(replacementActivation, block.timestamp + 48 hours);
        assertGt(replacementActivation, firstActivation);
        assertEq(pendingAprBps, 300);
        assertEq(pendingRecipient, ROTATED_FEE_RECIPIENT);

        vm.warp(firstActivation);
        vm.expectRevert(TrancheVault.TrancheVault__MaintenanceFeeTimelockNotReady.selector);
        juniorVault.finalizeMaintenanceFeeConfig();

        juniorVault.cancelMaintenanceFeeConfigProposal();
        assertEq(juniorVault.maintenanceFeeConfigActivationTime(), 0);
        (pendingAprBps, pendingRecipient) = juniorVault.pendingMaintenanceFeeConfig();
        assertEq(pendingAprBps, 0);
        assertEq(pendingRecipient, address(0));

        vm.expectRevert(TrancheVault.TrancheVault__NoMaintenanceFeeProposal.selector);
        juniorVault.cancelMaintenanceFeeConfigProposal();
    }

    function test_EnablementIsProspectiveFromTheFinalizationBoundary() public {
        uint256 rawSupply = juniorVault.totalSupply();
        vm.warp(block.timestamp + 100 days);

        uint256 recipientSharesBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        _enableFee(juniorVault, 200, FEE_RECIPIENT);
        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();

        assertEq(juniorVault.totalSupply(), rawSupply, "disabled history must not mint retroactive fees");
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), recipientSharesBefore);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(juniorVault.accruedTotalSupply(), rawSupply);

        vm.warp(startBoundary + 1 hours - 1);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0, "partial hours do not accrue");

        vm.warp(startBoundary + 1 hours);
        assertGt(juniorVault.pendingMaintenanceFeeShares(), 0, "first post-enable completed hour accrues");
    }

    function test_OneHourAccrualUsesEffectiveSupplyAndMintsBeforeSupplyMutation() public {
        uint256 aprBps = 876;
        _enableFee(juniorVault, aprBps, FEE_RECIPIENT);
        uint256 rawSupply = juniorVault.totalSupply();
        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(startBoundary + 1 hours);

        uint256 hourlyFeeRay = Math.mulDiv(aprBps, RAY, BPS * HOURS_PER_YEAR, Math.Rounding.Floor);
        uint256 expectedFeeShares = Math.mulDiv(rawSupply, hourlyFeeRay, RAY - hourlyFeeRay, Math.Rounding.Floor);
        assertGt(expectedFeeShares, 0);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), expectedFeeShares);
        assertEq(juniorVault.accruedTotalSupply(), rawSupply + expectedFeeShares);

        uint256 recipientSharesBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        _poolMint(juniorVault, 1, LP);

        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientSharesBefore, expectedFeeShares);
        assertEq(juniorVault.totalSupply(), rawSupply + expectedFeeShares + 1);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), block.timestamp);
    }

    function test_DisableFinalizationPaysAllOldRateAccrualToOldRecipient() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(startBoundary + 24 hours);

        juniorVault.proposeMaintenanceFeeConfig(0, address(0));
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        uint256 oldFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 oldRecipientBalance = juniorVault.balanceOf(FEE_RECIPIENT);
        uint256 rawSupply = juniorVault.totalSupply();

        juniorVault.finalizeMaintenanceFeeConfig();

        assertGt(oldFeeShares, 0);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - oldRecipientBalance, oldFeeShares);
        assertEq(juniorVault.totalSupply(), rawSupply + oldFeeShares);
        assertEq(juniorVault.maintenanceFeeAprBps(), 0);
        assertEq(juniorVault.maintenanceFeeRecipient(), address(0));
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);

        vm.warp(block.timestamp + 365 days);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0, "disabled fee must remain disabled");
    }

    function test_RecipientRotationPaysOldAccrualBeforeNewRecipientStarts() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(startBoundary + 24 hours);

        juniorVault.proposeMaintenanceFeeConfig(250, ROTATED_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        uint256 oldFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 oldRecipientBalance = juniorVault.balanceOf(FEE_RECIPIENT);

        juniorVault.finalizeMaintenanceFeeConfig();

        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - oldRecipientBalance, oldFeeShares);
        assertEq(juniorVault.balanceOf(ROTATED_FEE_RECIPIENT), 0);
        assertEq(juniorVault.maintenanceFeeAprBps(), 250);
        assertEq(juniorVault.maintenanceFeeRecipient(), ROTATED_FEE_RECIPIENT);

        uint256 rotatedBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(rotatedBoundary + 1 hours);
        uint256 newFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 oldRecipientAfterRotation = juniorVault.balanceOf(FEE_RECIPIENT);
        _poolMint(juniorVault, 1, LP);

        assertGt(newFeeShares, 0);
        assertEq(juniorVault.balanceOf(ROTATED_FEE_RECIPIENT), newFeeShares);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), oldRecipientAfterRotation);
    }

    function test_OrdinaryTransferDoesNotCheckpointAndStillHonorsCooldown() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        _poolMint(juniorVault, 100e9, LP);

        vm.expectRevert(TrancheVault.TrancheVault__TransferDuringCooldown.selector);
        vm.prank(LP);
        juniorVault.transfer(RECEIVER, 1e9);

        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(startBoundary + 1 hours);
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupply = juniorVault.totalSupply();
        uint256 recipientBalance = juniorVault.balanceOf(FEE_RECIPIENT);
        uint256 checkpointBoundary = juniorVault.maintenanceFeeCheckpointBoundary();

        vm.prank(LP);
        juniorVault.transfer(RECEIVER, 1e9);

        assertGt(pendingFeeShares, 0);
        assertEq(juniorVault.totalSupply(), rawSupply);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), recipientBalance);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), pendingFeeShares);
        assertEq(juniorVault.balanceOf(RECEIVER), 1e9);
    }

    function test_CatchUpChargesAtMostOneYearAndForgivesOlderHours() public {
        _enableFee(juniorVault, 1000, FEE_RECIPIENT);
        uint256 startBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.warp(startBoundary + HOURS_PER_YEAR * 1 hours);
        uint256 feeAtCap = juniorVault.pendingMaintenanceFeeShares();

        vm.warp(block.timestamp + 137 hours);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeAtCap, "hours beyond one year are forgiven");

        uint256 recipientBalance = juniorVault.balanceOf(FEE_RECIPIENT);
        _poolMint(juniorVault, 1, LP);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalance, feeAtCap);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), block.timestamp);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);

        vm.warp(block.timestamp + 1 hours);
        assertGt(juniorVault.pendingMaintenanceFeeShares(), 0, "post-forgiveness hours accrue from the new boundary");
    }

    function test_ZeroSupplyHistoryIsNotChargedWhenFirstSharesAreMinted() public {
        (HousePool emptyPool, TrancheVault emptySenior, TrancheVault emptyJunior) = _deployUnregisteredVaultPair();
        emptyPool.setSeniorVault(address(emptySenior));
        emptyPool.setJuniorVault(address(emptyJunior));
        _enableFee(emptyJunior, 1000, FEE_RECIPIENT);
        uint256 startBoundary = emptyJunior.maintenanceFeeCheckpointBoundary();

        vm.warp(startBoundary + (HOURS_PER_YEAR + 137) * 1 hours);
        assertEq(emptyJunior.totalSupply(), 0);
        assertEq(emptyJunior.pendingMaintenanceFeeShares(), 0);
        assertEq(emptyJunior.accruedTotalSupply(), 0);

        uint256 nextBoundary = _nextHourBoundary(block.timestamp);
        vm.expectEmit(true, true, true, true, address(emptyJunior));
        emit MaintenanceFeeCheckpointed(startBoundary, nextBoundary, FEE_RECIPIENT, 1000, 0, 0, 0);
        vm.prank(address(emptyPool));
        emptyJunior.bootstrapMint(100e9, LP);
        assertEq(emptyJunior.balanceOf(FEE_RECIPIENT), 0, "empty-vault history must not mint fee shares");
        assertEq(emptyJunior.totalSupply(), 100e9);
        assertEq(emptyJunior.pendingMaintenanceFeeShares(), 0);
        assertEq(emptyJunior.maintenanceFeeCheckpointBoundary(), nextBoundary);

        vm.warp(nextBoundary + 1 hours);
        assertGt(emptyJunior.pendingMaintenanceFeeShares(), 0, "new supply begins accruing prospectively");
    }

    function test_PendingDepositIsExcludedUntilAcceptedDepositCheckpointsFee() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);

        uint256 assets = 100_000e6;
        uint256 rawSupplyBeforeRequest = juniorVault.totalSupply();
        uint256 pendingFeeBeforeRequest = juniorVault.pendingMaintenanceFeeShares();
        uint256 accruedSupplyBeforeRequest = juniorVault.accruedTotalSupply();
        uint256 requestId = _requestJuniorDeposit(LP, assets);

        assertGt(pendingFeeBeforeRequest, 0);
        assertEq(juniorVault.totalSupply(), rawSupplyBeforeRequest, "deposit request must not mint shares");
        assertEq(
            juniorVault.pendingMaintenanceFeeShares(),
            pendingFeeBeforeRequest,
            "pending assets must not enter fee supply"
        );
        assertEq(juniorVault.accruedTotalSupply(), accruedSupplyBeforeRequest);
        assertEq(juniorVault.pendingDepositEscrowAssets(), assets);

        _matureAsyncRequest(requestId);
        uint256 pendingFeeAtAcceptance = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupplyAtAcceptance = juniorVault.totalSupply();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorDepositAssets, assets);
        assertGt(result.juniorDepositShares, 0);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeAtAcceptance);
        assertEq(
            juniorVault.totalSupply(),
            rawSupplyAtAcceptance + pendingFeeAtAcceptance + result.juniorDepositShares,
            "fee must mint before newly accepted deposit shares"
        );
        assertEq(juniorVault.claimableDepositRequest(requestId, LP), assets);
        assertEq(juniorVault.claimableDepositShares(requestId, LP), result.juniorDepositShares);

        vm.prank(LP);
        uint256 claimedShares = juniorVault.claimDeposit(requestId, assets, LP, LP);
        assertEq(claimedShares, result.juniorDepositShares);
        assertEq(juniorVault.balanceOf(LP), claimedShares);
    }

    function test_ActivatedUnclaimedDepositSharesRemainInTheFeeBase() public {
        _enableFee(juniorVault, 1000, FEE_RECIPIENT);

        uint256 assets = 100_000e6;
        uint256 requestId = _requestJuniorDeposit(LP, assets);
        _matureAsyncRequest(requestId);
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        uint256 claimEscrowShares = juniorVault.depositClaimEscrowShares();
        uint256 rawSupply = juniorVault.totalSupply();
        assertEq(claimEscrowShares, result.juniorDepositShares, "activated shares must remain in claim escrow");
        assertGt(claimEscrowShares, 0);
        assertGt(rawSupply, claimEscrowShares, "fixture requires incumbent and unclaimed shares");

        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        uint256 hourlyFeeRay = Math.mulDiv(1000, RAY, BPS * HOURS_PER_YEAR, Math.Rounding.Floor);
        uint256 expectedWithClaimEscrow = Math.mulDiv(rawSupply, hourlyFeeRay, RAY - hourlyFeeRay, Math.Rounding.Floor);
        uint256 expectedWithoutClaimEscrow =
            Math.mulDiv(rawSupply - claimEscrowShares, hourlyFeeRay, RAY - hourlyFeeRay, Math.Rounding.Floor);

        assertGt(
            expectedWithClaimEscrow,
            expectedWithoutClaimEscrow,
            "unclaimed activated shares must materially affect this fixture"
        );
        assertEq(
            juniorVault.pendingMaintenanceFeeShares(),
            expectedWithClaimEscrow,
            "deposit-claim escrow shares must pay the same maintenance fee as all issued shares"
        );
        assertEq(juniorVault.depositClaimEscrowShares(), claimEscrowShares, "fee accrual cannot reprice the claim");
    }

    function test_PendingRedeemSharesRemainFeeBearingUntilFundedBurn() public {
        uint256 lpShares = _fundJuniorDelayed(LP, 100_000e6);
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);

        uint256 redeemShares = lpShares / 4;
        uint256 rawSupplyBeforeRequest = juniorVault.totalSupply();
        uint256 pendingFeeBeforeRequest = juniorVault.pendingMaintenanceFeeShares();
        vm.prank(LP);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, LP, LP);

        assertGt(pendingFeeBeforeRequest, 0);
        assertEq(juniorVault.totalSupply(), rawSupplyBeforeRequest, "escrowing a redeem must not burn shares");
        assertEq(
            juniorVault.pendingMaintenanceFeeShares(),
            pendingFeeBeforeRequest,
            "escrowed redeem shares remain in fee-bearing supply"
        );
        assertEq(juniorVault.pendingRedeemEscrowShares(), redeemShares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), redeemShares);

        _matureAsyncRequest(requestId);
        uint256 pendingFeeAtFunding = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupplyAtFunding = juniorVault.totalSupply();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorFundedShares, redeemShares);
        assertGt(result.juniorFundedAssets, 0);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeAtFunding);
        assertEq(
            juniorVault.totalSupply(),
            rawSupplyAtFunding + pendingFeeAtFunding - redeemShares,
            "fee must mint before funded redeem shares burn"
        );
        assertEq(juniorVault.claimableRedeemRequest(requestId, LP), redeemShares);
        assertEq(juniorVault.claimableRedeemAssets(requestId, LP), result.juniorFundedAssets);

        vm.prank(LP);
        uint256 claimedAssets = juniorVault.claimRedeem(requestId, redeemShares, LP, LP);
        assertEq(claimedAssets, result.juniorFundedAssets);
        assertEq(usdc.balanceOf(LP), claimedAssets);
    }

    function test_PartialRedeemFundingCheckpointsOnceAndContinuesCumulatively() public {
        uint256 lpShares = _fundJuniorDelayed(LP, 300_000e6);
        uint256 transferredShares = (juniorVault.balanceOf(address(this)) * 3) / 5;
        juniorVault.transfer(LP, transferredShares);
        lpShares += transferredShares;

        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        _refreshEngineMark();
        uint256 positionSize = _reserveLiquidityLeaving(790_000e6);

        vm.prank(LP);
        uint256 requestId = juniorVault.requestRedeem(lpShares, LP, LP);
        _matureAsyncRequest(requestId);

        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeBefore = juniorVault.pendingMaintenanceFeeShares();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        IHousePool.LpEpochSettlementResult memory first = _settleLpEpochForTest();

        assertGt(pendingFeeBefore, 0);
        assertGt(first.juniorFundedShares, 0);
        assertLt(first.juniorFundedShares, lpShares);
        assertTrue(first.juniorBacklog);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeBefore);
        assertEq(juniorVault.totalSupply(), rawSupplyBefore + pendingFeeBefore - first.juniorFundedShares);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        uint256 checkpointAfterFirstFunding = juniorVault.maintenanceFeeCheckpointBoundary();

        _close(TRADER, CfdTypes.Side.LONG, positionSize, 1e8);
        IHousePool.LpEpochSettlementResult memory second = _settleLpEpochForTest();

        assertGt(second.juniorFundedShares, 0);
        assertEq(first.juniorFundedShares + second.juniorFundedShares, lpShares);
        assertEq(juniorVault.claimableRedeemRequest(requestId, LP), lpShares);
        assertEq(
            juniorVault.claimableRedeemAssets(requestId, LP),
            first.juniorFundedAssets + second.juniorFundedAssets,
            "funded assets must accumulate under the same request"
        );
        assertEq(
            juniorVault.balanceOf(FEE_RECIPIENT),
            recipientBalanceBefore + pendingFeeBefore,
            "same-hour continuation must not mint maintenance fees twice"
        );
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointAfterFirstFunding);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
    }

    function test_ConfigFinalizationOnlyDilutesSharesAndDoesNotResetRecipientCooldown() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        _requestJuniorDeposit(LP, 10_000e6);

        uint256 redeemShares = juniorVault.balanceOf(address(this)) / 100;
        juniorVault.requestRedeem(redeemShares, address(this), address(this));
        assertGt(juniorVault.pendingDepositEscrowAssets(), 0);
        assertGt(juniorVault.pendingRedeemEscrowShares(), 0);

        juniorVault.proposeMaintenanceFeeConfig(250, ROTATED_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());

        uint256 oldFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        uint256 recipientCooldownBefore = juniorVault.lastDepositTime(FEE_RECIPIENT);
        EconomicSnapshot memory beforeSnapshot = _economicSnapshot();

        juniorVault.finalizeMaintenanceFeeConfig();

        assertGt(oldFeeShares, 0);
        assertEq(juniorVault.totalSupply(), rawSupplyBefore + oldFeeShares);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, oldFeeShares);
        _assertEconomicSnapshotEq(_economicSnapshot(), beforeSnapshot);
        assertEq(
            juniorVault.lastDepositTime(FEE_RECIPIENT),
            recipientCooldownBefore,
            "fee mint must not impose or reset a deposit cooldown"
        );

        vm.prank(FEE_RECIPIENT);
        juniorVault.transfer(RECEIVER, oldFeeShares);
        assertEq(
            juniorVault.balanceOf(RECEIVER), oldFeeShares, "freshly minted fee shares are immediately transferable"
        );
    }

    function test_FeeAccruesThroughZeroNavEntryPauseOracleFreezeAndSettlementHold() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        uint256 rawSupply = juniorVault.totalSupply();
        uint256 checkpointBoundary = juniorVault.maintenanceFeeCheckpointBoundary();

        pool.pause();
        vm.warp(checkpointBoundary + 1 hours);
        uint256 pausedFeeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(pausedFeeShares, 0, "entry pause must not stop accrual");
        assertEq(juniorVault.totalSupply(), rawSupply);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBoundary);

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IHousePool.getPendingTrancheState.selector),
            abi.encode(pool.seniorPrincipal(), uint256(0), uint256(0), uint256(0))
        );
        assertEq(juniorVault.totalAssets(), 0, "mocked terminal wipe supplies the zero-NAV state");
        assertEq(juniorVault.pendingMaintenanceFeeShares(), pausedFeeShares, "zero NAV must not stop share dilution");
        vm.clearMockedCalls();
        pool.unpause();

        vm.warp(SATURDAY_ORACLE_FREEZE);
        assertTrue(engine.isOracleFrozen(), "setup must reach the weekend oracle freeze");
        uint256 frozenFeeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(frozenFeeShares, pausedFeeShares, "oracle freeze must not stop accrual");
        assertEq(juniorVault.totalSupply(), rawSupply);

        pool.pauseLpEpochSettlement();
        vm.warp(block.timestamp + 1 hours);
        uint256 heldFeeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(heldFeeShares, frozenFeeShares, "settlement hold must not stop accrual");

        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        pool.settleLpEpoch(0, 0);

        assertEq(juniorVault.totalSupply(), rawSupply, "held settlement must not materialize fee shares");
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), recipientBalanceBefore);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), heldFeeShares);
    }

    function test_FailedSettlementRollsBackFeeCheckpointAndDepositActivation() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        uint256 assets = 100_000e6;
        uint256 requestId = _requestJuniorDeposit(LP, assets);
        _matureAsyncRequest(requestId);

        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeBefore = juniorVault.pendingMaintenanceFeeShares();
        uint256 checkpointBoundaryBefore = juniorVault.maintenanceFeeCheckpointBoundary();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        uint256 pendingDepositEscrowBefore = juniorVault.pendingDepositEscrowAssets();
        uint256 vaultUsdcBefore = usdc.balanceOf(address(juniorVault));
        uint256 poolUsdcBefore = usdc.balanceOf(address(pool));

        vm.mockCall(
            address(usdc), abi.encodeWithSelector(IERC20.balanceOf.selector, address(pool)), abi.encode(poolUsdcBefore)
        );
        vm.expectRevert();
        pool.settleLpEpoch(0, 0);
        vm.clearMockedCalls();

        assertEq(juniorVault.totalSupply(), rawSupplyBefore, "fee mint and accepted shares must roll back atomically");
        assertEq(juniorVault.pendingMaintenanceFeeShares(), pendingFeeBefore);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBoundaryBefore);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), recipientBalanceBefore);
        assertEq(juniorVault.pendingDepositEscrowAssets(), pendingDepositEscrowBefore);
        assertEq(usdc.balanceOf(address(juniorVault)), vaultUsdcBefore);
        assertEq(usdc.balanceOf(address(pool)), poolUsdcBefore);
        assertEq(juniorVault.claimableDepositRequest(requestId, LP), 0);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        assertEq(result.juniorDepositAssets, assets);
        assertGt(result.juniorDepositShares, 0);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeBefore);
        assertEq(juniorVault.claimableDepositRequest(requestId, LP), assets);
    }

    function test_AllConversionsAndEstimatesUseAccruedSupply() public {
        _enableFee(juniorVault, 1000, FEE_RECIPIENT);
        vm.warp(SATURDAY_ORACLE_FREEZE);
        assertTrue(engine.isOracleFrozen(), "setup must exercise the frozen exit-fee estimates");

        uint256 rawSupply = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 effectiveSupply = rawSupply + pendingFeeShares;
        uint256 totalAssets = juniorVault.totalAssets();
        (, uint256 depositPricingAssets) = pool.getPendingDepositTrancheState();
        uint256 assets = 123_456e6;
        uint256 shares = 98_765e9;
        uint256 frozenFeeBps = pool.frozenLpFeeBps(false);

        assertGt(pendingFeeShares, 0);
        assertGt(frozenFeeBps, 0);
        assertEq(juniorVault.accruedTotalSupply(), effectiveSupply);

        {
            uint256 expectedConvertedShares =
                Math.mulDiv(assets, effectiveSupply + VIRTUAL_SHARES, totalAssets + 1, Math.Rounding.Floor);
            uint256 expectedConvertedAssets =
                Math.mulDiv(shares, totalAssets + 1, effectiveSupply + VIRTUAL_SHARES, Math.Rounding.Floor);
            assertEq(juniorVault.convertToShares(assets), expectedConvertedShares);
            assertEq(juniorVault.convertToAssets(shares), expectedConvertedAssets);
            assertGt(
                expectedConvertedShares,
                Math.mulDiv(assets, rawSupply + VIRTUAL_SHARES, totalAssets + 1, Math.Rounding.Floor),
                "pending dilution must increase shares quoted per asset"
            );
            assertLt(
                expectedConvertedAssets,
                Math.mulDiv(shares, totalAssets + 1, rawSupply + VIRTUAL_SHARES, Math.Rounding.Floor),
                "pending dilution must reduce assets quoted per share"
            );
        }

        {
            uint256 expectedDepositShares =
                juniorVault.quoteDepositFromState(assets, depositPricingAssets, effectiveSupply, 0);
            assertEq(juniorVault.estimateDepositShares(assets), expectedDepositShares);
            assertEq(juniorVault.quoteBootstrapDeposit(assets), expectedDepositShares);
        }
        {
            uint256 expectedMintAssets =
                Math.mulDiv(shares, depositPricingAssets + 1, effectiveSupply + VIRTUAL_SHARES, Math.Rounding.Ceil);
            assertEq(juniorVault.estimateMintAssets(shares), expectedMintAssets);
        }
        {
            uint256 grossWithdrawAssets = Math.mulDiv(assets, BPS, BPS - frozenFeeBps, Math.Rounding.Ceil);
            uint256 expectedWithdrawShares =
                Math.mulDiv(grossWithdrawAssets, effectiveSupply + VIRTUAL_SHARES, totalAssets + 1, Math.Rounding.Ceil);
            assertEq(juniorVault.estimateWithdrawShares(assets), expectedWithdrawShares);
        }
        {
            uint256 grossRedeemAssets =
                Math.mulDiv(shares, totalAssets + 1, effectiveSupply + VIRTUAL_SHARES, Math.Rounding.Floor);
            uint256 expectedRedeemAssets = Math.mulDiv(grossRedeemAssets, BPS - frozenFeeBps, BPS, Math.Rounding.Floor);
            assertEq(juniorVault.estimateRedeemAssets(shares), expectedRedeemAssets);
        }
    }

    function test_DepositActivationUsesExactPreMintEffectiveSupplyPrice() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 2 hours);

        uint256 assets = 137_000e6;
        uint256 requestId = _requestJuniorDeposit(LP, assets);
        _matureAsyncRequest(requestId);

        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 effectiveSupply = rawSupplyBefore + pendingFeeShares;
        (, uint256 pricingAssets) = pool.getPendingDepositTrancheState();
        uint256 expectedDepositShares = juniorVault.quoteDepositFromState(assets, pricingAssets, effectiveSupply, 0);
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(pendingFeeShares, 0);
        assertEq(result.juniorDepositAssets, assets);
        assertEq(result.juniorDepositShares, expectedDepositShares);
        assertEq(juniorVault.claimableDepositShares(requestId, LP), expectedDepositShares);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeShares);
        assertEq(juniorVault.totalSupply(), effectiveSupply + expectedDepositShares);
    }

    function test_RedemptionFundingUsesExactPreBurnEffectiveSupplyPrice() public {
        uint256 lpShares = _fundJuniorDelayed(LP, 200_000e6);
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 2 hours);

        uint256 redeemShares = lpShares / 3;
        vm.prank(LP);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, LP, LP);
        _matureAsyncRequest(requestId);

        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 effectiveSupply = rawSupplyBefore + pendingFeeShares;
        uint256 pricingPrincipal = juniorVault.totalAssets();
        uint256 expectedRedeemAssets =
            Math.mulDiv(redeemShares, pricingPrincipal + 1, effectiveSupply + VIRTUAL_SHARES, Math.Rounding.Floor);
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(pendingFeeShares, 0);
        assertEq(pool.frozenLpFeeBps(false), 0);
        assertEq(result.juniorFundedShares, redeemShares);
        assertEq(result.juniorFundedAssets, expectedRedeemAssets);
        assertEq(juniorVault.claimableRedeemAssets(requestId, LP), expectedRedeemAssets);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, pendingFeeShares);
        assertEq(juniorVault.totalSupply(), effectiveSupply - redeemShares);
    }

    function test_CombinedSettlementPricesDepositAfterFeeMintAndRedemptionBurn() public {
        uint256 lpShares = _fundJuniorDelayed(LP, 250_000e6);
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 2 hours);

        uint256 redeemShares = lpShares / 5;
        vm.prank(LP);
        uint256 redeemRequestId = juniorVault.requestRedeem(redeemShares, LP, LP);
        uint256 depositAssets = 111_000e6;
        uint256 depositRequestId = _requestJuniorDeposit(RECEIVER, depositAssets);
        assertEq(depositRequestId, redeemRequestId, "requests must mature in the same LP epoch");
        _matureAsyncRequest(depositRequestId);

        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 effectiveSupplyBefore = rawSupplyBefore + pendingFeeShares;
        uint256 pricingPrincipalBefore = juniorVault.totalAssets();
        uint256 expectedRedeemAssets = Math.mulDiv(
            redeemShares, pricingPrincipalBefore + 1, effectiveSupplyBefore + VIRTUAL_SHARES, Math.Rounding.Floor
        );
        uint256 postRedeemSupply = effectiveSupplyBefore - redeemShares;
        uint256 postRedeemPrincipal = pricingPrincipalBefore - expectedRedeemAssets;
        uint256 expectedDepositShares =
            juniorVault.quoteDepositFromState(depositAssets, postRedeemPrincipal, postRedeemSupply, 0);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorFundedShares, redeemShares);
        assertEq(result.juniorFundedAssets, expectedRedeemAssets);
        assertEq(result.juniorDepositAssets, depositAssets);
        assertEq(
            result.juniorDepositShares,
            expectedDepositShares,
            "deposit must use the post-redemption principal and supply"
        );
        assertEq(juniorVault.claimableRedeemAssets(redeemRequestId, LP), expectedRedeemAssets);
        assertEq(juniorVault.claimableDepositShares(depositRequestId, RECEIVER), expectedDepositShares);
        assertEq(juniorVault.totalSupply(), postRedeemSupply + expectedDepositShares);
    }

    function test_ZeroNavFeeCrystallizesWorthlessThenParticipatesInRecovery() public {
        _enableFee(juniorVault, 500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 2 hours);

        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 juniorPrincipalBefore = pool.juniorPrincipal();
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IHousePool.getPendingTrancheState.selector),
            abi.encode(pool.seniorPrincipal(), uint256(0), uint256(0), uint256(0))
        );
        assertEq(juniorVault.totalAssets(), 0);

        _poolMint(juniorVault, 1, LP);

        assertGt(pendingFeeShares, 0);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), pendingFeeShares);
        assertEq(juniorVault.totalSupply(), rawSupplyBefore + pendingFeeShares + 1);
        assertEq(juniorVault.convertToAssets(pendingFeeShares), 0, "fee shares must initially be worthless at zero NAV");
        assertEq(pool.juniorPrincipal(), juniorPrincipalBefore, "share crystallization must not alter principal");

        vm.clearMockedCalls();
        uint256 recoveredValue = juniorVault.convertToAssets(pendingFeeShares);
        uint256 expectedRecoveredValue = Math.mulDiv(
            pendingFeeShares,
            juniorVault.totalAssets() + 1,
            juniorVault.totalSupply() + VIRTUAL_SHARES,
            Math.Rounding.Floor
        );
        assertGt(recoveredValue, 0, "ordinary fee shares must participate in later NAV recovery");
        assertEq(recoveredValue, expectedRecoveredValue);
    }

    function test_MidHourMintAndBurnShiftExposureByLessThanOneHour() public {
        vm.warp(block.timestamp + 17 minutes);
        _enableFee(juniorVault, 876, FEE_RECIPIENT);
        uint256 firstChargeBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        assertGt(firstChargeBoundary, block.timestamp);
        assertLt(firstChargeBoundary - block.timestamp, 1 hours);

        vm.warp(firstChargeBoundary + 30 minutes);
        uint256 midHourMintShares = 10_000e9;
        uint256 rawSupplyBeforeMint = juniorVault.totalSupply();
        _poolMint(juniorVault, midHourMintShares, LP);
        assertEq(juniorVault.totalSupply(), rawSupplyBeforeMint + midHourMintShares);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0, "no completed fee hour exists at the mid-hour mint");

        uint256 redeemShares = juniorVault.balanceOf(address(this)) / 100;
        juniorVault.requestRedeem(redeemShares, address(this), address(this));
        vm.warp(firstChargeBoundary + 1 hours + 30 minutes);
        _refreshEngineMark();

        uint256 rawSupplyBeforeBurn = juniorVault.totalSupply();
        uint256 expectedFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 recipientBalanceBefore = juniorVault.balanceOf(FEE_RECIPIENT);
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(expectedFeeShares, 0);
        assertEq(result.juniorFundedShares, redeemShares);
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT) - recipientBalanceBefore, expectedFeeShares);
        assertEq(juniorVault.totalSupply(), rawSupplyBeforeBurn + expectedFeeShares - redeemShares);
        assertEq(
            juniorVault.maintenanceFeeCheckpointBoundary(),
            firstChargeBoundary + 1 hours,
            "mid-hour burn checkpoints only the last completed Unix hour"
        );
        assertLt(block.timestamp - juniorVault.maintenanceFeeCheckpointBoundary(), 1 hours);

        vm.warp(firstChargeBoundary + 2 hours);
        assertGt(
            juniorVault.pendingMaintenanceFeeShares(),
            0,
            "the post-burn supply starts its next charge at the completed-hour boundary"
        );
    }

    function test_MaintenanceFeeEventsExposeTimelockAndCheckpointEconomics() public {
        uint256 activationTime = block.timestamp + juniorVault.MAINTENANCE_FEE_CONFIG_DELAY();
        vm.expectEmit(true, false, false, true, address(juniorVault));
        emit MaintenanceFeeConfigProposed(500, FEE_RECIPIENT, activationTime);
        juniorVault.proposeMaintenanceFeeConfig(500, FEE_RECIPIENT);

        vm.expectEmit(true, false, false, true, address(juniorVault));
        emit MaintenanceFeeConfigProposalCancelled(500, FEE_RECIPIENT, activationTime);
        juniorVault.cancelMaintenanceFeeConfigProposal();

        juniorVault.proposeMaintenanceFeeConfig(500, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        uint256 checkpointBoundary = _nextHourBoundary(block.timestamp);
        vm.expectEmit(true, true, false, true, address(juniorVault));
        emit MaintenanceFeeConfigFinalized(0, address(0), 500, FEE_RECIPIENT, checkpointBoundary);
        juniorVault.finalizeMaintenanceFeeConfig();

        vm.warp(checkpointBoundary + 3 hours);
        uint256 expectedFeeShares = juniorVault.pendingMaintenanceFeeShares();
        vm.expectEmit(true, true, true, true, address(juniorVault));
        emit MaintenanceFeeCheckpointed(
            checkpointBoundary, block.timestamp, FEE_RECIPIENT, 500, expectedFeeShares, 3, 0
        );
        _poolMint(juniorVault, 1, LP);
    }

    function _enableFee(
        TrancheVault vault,
        uint256 aprBps,
        address recipient
    ) internal {
        vault.proposeMaintenanceFeeConfig(aprBps, recipient);
        vm.warp(vault.maintenanceFeeConfigActivationTime());
        vault.finalizeMaintenanceFeeConfig();
    }

    function _poolMint(
        TrancheVault vault,
        uint256 shares,
        address receiver
    ) internal {
        vm.prank(address(pool));
        vault.bootstrapMint(shares, receiver);
    }

    function _deployUnregisteredVaultPair()
        internal
        returns (HousePool deploymentPool, TrancheVault deploymentSenior, TrancheVault deploymentJunior)
    {
        deploymentPool = new HousePool(address(usdc), address(engine), address(housePoolRedemptionMathSidecar));
        deploymentSenior = new TrancheVault(
            IERC20(address(usdc)), address(deploymentPool), true, "Deployment Senior LP", "deploymentSeniorUSDC"
        );
        deploymentJunior = new TrancheVault(
            IERC20(address(usdc)), address(deploymentPool), false, "Deployment Junior LP", "deploymentJuniorUSDC"
        );
    }

    function _requestJuniorDeposit(
        address lp,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(lp, assets);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, lp, lp);
        vm.stopPrank();
    }

    function _matureAsyncRequest(
        uint256 requestId
    ) internal {
        uint256 maturity = juniorVault.depositEpochStart(requestId);
        if (block.timestamp < maturity) {
            vm.warp(maturity);
        }
        _refreshEngineMark();
    }

    function _refreshEngineMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

    function _reserveLiquidityLeaving(
        uint256 targetFreeUsdc
    ) internal returns (uint256 positionSize) {
        uint256 assets = pool.totalAssets();
        assertGt(assets, targetFreeUsdc, "target free cash must be below pool assets");
        uint256 reservedUsdc = assets - targetFreeUsdc;
        uint256 maxLiabilityUsdc = reservedUsdc * 10_000 / (10_000 + engine.settlementBufferBps());
        maxLiabilityUsdc -= maxLiabilityUsdc % 100e6;
        uint256 margin = maxLiabilityUsdc / 10 + 10e6;
        _fundTrader(TRADER, margin);
        positionSize = maxLiabilityUsdc * 1e12;
        _open(TRADER, CfdTypes.Side.LONG, positionSize, margin, 1e8);
        uint256 settlementBufferUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engine.settlementBufferBps());
        uint256 expectedFreeUsdc = assets - maxLiabilityUsdc - settlementBufferUsdc;
        assertEq(pool.getFreeUSDC(), expectedFreeUsdc, "position must create the quantized cash budget");
        assertGe(expectedFreeUsdc, targetFreeUsdc, "lot quantization must not over-reserve the target budget");
        assertLe(
            expectedFreeUsdc - targetFreeUsdc,
            101e6,
            "one liability lot plus its buffer bounds the target-budget rounding"
        );
    }

    function _economicSnapshot() internal view returns (EconomicSnapshot memory snapshot) {
        snapshot.seniorPrincipal = pool.seniorPrincipal();
        snapshot.juniorPrincipal = pool.juniorPrincipal();
        snapshot.seniorHighWaterMark = pool.seniorHighWaterMark();
        snapshot.seniorTotalSupply = seniorVault.totalSupply();
        snapshot.accountedAssets = pool.accountedAssets();
        snapshot.poolUsdc = usdc.balanceOf(address(pool));
        snapshot.vaultUsdc = usdc.balanceOf(address(juniorVault));
        snapshot.pendingDepositEscrowAssets = juniorVault.pendingDepositEscrowAssets();
        snapshot.pendingRedeemEscrowShares = juniorVault.pendingRedeemEscrowShares();
        snapshot.depositClaimEscrowShares = juniorVault.depositClaimEscrowShares();
        snapshot.withdrawalEscrowAssets = juniorVault.withdrawalEscrowAssets();
    }

    function _assertEconomicSnapshotEq(
        EconomicSnapshot memory actual,
        EconomicSnapshot memory expected
    ) internal pure {
        assertEq(actual.seniorPrincipal, expected.seniorPrincipal, "senior principal changed");
        assertEq(actual.juniorPrincipal, expected.juniorPrincipal, "junior principal changed");
        assertEq(actual.seniorHighWaterMark, expected.seniorHighWaterMark, "senior HWM changed");
        assertEq(actual.seniorTotalSupply, expected.seniorTotalSupply, "senior raw supply changed");
        assertEq(actual.accountedAssets, expected.accountedAssets, "accounted assets changed");
        assertEq(actual.poolUsdc, expected.poolUsdc, "pool USDC changed");
        assertEq(actual.vaultUsdc, expected.vaultUsdc, "vault USDC changed");
        assertEq(
            actual.pendingDepositEscrowAssets, expected.pendingDepositEscrowAssets, "pending deposit escrow changed"
        );
        assertEq(actual.pendingRedeemEscrowShares, expected.pendingRedeemEscrowShares, "pending redeem escrow changed");
        assertEq(actual.depositClaimEscrowShares, expected.depositClaimEscrowShares, "deposit claim escrow changed");
        assertEq(actual.withdrawalEscrowAssets, expected.withdrawalEscrowAssets, "withdrawal escrow changed");
    }

    function _nextHourBoundary(
        uint256 timestamp
    ) internal pure returns (uint256) {
        uint256 remainder = timestamp % 1 hours;
        return remainder == 0 ? timestamp : timestamp + (1 hours - remainder);
    }

}
