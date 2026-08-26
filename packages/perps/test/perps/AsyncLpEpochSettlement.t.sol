// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @notice Focused integration coverage for the synchronized asynchronous LP queue.
contract AsyncLpEpochSettlementTest is BasePerpTest {

    event Deposit(address indexed controller, address indexed receiver, uint256 assets, uint256 shares);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant OPERATOR = address(0x0F3A4702);
    address internal constant TRADER = address(0x7A0E2);
    address internal constant MAINTENANCE_FEE_RECIPIENT = address(0xFEE70001);
    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600;
    uint256 internal constant MAINTENANCE_FEE_APR_BPS = 1000;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 0,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_RequestEpochWindowAndAsyncPreviews() public {
        (uint256 expectedDepositId,) = juniorVault.getRequestEpochWindow();
        uint256 depositId = _requestDeposit(juniorVault, ALICE, 100_000e6);
        assertEq(depositId, expectedDepositId, "deposit request must use the advertised epoch window");

        _settleAt(depositId);
        uint256 shares = _claimAllDeposit(juniorVault, depositId, ALICE);
        assertGt(shares, 0, "matured deposit must become claimable");
        _finishCooldown(juniorVault, ALICE);

        (uint256 expectedRedeemId,) = juniorVault.getRequestEpochWindow();
        uint256 redeemId = _requestRedeem(juniorVault, ALICE, shares / 2, ALICE, ALICE);
        assertEq(redeemId, expectedRedeemId, "redeem request must use the advertised epoch window");

        vm.expectRevert();
        juniorVault.previewDeposit(1e6);
        vm.expectRevert();
        juniorVault.previewMint(1e9);
        vm.expectRevert();
        juniorVault.previewWithdraw(1e6);
        vm.expectRevert();
        juniorVault.previewRedeem(1e9);
    }

    function test_AdvertisesErc7540AndErc7575Interfaces() public view {
        _assertAsyncInterfaces(seniorVault);
        _assertAsyncInterfaces(juniorVault);
    }

    function test_EpochCompatibilityViewsMatchPool() public view {
        uint256 currentEpoch = pool.currentLpEpoch();
        assertEq(juniorVault.currentLpEpoch(), currentEpoch);
        assertEq(juniorVault.currentDepositEpoch(), currentEpoch);
        assertEq(juniorVault.depositEpochStart(currentEpoch), pool.lpEpochStart(currentEpoch));
    }

    function test_AsyncRequestAndEmptyQueueValidationGuards() public {
        (uint256 depositEpoch, uint256 depositAssets) = juniorVault.getMaturedDepositHead(type(uint256).max);
        (uint256 redeemEpoch, uint256 redeemShares) = juniorVault.getMaturedRedeemHead(type(uint256).max);
        assertEq(depositEpoch, 0);
        assertEq(depositAssets, 0);
        assertEq(redeemEpoch, 0);
        assertEq(redeemShares, 0);
        assertEq(juniorVault.maxRequestRedeem(address(this)), 0, "seed shares must still be cooling down");

        uint256 amount = pool.minTrancheDepositUsdc();
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.requestDeposit(amount, address(0), ALICE);

        vm.prank(OPERATOR);
        vm.expectRevert(TrancheVault.TrancheVault__NotControllerOrOperator.selector);
        juniorVault.requestDeposit(amount, ALICE, ALICE);

        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.requestRedeem(1, address(0), ALICE);

        vm.prank(ALICE);
        vm.expectPartialRevert(TrancheVault.TrancheVault__ExceededMaxRequestRedeem.selector);
        juniorVault.requestRedeem(1, ALICE, ALICE);

        vm.expectRevert(TrancheVault.TrancheVault__InvalidFee.selector);
        juniorVault.quoteDepositFromState(amount, amount, 1e9, 10_001);

        vm.expectRevert(TrancheVault.TrancheVault__NotPool.selector);
        juniorVault.finalizeDepositEpochFromPool(0, 1);
    }

    function test_AsyncCancellationAndClaimValidationGuards() public {
        uint256 futureEpoch = pool.currentLpEpoch() + 1;

        vm.prank(OPERATOR);
        vm.expectRevert(TrancheVault.TrancheVault__NotControllerOrOperator.selector);
        juniorVault.cancelPendingDeposit(futureEpoch, ALICE, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.cancelPendingDeposit(futureEpoch, address(0), ALICE);

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.cancelRedeemRequest(futureEpoch, address(0));

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__NoPendingRedeem.selector);
        juniorVault.cancelRedeemRequest(futureEpoch, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.claimRedeemRefund(futureEpoch, address(0), ALICE);

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__RedeemRefundUnavailable.selector);
        juniorVault.claimRedeemRefund(futureEpoch, ALICE, ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.deposit(0, address(0), ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.mint(0, address(0), ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.redeem(0, address(0), ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__ZeroAddress.selector);
        juniorVault.withdraw(0, address(0), ALICE);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        juniorVault.redeem(1, ALICE, ALICE);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        juniorVault.withdraw(1, ALICE, ALICE);
        vm.stopPrank();

        uint256 requestId = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _settleAt(requestId);

        vm.startPrank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochFinalized.selector);
        juniorVault.cancelPendingDeposit(requestId, ALICE, ALICE);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        juniorVault.deposit(0, ALICE, ALICE);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxMint.selector);
        juniorVault.mint(0, ALICE, ALICE);
        vm.stopPrank();
    }

    function test_NoProgressSettlementRevertsWithoutCheckpointingAccounting() public {
        _fundPair(ALICE, 100_000e6, BOB, 100_000e6);
        uint256 checkpointBefore = pool.lastSeniorCouponCheckpointTime();
        uint256 lastReconcileBefore = pool.lastReconcileTime();
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 hwmBefore = pool.seniorHighWaterMark();
        uint256 accountedBefore = pool.accountedAssets();
        uint256 unassignedBefore = pool.unassignedAssets();
        assertGt(block.timestamp, checkpointBefore, "setup needs elapsed coupon time");

        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);

        assertEq(pool.lastSeniorCouponCheckpointTime(), checkpointBefore, "no-op settlement must roll back checkpoint");
        assertEq(pool.lastReconcileTime(), lastReconcileBefore, "no-op settlement must roll back reconcile time");
        assertEq(pool.seniorPrincipal(), seniorBefore, "no-op settlement must roll back Senior accounting");
        assertEq(pool.juniorPrincipal(), juniorBefore, "no-op settlement must roll back Junior accounting");
        assertEq(pool.seniorHighWaterMark(), hwmBefore, "no-op settlement must roll back Senior HWM");
        assertEq(pool.accountedAssets(), accountedBefore, "no-op settlement must roll back canonical assets");
        assertEq(pool.unassignedAssets(), unassignedBefore, "no-op settlement must roll back unassigned assets");
    }

    function test_OperatorDepositClaimEmitsControllerAndReceiver() public {
        uint256 assets = 25_000e6;
        uint256 requestId = _requestDeposit(juniorVault, ALICE, assets);
        vm.prank(ALICE);
        assertTrue(_async(juniorVault).setOperator(OPERATOR, true));
        _settleAt(requestId);

        uint256 expectedShares = _async(juniorVault).claimableDepositShares(requestId, ALICE);
        vm.expectEmit(true, true, false, true, address(juniorVault));
        emit Deposit(ALICE, CAROL, assets, expectedShares);
        vm.prank(OPERATOR);
        uint256 claimedShares = _async(juniorVault).claimDeposit(requestId, assets, CAROL, ALICE);

        assertEq(claimedShares, expectedShares);
        assertEq(juniorVault.balanceOf(CAROL), expectedShares);
    }

    function test_DepositCancellationEndsAtMaturity() public {
        uint256 assets = 25_000e6;
        uint256 requestId = _requestDeposit(juniorVault, ALICE, assets);
        uint256 balanceBeforeRefund = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 refunded = _async(juniorVault).cancelPendingDeposit(requestId, ALICE, ALICE);
        assertEq(refunded, assets);
        assertEq(usdc.balanceOf(ALICE), balanceBeforeRefund + assets);
        assertEq(_pendingDeposit(juniorVault, requestId, ALICE), 0);

        requestId = _requestDeposit(juniorVault, ALICE, assets);
        _warpToEpoch(requestId);
        vm.prank(ALICE);
        (bool cancelledAtMaturity,) = address(juniorVault)
            .call(abi.encodeWithSignature("cancelPendingDeposit(uint256,address,address)", requestId, ALICE, ALICE));
        assertFalse(cancelledAtMaturity, "a normally executable matured deposit must not be cancellable");
        assertEq(_pendingDeposit(juniorVault, requestId, ALICE), assets);
    }

    function test_OperatorEscrowsRedeemAndCancellationEndsAtMaturity() public {
        uint256 shares = _fundOne(juniorVault, ALICE, 50_000e6);
        uint256 requestedShares = shares / 2;

        vm.prank(OPERATOR);
        (bool unauthorized,) = address(juniorVault)
            .call(abi.encodeWithSignature("requestRedeem(uint256,address,address)", requestedShares, ALICE, ALICE));
        assertFalse(unauthorized, "an unapproved operator must not control a request");

        vm.prank(ALICE);
        assertTrue(_async(juniorVault).setOperator(OPERATOR, true));
        assertTrue(_async(juniorVault).isOperator(ALICE, OPERATOR));

        uint256 ownerBalanceBefore = juniorVault.balanceOf(ALICE);
        uint256 escrowBefore = juniorVault.balanceOf(address(juniorVault));
        uint256 requestId = _requestRedeem(juniorVault, OPERATOR, requestedShares, ALICE, ALICE);
        assertEq(juniorVault.balanceOf(ALICE), ownerBalanceBefore - requestedShares, "owner shares must enter escrow");
        assertEq(
            juniorVault.balanceOf(address(juniorVault)), escrowBefore + requestedShares, "vault must custody requests"
        );
        assertEq(_pendingRedeem(juniorVault, requestId, ALICE), requestedShares);

        vm.prank(OPERATOR);
        _async(juniorVault).cancelRedeemRequest(requestId, ALICE, ALICE);
        assertEq(juniorVault.balanceOf(ALICE), ownerBalanceBefore, "cancellation must return escrowed shares");
        assertEq(_pendingRedeem(juniorVault, requestId, ALICE), 0);

        vm.prank(OPERATOR);
        (bool duringRestartedCooldown,) = address(juniorVault)
            .call(abi.encodeWithSignature("requestRedeem(uint256,address,address)", requestedShares, ALICE, ALICE));
        assertFalse(duringRestartedCooldown, "cancellation must restart the owner cooldown");

        _finishCooldown(juniorVault, ALICE);
        requestId = _requestRedeem(juniorVault, OPERATOR, requestedShares, ALICE, ALICE);
        _warpToEpoch(requestId);

        vm.prank(OPERATOR);
        (bool cancelledAtMaturity,) = address(juniorVault)
            .call(abi.encodeWithSignature("cancelRedeemRequest(uint256,address,address)", requestId, ALICE, ALICE));
        assertFalse(cancelledAtMaturity, "a matured redeem request must not be cancellable");
        assertEq(_pendingRedeem(juniorVault, requestId, ALICE), requestedShares);
    }

    function test_MaintenanceFee_RequestAndCancellationPathsDoNotCrystallize() public {
        uint256 shares = _fundOne(juniorVault, ALICE, 50_000e6);
        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        _refreshMark();

        uint256 rawSupply = juniorVault.totalSupply();
        uint256 feeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 feeBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        uint256 recipientShares = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        assertGt(feeShares, 0, "fixture must have an accrued fee");

        uint256 assets = 25_000e6;
        uint256 depositId = _requestDeposit(juniorVault, BOB, assets);
        uint256 redeemId = _requestRedeem(juniorVault, ALICE, shares / 2, ALICE, ALICE);
        assertEq(depositId, redeemId, "entry and exit must share the cancellable epoch");
        assertEq(juniorVault.totalSupply(), rawSupply, "requests cannot change issued supply");
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares, "requests cannot checkpoint the fee");

        vm.prank(BOB);
        assertEq(_async(juniorVault).cancelPendingDeposit(depositId, BOB, BOB), assets);
        vm.prank(ALICE);
        assertEq(_async(juniorVault).cancelRedeemRequest(redeemId, ALICE, ALICE), shares / 2);

        assertEq(juniorVault.totalSupply(), rawSupply, "cancellations cannot change issued supply");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares);
        assertEq(juniorVault.pendingDepositEscrowAssets(), 0);
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0);
    }

    function test_MaintenanceFee_RejectedDepositAndRefundDoNotCrystallize() public {
        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        _refreshMark();

        uint256 assets = 25_000e6;
        uint256 requestId = _requestDeposit(juniorVault, ALICE, assets);
        _warpToEpoch(requestId);
        _refreshMark();

        uint256 rawSupply = juniorVault.totalSupply();
        uint256 feeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 feeBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        uint256 recipientShares = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        assertGt(feeShares, 0, "fixture must have an accrued fee");

        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(requestId, 0), assets);

        assertEq(juniorVault.totalSupply(), rawSupply, "zero-share rejection cannot change issued supply");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares);
        assertEq(_async(juniorVault).refundableDepositRequest(requestId, ALICE), assets);

        vm.warp(block.timestamp + 1 hours);
        uint256 feeSharesBeforeRefund = juniorVault.pendingMaintenanceFeeShares();
        vm.prank(ALICE);
        assertEq(_async(juniorVault).cancelPendingDeposit(requestId, ALICE, ALICE), assets);

        assertGt(feeSharesBeforeRefund, feeShares, "rejected assets must not stop time-based accrual");
        assertEq(juniorVault.totalSupply(), rawSupply, "asset refund cannot change issued supply");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeSharesBeforeRefund);
        assertEq(juniorVault.pendingDepositEscrowAssets(), 0);
    }

    function test_MaintenanceFee_ZeroValueRedeemRefundDoesNotCrystallize() public {
        _fundOne(juniorVault, ALICE, 10_000e6);
        vm.prank(ALICE);
        juniorVault.transfer(CAROL, 1);
        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        _refreshMark();

        uint256 requestId = _requestRedeem(juniorVault, CAROL, 1, CAROL, CAROL);
        _warpToEpoch(requestId);
        _refreshMark();
        assertEq(juniorVault.estimateRedeemAssets(1), 0, "one share must exercise the zero-value path");

        uint256 rawSupply = juniorVault.totalSupply();
        uint256 feeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 feeBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        uint256 recipientShares = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        assertGt(feeShares, 0, "fixture must have an accrued fee");

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorProcessedEpochs, 1);
        assertEq(result.juniorFundedShares, 0);
        assertEq(result.juniorFundedAssets, 0);
        assertEq(_refundableRedeem(juniorVault, requestId, CAROL), 1);
        assertEq(juniorVault.totalSupply(), rawSupply, "zero-value refund cannot burn shares");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares);

        vm.warp(block.timestamp + 1 hours);
        uint256 feeSharesBeforeRefund = juniorVault.pendingMaintenanceFeeShares();
        vm.prank(CAROL);
        assertEq(_async(juniorVault).claimRedeemRefund(requestId, CAROL, CAROL), 1);

        assertGt(feeSharesBeforeRefund, feeShares, "refundable shares must remain fee-bearing");
        assertEq(juniorVault.totalSupply(), rawSupply, "share refund cannot change issued supply");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeSharesBeforeRefund);
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0);
    }

    function test_MaintenanceFee_AlreadyFundedClaimsAfterTimeDoNotCrystallize() public {
        uint256 shares = _fundOne(juniorVault, ALICE, 100_000e6);
        _enableJuniorMaintenanceFee();
        _refreshMark();

        uint256 depositAssets = 25_000e6;
        uint256 depositId = _requestDeposit(juniorVault, BOB, depositAssets);
        uint256 redeemShares = shares / 4;
        uint256 redeemId = _requestRedeem(juniorVault, ALICE, redeemShares, ALICE, ALICE);
        assertEq(depositId, redeemId, "entry and exit must share the funded epoch");
        IHousePool.LpEpochSettlementResult memory result = _settleAt(depositId);
        assertEq(result.juniorDepositAssets, depositAssets);
        assertEq(result.juniorFundedShares, redeemShares);

        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        uint256 rawSupply = juniorVault.totalSupply();
        uint256 feeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 feeBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        uint256 recipientShares = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        assertGt(feeShares, 0, "claim delay must accrue a fee");

        assertGt(_claimAllDeposit(juniorVault, depositId, BOB), 0);
        assertEq(juniorVault.totalSupply(), rawSupply, "funded deposit claim cannot mint new shares");
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares);

        assertGt(_claimRedeem(juniorVault, redeemId, ALICE, redeemShares), 0);
        assertEq(juniorVault.totalSupply(), rawSupply, "funded redemption claim cannot burn shares again");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientShares);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), feeBoundary);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), feeShares);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.withdrawalEscrowAssets(), 0);
    }

    function test_SettlementFundsSeniorBeforeJunior() public {
        (uint256 seniorShares, uint256 juniorShares) = _fundPair(ALICE, 300_000e6, BOB, 300_000e6);
        _reserveLiquidityLeaving(50_000e6);

        uint256 seniorRequest = _requestRedeem(seniorVault, ALICE, seniorShares, ALICE, ALICE);
        uint256 juniorRequest = _requestRedeem(juniorVault, BOB, juniorShares, BOB, BOB);
        assertEq(seniorRequest, juniorRequest, "both tranches must share the redeem clock");

        IHousePool.LpEpochSettlementResult memory result = _settleAt(seniorRequest);
        assertGt(result.seniorFundedAssets, 0, "available cash must fund Senior first");
        assertTrue(result.seniorBacklog, "constrained cash must leave Senior demand pending");
        assertEq(result.juniorFundedAssets, 0, "Junior must not bypass a Senior liquidity backlog");
        assertEq(_claimableRedeem(juniorVault, juniorRequest, BOB), 0);
        assertEq(_pendingRedeem(juniorVault, juniorRequest, BOB), juniorShares);
    }

    function test_LaterSeniorRequestPreemptsOlderJuniorBacklog() public {
        (uint256 seniorShares, uint256 juniorShares) = _fundPair(ALICE, 100_000e6, BOB, 500_000e6);
        _reserveLiquidityLeaving(50_000e6);

        uint256 juniorRequest = _requestRedeem(juniorVault, BOB, juniorShares, BOB, BOB);
        IHousePool.LpEpochSettlementResult memory first = _settleAt(juniorRequest);
        assertGt(first.juniorFundedAssets, 0, "older Junior request must receive the initial free cash");
        assertTrue(first.juniorBacklog, "older Junior request must remain partially unfunded");

        uint256 seniorRequest = _requestRedeem(seniorVault, ALICE, seniorShares, ALICE, ALICE);
        assertGt(seniorRequest, juniorRequest, "Senior request must mature after the Junior backlog was created");

        uint256 juniorPendingBefore = _pendingRedeem(juniorVault, juniorRequest, BOB);
        uint256 juniorClaimableBefore = _claimableRedeem(juniorVault, juniorRequest, BOB);
        usdc.mint(address(pool), 25_000e6);
        pool.accountExcess();

        IHousePool.LpEpochSettlementResult memory second = _settleAt(seniorRequest);
        assertGt(second.seniorFundedAssets, 0, "newly available cash must fund the later Senior request first");
        assertTrue(second.seniorBacklog, "constrained cash must leave the later Senior request pending");
        assertEq(second.juniorFundedAssets, 0, "older Junior remainder must not bypass a later Senior backlog");
        assertEq(second.juniorProcessedEpochs, 0);
        assertEq(_pendingRedeem(juniorVault, juniorRequest, BOB), juniorPendingBefore);
        assertEq(_claimableRedeem(juniorVault, juniorRequest, BOB), juniorClaimableBefore);
    }

    function test_DormantSeniorWithoutDemandDoesNotBlockJunior() public {
        uint256 juniorShares = _fundOne(juniorVault, ALICE, 100_000e6);
        _reserveLiquidityLeaving(500e6);
        uint256 freeBefore = pool.getFreeUSDC();
        assertLt(freeBefore, pool.seniorPrincipal(), "setup requires cash below dormant Senior principal");

        uint256 requestId = _requestRedeem(juniorVault, ALICE, juniorShares / 2, ALICE, ALICE);
        IHousePool.LpEpochSettlementResult memory result = _settleAt(requestId);

        assertEq(result.seniorFundedAssets, 0, "there is no matured Senior demand");
        assertGt(result.juniorFundedAssets, 0, "dormant Senior principal must not reserve Junior cash");
        assertLe(result.juniorFundedAssets, freeBefore);
    }

    function test_PauseFundsExitsAndDefersEntries() public {
        uint256 juniorShares = _fundOne(juniorVault, ALICE, 50_000e6);
        uint256 depositId = _requestDeposit(juniorVault, BOB, 25_000e6);

        uint256 redeemId = _requestRedeem(juniorVault, ALICE, juniorShares / 2, ALICE, ALICE);
        assertEq(depositId, redeemId, "requests must mature in the same clearing pass");

        _warpToEpoch(depositId);
        _refreshMark();
        pool.pause();
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(result.juniorFundedAssets, 0, "pause must not strand already requested exits");
        assertEq(result.juniorDepositAssets, 0, "pause must defer new entry accounting");
        assertTrue(result.entriesDeferred);
        assertEq(_pendingDeposit(juniorVault, depositId, BOB), 25_000e6);
        assertEq(_claimableDeposit(juniorVault, depositId, BOB), 0);

        uint256 claimableShares = _claimableRedeem(juniorVault, redeemId, ALICE);
        uint256 balanceBefore = usdc.balanceOf(ALICE);
        uint256 claimedAssets = _claimRedeem(juniorVault, redeemId, ALICE, claimableShares);
        assertGt(claimedAssets, 0, "funded claims must remain callable during pause");
        assertEq(usdc.balanceOf(ALICE), balanceBefore + claimedAssets);

        pool.unpause();
        _refreshMark();
        IHousePool.LpEpochSettlementResult memory resumed = _settleLpEpochForTest();
        assertEq(resumed.juniorDepositAssets, 25_000e6, "unpause must activate the deferred entry");
        assertEq(_claimableDeposit(juniorVault, depositId, BOB), 25_000e6);
    }

    function test_SameCallDepositsAreExcludedFromWithdrawalFunding() public {
        uint256 seniorShares = _fundOne(seniorVault, ALICE, 300_000e6);
        uint256 depositId = _requestDeposit(juniorVault, BOB, 200_000e6);

        uint256 redeemId = _requestRedeem(seniorVault, ALICE, seniorShares, ALICE, ALICE);
        assertEq(depositId, redeemId, "entry and exit must mature together");

        _reserveLiquidityLeaving(25_000e6);
        _warpToEpoch(depositId);
        _refreshMark();
        uint256 preEntryFreeUsdc = pool.getFreeUSDC();
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(result.seniorFundedAssets, 0);
        assertLe(result.seniorFundedAssets, preEntryFreeUsdc, "entry escrow must not expand the frozen exit budget");
        assertLe(preEntryFreeUsdc - result.seniorFundedAssets, 1, "sole Senior head should consume its cash budget");
        assertLt(result.seniorFundedAssets, 200_000e6, "same-call deposit would otherwise materially increase fill");
        assertFalse(result.entriesDeferred, "zero-PnL exposure alone must not defer symmetric-NAV entry");
        assertEq(result.juniorDepositAssets, 200_000e6, "safe entry must activate after withdrawal budgets freeze");
        assertEq(_pendingDeposit(juniorVault, depositId, BOB), 0);
        assertEq(_claimableDeposit(juniorVault, depositId, BOB), 200_000e6);
    }

    function test_LiquidityOnlySeniorBacklogStillAllowsSameCallJuniorEntry() public {
        (uint256 seniorShares,) = _fundPair(ALICE, 300_000e6, CAROL, 100_000e6);
        uint256 depositId = _requestDeposit(juniorVault, BOB, 200_000e6);

        uint256 redeemId = _requestRedeem(seniorVault, ALICE, seniorShares, ALICE, ALICE);
        assertEq(depositId, redeemId, "entry and exit must mature together");

        _reserveLiquidityLeaving(250_000e6);
        _warpToEpoch(depositId);
        _refreshMark();
        assertFalse(
            pool.isSeniorImpairedAfterPendingDepositReconcile(),
            "existing Junior capital must absorb the conservative open-risk reserve"
        );
        uint256 preEntryFreeUsdc = pool.getFreeUSDC();
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertGt(result.seniorFundedAssets, 0);
        assertTrue(result.seniorBacklog, "the frozen cash budget must leave Senior shares queued");
        assertLe(result.seniorFundedAssets, preEntryFreeUsdc, "entry escrow must not expand the exit budget");
        assertLe(preEntryFreeUsdc - result.seniorFundedAssets, 1, "Senior should consume the frozen cash budget");
        assertEq(result.juniorDepositAssets, 200_000e6, "Junior entry should finalize after withdrawal pricing");
        assertFalse(result.entriesDeferred, "liquidity exhaustion alone must not defer entries");
        assertEq(_pendingDeposit(juniorVault, depositId, BOB), 0);
        assertEq(_claimableDeposit(juniorVault, depositId, BOB), 200_000e6);
    }

    function test_JuniorEntryRestoresCapacityBeforeSameCallSeniorEntry() public {
        (, uint256 juniorShares) = _fundPair(ALICE, 100_000e6, CAROL, 300_000e6);
        _setSeniorCapacity(type(uint256).max - 1, 5000);

        (uint256 expectedRedeemId, uint256 requestCutoffTime) = juniorVault.getRequestEpochWindow();
        uint256 juniorRedeemId = _requestRedeem(juniorVault, CAROL, juniorShares / 2, CAROL, CAROL);
        assertEq(juniorRedeemId, expectedRedeemId, "the Junior exit must join the pre-cutoff epoch");

        vm.warp(requestCutoffTime);
        uint256 seniorDepositId = _requestDeposit(seniorVault, BOB, 100_000e6);
        uint256 juniorDepositId = _requestDeposit(juniorVault, BOB, 100_000e6);
        assertEq(seniorDepositId, juniorDepositId, "both entry phases must share one maturity epoch");
        assertEq(juniorDepositId, juniorRedeemId + 1, "post-cutoff entries must follow the older Junior exit");

        IHousePool.LpEpochSettlementResult memory result = _settleAt(juniorDepositId);

        assertGt(result.juniorFundedAssets, 0, "Junior exit must consume enough subordination to test ordering");
        assertEq(result.juniorDepositAssets, 100_000e6, "Junior entry must execute first");
        assertEq(result.seniorDepositAssets, 100_000e6, "restored capacity must then admit the Senior entry");
        assertFalse(result.entriesDeferred);
        assertEq(_claimableDeposit(juniorVault, juniorDepositId, BOB), 100_000e6);
        assertEq(_claimableDeposit(seniorVault, seniorDepositId, BOB), 100_000e6);

        uint256 juniorBeforeEntry = pool.juniorPrincipal() - result.juniorDepositAssets;
        assertGt(
            pool.seniorPrincipal(),
            juniorBeforeEntry,
            "the Senior commitment must be ratio-invalid until Junior entry restores capacity"
        );
        assertLe(pool.seniorPrincipal(), pool.juniorPrincipal(), "the final 50% Senior-share covenant must hold");
    }

    function test_ImpairedSeniorFrozenExitScalesHwmByFundedShares() public {
        (uint256 seniorShares,) = _fundPair(ALICE, 100_000e6, BOB, 100_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.warp(SATURDAY_FROZEN);
        _refreshMark();
        assertTrue(engine.isOracleFrozen(), "setup must charge the nonzero frozen Senior exit fee");
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertLt(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "setup must impair Senior below its HWM");

        uint256 requestId = _requestRedeem(seniorVault, ALICE, seniorShares / 2, ALICE, ALICE);
        _warpToEpoch(requestId);
        _refreshMark();
        uint256 principalBefore = pool.seniorPrincipal();
        uint256 hwmBefore = pool.seniorHighWaterMark();
        uint256 supplyBefore = seniorVault.totalSupply();

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        uint256 expectedHwm = hwmBefore - (hwmBefore * result.seniorFundedShares) / supplyBefore;
        uint256 noFeeAssets = (principalBefore * result.seniorFundedShares) / supplyBefore;

        assertGt(result.seniorFundedAssets, 0);
        assertEq(result.seniorFundedShares, seniorShares / 2);
        assertLt(result.seniorFundedAssets, noFeeAssets, "the frozen exit fee must reduce assets, not HWM ownership");
        assertEq(pool.seniorPrincipal(), principalBefore - result.seniorFundedAssets);
        assertEq(pool.seniorHighWaterMark(), expectedHwm, "HWM must burn by funded-share ownership");
    }

    function test_PartialFundingAccumulatesAcrossClaims() public {
        uint256 juniorShares = _fundOne(juniorVault, ALICE, 300_000e6);
        uint256 positionSize = _reserveLiquidityLeaving(50_000e6);
        uint256 requestId = _requestRedeem(juniorVault, ALICE, juniorShares, ALICE, ALICE);

        IHousePool.LpEpochSettlementResult memory first = _settleAt(requestId);
        assertGt(first.juniorFundedShares, 0);
        assertLt(first.juniorFundedShares, juniorShares);
        assertTrue(first.juniorBacklog);

        uint256 firstClaimableShares = _claimableRedeem(juniorVault, requestId, ALICE);
        uint256 firstPaid = _claimRedeem(juniorVault, requestId, ALICE, firstClaimableShares);
        assertEq(firstPaid, first.juniorFundedAssets);
        assertEq(_claimableRedeem(juniorVault, requestId, ALICE), 0);

        _close(TRADER, CfdTypes.Side.BULL, positionSize, 1e8);
        _warpToEpoch(pool.currentLpEpoch() + 1);
        _refreshMark();
        IHousePool.LpEpochSettlementResult memory second = _settleLpEpochForTest();

        uint256 secondClaimableShares = _claimableRedeem(juniorVault, requestId, ALICE);
        uint256 secondPaid = _claimRedeem(juniorVault, requestId, ALICE, secondClaimableShares);
        assertGt(secondPaid, 0, "restored liquidity must fund the same FIFO head cumulatively");
        assertEq(secondPaid, second.juniorFundedAssets);
        assertEq(firstPaid + secondPaid, first.juniorFundedAssets + second.juniorFundedAssets);
        assertEq(_pendingRedeem(juniorVault, requestId, ALICE), 0);
    }

    function test_ZeroPayoutShareIsNotBurned() public {
        _fundOne(juniorVault, ALICE, 10_000e6);
        vm.prank(ALICE);
        juniorVault.transfer(CAROL, 1);
        assertEq(juniorVault.balanceOf(CAROL), 1, "fresh owner must hold the legal full-exit minimum");
        assertEq(_async(juniorVault).estimateRedeemAssets(1), 0, "one share must exercise the zero-payout path");
        uint256 ownerBalanceBefore = juniorVault.balanceOf(ALICE);
        uint256 supplyBefore = juniorVault.totalSupply();
        uint256 zeroPayoutRequestId = _requestRedeem(juniorVault, CAROL, 1, CAROL, CAROL);

        _warpToEpoch(zeroPayoutRequestId);
        _refreshMark();
        uint256 nextShares = ownerBalanceBefore / 2;
        uint256 nextRequestId = _requestRedeem(juniorVault, ALICE, nextShares, ALICE, ALICE);

        IHousePool.LpEpochSettlementResult memory result = _settleAt(nextRequestId);

        assertEq(result.juniorProcessedEpochs, 2, "zero quote must be dequeued before the next epoch");
        assertEq(result.juniorFundedShares, nextShares, "the next FIFO epoch must settle after a zero quote");
        assertGt(result.juniorFundedAssets, 0);
        assertEq(
            juniorVault.totalSupply(),
            supplyBefore - result.juniorFundedShares,
            "only asset-backed shares may be burned"
        );
        assertEq(juniorVault.balanceOf(address(juniorVault)), 1);
        assertEq(_claimableRedeem(juniorVault, nextRequestId, ALICE), nextShares);
        assertEq(_pendingRedeem(juniorVault, zeroPayoutRequestId, CAROL), 0);
        assertEq(_refundableRedeem(juniorVault, zeroPayoutRequestId, CAROL), 1);

        vm.prank(CAROL);
        uint256 refunded = _async(juniorVault).claimRedeemRefund(zeroPayoutRequestId, CAROL, CAROL);
        assertEq(refunded, 1, "the rejected zero-payout remainder must be refundable");
        assertEq(_refundableRedeem(juniorVault, zeroPayoutRequestId, CAROL), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0);
        assertEq(juniorVault.balanceOf(CAROL), 1);
        assertEq(juniorVault.balanceOf(ALICE), ownerBalanceBefore - nextShares);
    }

    function test_SeniorWorkCapStopsJuniorAndDepositFallthrough() public {
        (uint256 seniorShares, uint256 juniorShares) = _fundPair(ALICE, 340_000e6, BOB, 50_000e6);
        uint256 juniorRequestId = _requestRedeem(juniorVault, BOB, juniorShares / 2, BOB, BOB);
        uint256 depositId = _requestDeposit(juniorVault, CAROL, 25_000e6);

        uint256 seniorChunk = seniorShares / 34;
        uint256 previousRequestId;
        for (uint256 i; i < 17; ++i) {
            uint256 requestId = _requestRedeem(seniorVault, ALICE, seniorChunk, ALICE, ALICE);
            if (i != 0) {
                assertGt(requestId, previousRequestId, "work-cap setup needs distinct FIFO epochs");
            }
            previousRequestId = requestId;
            _warpToEpoch(pool.currentLpEpoch() + 1);
            _refreshMark();
        }

        uint256 juniorPendingBefore = _pendingRedeem(juniorVault, juniorRequestId, BOB);
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.seniorProcessedEpochs, 16);
        assertEq(result.seniorFundedShares, seniorChunk * 16);
        assertTrue(result.seniorBacklog, "the seventeenth Senior epoch must remain queued");
        assertTrue(result.juniorBacklog, "Junior work must be reported but not processed after the Senior cap");
        assertEq(result.juniorProcessedEpochs, 0);
        assertEq(result.juniorFundedAssets, 0);
        assertEq(_pendingRedeem(juniorVault, juniorRequestId, BOB), juniorPendingBefore);
        assertTrue(result.entriesDeferred);
        assertEq(result.juniorDepositAssets, 0);
        assertEq(_pendingDeposit(juniorVault, depositId, CAROL), 25_000e6);
    }

    function test_FrozenWindowRejectsNewDepositRequests() public {
        uint256 assets = 100_000e6;
        vm.warp(SATURDAY_FROZEN);
        _refreshMark();
        assertTrue(engine.isOracleFrozen(), "setup must use a frozen-oracle window");
        assertEq(juniorVault.maxRequestDeposit(ALICE), 0, "frozen entry capacity must be zero");

        usdc.mint(ALICE, assets);
        vm.startPrank(ALICE);
        usdc.approve(address(juniorVault), assets);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        _async(juniorVault).requestDeposit(assets, ALICE, ALICE);
        vm.stopPrank();
    }

    function test_PreFrozenQueuedDepositDefersUntilOracleLive() public {
        uint256 juniorShares = _fundOne(juniorVault, CAROL, 50_000e6);
        uint256 assets = 25_000e6;
        uint256 depositId = _requestDeposit(juniorVault, ALICE, assets);
        uint256 redeemId = _requestRedeem(juniorVault, CAROL, juniorShares / 2, CAROL, CAROL);
        assertEq(depositId, redeemId, "exit and pre-frozen entry must mature together");

        vm.warp(SATURDAY_FROZEN);
        _refreshMark();
        assertTrue(engine.isOracleFrozen(), "setup must settle while oracle-frozen");
        IHousePool.LpEpochSettlementResult memory frozenResult = _settleLpEpochForTest();
        assertGt(frozenResult.juniorFundedAssets, 0, "frozen mode must still fund the matured exit");
        assertEq(frozenResult.juniorDepositAssets, 0, "frozen mode must not activate queued entry capital");
        assertTrue(frozenResult.entriesDeferred);
        assertEq(_pendingDeposit(juniorVault, depositId, ALICE), assets);

        vm.warp(SATURDAY_FROZEN + 48 hours);
        _refreshMark();
        assertFalse(engine.isOracleFrozen(), "entry must resume only after the frozen window closes");
        IHousePool.LpEpochSettlementResult memory liveResult = _settleLpEpochForTest();
        assertEq(liveResult.juniorDepositAssets, assets);
        assertFalse(liveResult.entriesDeferred);
        assertEq(_pendingDeposit(juniorVault, depositId, ALICE), 0);
        assertEq(_claimableDeposit(juniorVault, depositId, ALICE), assets);
    }

    function _fundPair(
        address seniorLp,
        uint256 seniorAssets,
        address juniorLp,
        uint256 juniorAssets
    ) internal returns (uint256 seniorShares, uint256 juniorShares) {
        uint256 seniorId = _requestDeposit(seniorVault, seniorLp, seniorAssets);
        uint256 juniorId = _requestDeposit(juniorVault, juniorLp, juniorAssets);
        assertEq(seniorId, juniorId);
        _settleAt(seniorId);
        seniorShares = _claimAllDeposit(seniorVault, seniorId, seniorLp);
        juniorShares = _claimAllDeposit(juniorVault, juniorId, juniorLp);
        _finishCooldown(seniorVault, seniorLp);
        _finishCooldown(juniorVault, juniorLp);
    }

    function _fundOne(
        TrancheVault vault,
        address lp,
        uint256 assets
    ) internal returns (uint256 shares) {
        uint256 requestId = _requestDeposit(vault, lp, assets);
        _settleAt(requestId);
        shares = _claimAllDeposit(vault, requestId, lp);
        _finishCooldown(vault, lp);
    }

    function _requestDeposit(
        TrancheVault vault,
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(vault), assets);
        requestId = _async(vault).requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _requestRedeem(
        TrancheVault vault,
        address caller,
        uint256 shares,
        address controller,
        address owner
    ) internal returns (uint256 requestId) {
        vm.prank(caller);
        requestId = _async(vault).requestRedeem(shares, controller, owner);
    }

    function _claimAllDeposit(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal returns (uint256 shares) {
        uint256 assets = _claimableDeposit(vault, requestId, controller);
        assertGt(assets, 0, "deposit request must be claimable");
        vm.prank(controller);
        shares = _async(vault).claimDeposit(requestId, assets, controller, controller);
    }

    function _claimRedeem(
        TrancheVault vault,
        uint256 requestId,
        address controller,
        uint256 shares
    ) internal returns (uint256 assets) {
        assertGt(shares, 0, "redeem request must be claimable");
        assertGe(_claimableRedeem(vault, requestId, controller), shares);
        vm.prank(controller);
        assets = _async(vault).claimRedeem(requestId, shares, controller, controller);
    }

    function _pendingDeposit(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal view returns (uint256) {
        return _async(vault).pendingDepositRequest(requestId, controller);
    }

    function _claimableDeposit(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal view returns (uint256) {
        return _async(vault).claimableDepositRequest(requestId, controller);
    }

    function _pendingRedeem(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal view returns (uint256) {
        return _async(vault).pendingRedeemRequest(requestId, controller);
    }

    function _claimableRedeem(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal view returns (uint256) {
        return _async(vault).claimableRedeemRequest(requestId, controller);
    }

    function _refundableRedeem(
        TrancheVault vault,
        uint256 requestId,
        address controller
    ) internal view returns (uint256) {
        return _async(vault).refundableRedeemRequest(requestId, controller);
    }

    function _settleAt(
        uint256 epochId
    ) internal returns (IHousePool.LpEpochSettlementResult memory result) {
        _warpToEpoch(epochId);
        _refreshMark();
        result = _settleLpEpochForTest();
    }

    function _warpToEpoch(
        uint256 epochId
    ) internal {
        uint256 timestamp = pool.lpEpochStart(epochId);
        if (block.timestamp < timestamp) {
            vm.warp(timestamp);
        }
    }

    function _finishCooldown(
        TrancheVault vault,
        address owner
    ) internal {
        uint256 unlockTime = vault.lastDepositTime(owner) + vault.DEPOSIT_COOLDOWN();
        if (block.timestamp < unlockTime) {
            vm.warp(unlockTime);
            _refreshMark();
        }
    }

    function _refreshMark() internal {
        uint256 mark = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(mark == 0 ? 1e8 : mark, uint64(block.timestamp));
    }

    function _enableJuniorMaintenanceFee() internal {
        juniorVault.proposeMaintenanceFeeConfig(MAINTENANCE_FEE_APR_BPS, MAINTENANCE_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
        assertEq(juniorVault.maintenanceFeeAprBps(), MAINTENANCE_FEE_APR_BPS);
        assertEq(juniorVault.maintenanceFeeRecipient(), MAINTENANCE_FEE_RECIPIENT);
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
        _open(TRADER, CfdTypes.Side.BULL, positionSize, margin, 1e8);
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

    function _assertAsyncInterfaces(
        TrancheVault vault
    ) internal view {
        IAsyncTrancheVault asyncVault = _async(vault);
        assertEq(asyncVault.share(), address(vault));
        assertEq(asyncVault.vault(vault.asset()), address(vault), "the underlying must resolve to this vault");
        assertEq(asyncVault.vault(address(0xDEAD)), address(0), "an unrelated asset must not resolve to this vault");
        assertTrue(asyncVault.supportsInterface(0x01ffc9a7), "ERC-165 must be advertised");
        assertTrue(asyncVault.supportsInterface(0xe3bc4e65), "ERC-7540 operator fragment must be advertised");
        assertTrue(asyncVault.supportsInterface(0xce3bbe50), "ERC-7540 deposit fragment must be advertised");
        assertTrue(asyncVault.supportsInterface(0x620ee8e4), "ERC-7540 redeem fragment must be advertised");
        assertTrue(asyncVault.supportsInterface(0x2f0a18c5), "ERC-7575 must be advertised");
        assertTrue(asyncVault.supportsInterface(0xf815c03d), "ERC-7575 share token must be advertised");
        assertTrue(
            asyncVault.supportsInterface(type(IAsyncTrancheVault).interfaceId),
            "custom async vault interface must be advertised"
        );
        assertFalse(asyncVault.supportsInterface(0xffffffff), "unknown interface ids must be rejected");
    }

    function _async(
        TrancheVault vault
    ) internal pure returns (IAsyncTrancheVault) {
        return IAsyncTrancheVault(address(vault));
    }

}
