// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract SettlementMonitorOracleBindingMock {

    address public immutable engine;
    address public immutable housePool;
    address public immutable pyth;

    constructor(
        address engine_,
        address housePool_,
        address pyth_
    ) {
        engine = engine_;
        housePool = housePool_;
        pyth = pyth_;
    }

}

/// @notice Focused integration coverage for the bounded settlement-monitoring surface.
contract SettlementMonitorLensTest is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 internal constant EPOCH_DURATION = 1 hours;
    uint256 internal constant REQUEST_CUTOFF = 5 minutes;
    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    bytes4 internal constant DEPOSIT_QUEUE_HEAD_SELECTOR = bytes4(keccak256("depositQueueHead()"));
    bytes4 internal constant DEPOSIT_QUEUE_TAIL_SELECTOR = bytes4(keccak256("depositQueueTail()"));
    bytes4 internal constant REDEEM_QUEUE_HEAD_SELECTOR = bytes4(keccak256("redeemQueueHead()"));
    bytes4 internal constant REDEEM_QUEUE_TAIL_SELECTOR = bytes4(keccak256("redeemQueueTail()"));
    bytes4 internal constant DEPOSIT_EPOCHS_SELECTOR = bytes4(keccak256("depositEpochs(uint256)"));
    bytes4 internal constant DEPOSIT_QUEUE_STATE_SELECTOR = bytes4(keccak256("depositEpochQueueState(uint256)"));
    bytes4 internal constant REDEEM_EPOCHS_SELECTOR = bytes4(keccak256("redeemEpochs(uint256)"));
    bytes4 internal constant REDEEM_QUEUE_STATE_SELECTOR = bytes4(keccak256("redeemEpochQueueState(uint256)"));
    bytes4 internal constant MATURED_DEPOSIT_HEAD_SELECTOR = bytes4(keccak256("getMaturedDepositHead(uint256)"));
    bytes4 internal constant MATURED_REDEEM_HEAD_SELECTOR = bytes4(keccak256("getMaturedRedeemHead(uint256)"));
    bytes4 internal constant LP_EPOCH_SETTLEMENT_PAUSED_SELECTOR = bytes4(keccak256("lpEpochSettlementPaused()"));
    bytes4 internal constant MAINTENANCE_FEE_APR_BPS_SELECTOR = bytes4(keccak256("maintenanceFeeAprBps()"));
    bytes4 internal constant MAINTENANCE_FEE_RECIPIENT_SELECTOR = bytes4(keccak256("maintenanceFeeRecipient()"));

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant EVE = address(0xE0E);
    address internal constant TRADER = address(0x7A0E2);
    uint256 internal constant SATURDAY_FROZEN = 1_709_985_600;

    SettlementMonitorLens internal monitorLens;

    function setUp() public override {
        super.setUp();
        monitorLens = new SettlementMonitorLens(address(router));
    }

    function test_BaselineBindsCanonicalStackAndReportsHealthyClock() public view {
        assertEq(address(monitorLens.ROUTER()), address(router));
        assertEq(address(monitorLens.ENGINE()), address(engine));
        assertEq(address(monitorLens.HOUSE_POOL()), address(pool));
        assertEq(address(monitorLens.ENGINE_PROTOCOL_LENS()), address(pool.ENGINE_PROTOCOL_LENS()));
        assertEq(address(monitorLens.CLEARINGHOUSE()), address(clearinghouse));
        assertEq(address(monitorLens.TERMINAL_NAV_BOOK()), address(terminalNavBook));
        assertEq(address(monitorLens.SENIOR_VAULT()), address(seniorVault));
        assertEq(address(monitorLens.JUNIOR_VAULT()), address(juniorVault));
        assertEq(address(monitorLens.USDC()), address(usdc));
        assertEq(monitorLens.SIDECAR().MONITOR(), address(monitorLens));

        (uint256 observedEpoch, uint256 nextCutoff) = juniorVault.getRequestEpochWindow();
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertEq(status.clock.observedAt, block.timestamp);
        assertEq(status.clock.observedBlock, block.number);
        assertEq(status.clock.epochDuration, EPOCH_DURATION);
        assertEq(status.clock.requestCutoffDuration, REQUEST_CUTOFF);
        assertEq(status.clock.currentEpoch, pool.currentLpEpoch());
        assertEq(status.clock.settlementCutoffEpoch, pool.currentLpEpoch());
        assertEq(status.clock.observedEpoch, observedEpoch);
        assertEq(status.clock.observedEpochStart, pool.lpEpochStart(observedEpoch));
        assertEq(status.clock.observedEpochRequestCutoff, pool.lpEpochStart(observedEpoch) - REQUEST_CUTOFF);
        assertEq(status.senior.nextRequestEpoch, observedEpoch);
        assertEq(status.junior.nextRequestEpoch, observedEpoch);
        assertEq(status.senior.nextRequestCutoffTime, nextCutoff);
        assertEq(status.junior.nextRequestCutoffTime, nextCutoff);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork));
        assertEq(status.executionPathDependencyMask, 0);
        assertEq(status.dependencyFailureMask, 0);

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();
        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertEq(health.criticalFaultMask, 0);
        assertEq(health.dependencyFailureMask, 0);
        assertEq(health.bookCapPrice, engine.CAP_PRICE());
        assertEq(health.engineCapPrice, engine.CAP_PRICE());
        assertEq(health.poolRawAssetsUsdc, usdc.balanceOf(address(pool)));
        assertEq(health.poolAccountedAssetsUsdc, pool.accountedAssets());
        assertEq(health.poolCustodyDeficitUsdc, 0);
        assertEq(health.seniorImpairmentUsdc, 0);
        assertEq(monitorLens.CONFIG_SCHEMA_VERSION(), 4);
        assertEq(monitorLens.OBSERVATION_DOMAIN(), keccak256("PLETHER_SETTLEMENT_OBSERVATION_V4"));
        assertTrue(monitorLens.OBSERVATION_DOMAIN() != keccak256("PLETHER_SETTLEMENT_OBSERVATION_V3"));
        assertTrue(monitorLens.observableConfigDigest() != bytes32(0));
    }

    function test_ReadableSettlementHoldIsCompleteAndPreservesRouteDiagnostics() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        SettlementMonitorViewTypes.SettlementObservation memory beforeHold =
            monitorLens.getSettlementObservation(observedEpoch);
        bytes32 configBefore = beforeHold.observableConfigDigest;

        pool.pauseLpEpochSettlement();
        SettlementMonitorViewTypes.SettlementObservation memory held =
            monitorLens.getSettlementObservation(observedEpoch);

        assertTrue(held.status.lpEpochSettlementPaused);
        assertTrue(
            _hasOperationalBlocker(
                held.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.LpEpochSettlementPaused
            )
        );
        assertTrue(
            _hasDeferral(
                held.status.seniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.LpEpochSettlementPaused
            )
        );
        assertTrue(
            _hasDeferral(
                held.status.juniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.LpEpochSettlementPaused
            )
        );
        assertEq(held.status.dependencyFailureMask, 0);
        assertEq(uint8(held.status.requiredExecutionPath), uint8(beforeHold.status.requiredExecutionPath));
        assertEq(held.status.executionPathDependencyMask, beforeHold.status.executionPathDependencyMask);
        assertEq(held.observableConfigDigest, configBefore, "an active breaker is runtime state, not configuration");
        assertTrue(held.observationDigest != beforeHold.observationDigest);
        assertTrue(held.observationComplete, "an intentional readable hold must remain complete evidence");
        assertTrue(held.completeObservationDigest != bytes32(0));
    }

    function test_UnreadableSettlementHoldIsPoolDependencyUnknownWithoutErasingRoute() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        SettlementMonitorViewTypes.SettlementStatus memory beforeFailure =
            monitorLens.getSettlementStatus(observedEpoch);

        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(LP_EPOCH_SETTLEMENT_PAUSED_SELECTOR), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementObservation memory unreadable =
            monitorLens.getSettlementObservation(observedEpoch);

        assertFalse(unreadable.status.lpEpochSettlementPaused);
        assertTrue(_hasDependency(unreadable.status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertTrue(
            _hasOperationalBlocker(
                unreadable.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertTrue(
            _hasDeferral(
                unreadable.status.seniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown
            )
        );
        assertTrue(
            _hasDeferral(
                unreadable.status.juniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown
            )
        );
        assertEq(uint8(unreadable.status.requiredExecutionPath), uint8(beforeFailure.requiredExecutionPath));
        assertEq(unreadable.status.executionPathDependencyMask, beforeFailure.executionPathDependencyMask);
        assertFalse(unreadable.observationComplete);
        assertEq(unreadable.completeObservationDigest, bytes32(0));
    }

    function test_ConstructorRejectsRouterSettlementPoolDifferentFromEnginePool() public {
        address wrongPool = address(0xBADF00D);
        SettlementMonitorOracleBindingMock wrongOracle =
            new SettlementMonitorOracleBindingMock(address(engine), wrongPool, address(baseMockPyth));
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        OrderRouter wrongRouter = new OrderRouter(
            address(engine), address(engineLens), wrongPool, address(wrongOracle), address(keeperSidecar)
        );
        assertEq(address(wrongRouter), predictedRouter);
        vm.mockCall(
            address(engine),
            abi.encodeWithSelector(bytes4(keccak256("orderRouter()"))),
            abi.encode(address(wrongRouter))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementMonitorLens.SettlementMonitorLens__BindingMismatch.selector,
                uint8(20),
                address(pool),
                wrongPool
            )
        );
        new SettlementMonitorLens(address(wrongRouter));
    }

    function test_SettlementAccountingMatchesCanonicalSources() public view {
        SettlementMonitorViewTypes.SettlementAccounting memory accounting =
        monitorLens.getSettlementObservation(pool.currentLpEpoch()).accounting;
        IHousePool.PoolLiquidityView memory liquidity = pool.getPoolLiquidityView();
        (uint256 pendingSenior, uint256 pendingJunior, uint256 pendingSeniorWithdraw, uint256 pendingJuniorWithdraw) =
            pool.getPendingTrancheState();
        ICfdEngineTypes.TerminalNavSnapshot memory terminal = engine.terminalNavSnapshot();

        assertEq(accounting.poolRawAssetsUsdc, pool.rawAssets());
        assertEq(accounting.poolAccountedAssetsUsdc, pool.accountedAssets());
        assertEq(accounting.poolTotalAssetsUsdc, pool.totalAssets());
        assertEq(accounting.poolExcessAssetsUsdc, pool.excessAssets());
        assertEq(accounting.withdrawalReservedUsdc, liquidity.withdrawalReservedUsdc);
        assertEq(accounting.freeUsdc, liquidity.freeUsdc);
        assertEq(accounting.storedSeniorPrincipalUsdc, pool.seniorPrincipal());
        assertEq(accounting.storedJuniorPrincipalUsdc, pool.juniorPrincipal());
        assertEq(accounting.storedSeniorHighWaterMarkUsdc, pool.seniorHighWaterMark());
        assertEq(accounting.cachedPreviewSeniorPrincipalUsdc, pendingSenior);
        assertEq(accounting.cachedPreviewJuniorPrincipalUsdc, pendingJunior);
        assertEq(accounting.cachedPreviewMaxSeniorWithdrawUsdc, pendingSeniorWithdraw);
        assertEq(accounting.cachedPreviewMaxJuniorWithdrawUsdc, pendingJuniorWithdraw);
        assertEq(accounting.pendingRecapitalizationUsdc, pool.pendingRecapitalizationUsdc());
        assertEq(accounting.pendingTradingRevenueUsdc, pool.pendingTradingRevenueUsdc());
        assertEq(accounting.unassignedAssetsUsdc, pool.unassignedAssets());
        assertEq(accounting.reservedSeniorDepositAssetsUsdc, pool.reservedSeniorDepositAssetsUsdc());
        assertEq(accounting.storedTerminalDeficitUsdc, pool.terminalDeficitUsdc());
        assertEq(accounting.cachedPreviewTerminalDeficitUsdc, liquidity.currentTerminalDeficitUsdc);
        assertEq(accounting.lastReconcileTime, pool.lastReconcileTime());
        assertEq(accounting.lastSeniorCouponCheckpointTime, pool.lastSeniorCouponCheckpointTime());
        assertEq(accounting.terminalMarkPrice, terminal.markPrice);
        assertEq(accounting.terminalMarkTime, terminal.markTime);
        assertEq(accounting.terminalLpPriceDeltaUsdc, terminal.terminalLpPriceDeltaUsdc);
        assertEq(accounting.totalTraderClaimsUsdc, terminal.totalTraderClaimsUsdc);
        assertEq(accounting.maxDirectionalLiabilityUsdc, terminal.maxDirectionalLiabilityUsdc);
        assertEq(accounting.terminalBookVersion, terminal.bookVersion);
        assertEq(accounting.terminalHasOpenPositions, terminal.hasOpenPositions);
        assertEq(accounting.terminalDegradedMode, terminal.degradedMode);
        assertTrue(accounting.cachedPreviewAvailable);
        assertTrue(accounting.terminalSnapshotAvailable);
        assertEq(accounting.dependencyFailureMask, 0);
    }

    function test_SettlementAccountingAttributesSourceReadFailures() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(bytes4(keccak256("rawAssets()"))), bytes("failed"));
        SettlementMonitorViewTypes.SettlementAccounting memory accounting =
        monitorLens.getSettlementObservation(observedEpoch).accounting;
        assertTrue(_hasDependency(accounting.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));

        vm.clearMockedCalls();
        vm.mockCall(address(pool), abi.encodeWithSelector(IHousePool.getPendingTrancheState.selector), hex"01");
        accounting = monitorLens.getSettlementObservation(observedEpoch).accounting;
        assertTrue(
            _hasDependency(
                accounting.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.PoolAccountingPreview
            )
        );

        vm.clearMockedCalls();
        vm.mockCall(address(engine), abi.encodeWithSelector(bytes4(keccak256("terminalNavSnapshot()"))), hex"01");
        accounting = monitorLens.getSettlementObservation(observedEpoch).accounting;
        assertTrue(_hasDependency(accounting.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
    }

    function test_SidecarRejectsDirectCaller() public {
        (bool ok, bytes memory result) = address(monitorLens.SIDECAR())
            .staticcall(abi.encodeWithSelector(bytes4(keccak256("getSettlementAccounting()"))));
        assertFalse(ok);
        assertEq(bytes4(result), bytes4(keccak256("SettlementMonitorLensSidecar__OnlyMonitor()")));
    }

    function test_SettlementMonitorLensRuntimeFitsEip170() public view {
        assertGt(address(monitorLens).code.length, 0);
        assertLe(address(monitorLens).code.length, EIP170_RUNTIME_CODE_LIMIT);
        assertGt(address(monitorLens.SIDECAR()).code.length, 0);
        assertLe(address(monitorLens.SIDECAR()).code.length, EIP170_RUNTIME_CODE_LIMIT);
    }

    function test_SettlementMonitorLensCreationInputFitsEip3860() public pure {
        uint256 creationInputLength = type(SettlementMonitorLens).creationCode.length + 32;
        assertLe(
            creationInputLength,
            EIP3860_INITCODE_LIMIT,
            "SettlementMonitorLens creation code plus constructor argument must remain deployable"
        );
    }

    function test_StatusTracksExplicitEpochAcrossCutoffRollAndCancellation() public {
        _fundSenior(ALICE, 50_000e6);
        _fundJunior(BOB, 50_000e6);

        uint256 boundary = ((block.timestamp + 2 hours) / EPOCH_DURATION) * EPOCH_DURATION;
        vm.warp(boundary - REQUEST_CUTOFF - 1);
        uint256 observedEpoch = boundary / EPOCH_DURATION;

        uint256 seniorDepositAssets = 11_000e6;
        uint256 juniorDepositAssets = 13_000e6;
        uint256 seniorRedeemShares = seniorVault.balanceOf(ALICE) / 5;
        uint256 juniorRedeemShares = juniorVault.balanceOf(BOB) / 5;

        assertEq(_requestDeposit(seniorVault, CAROL, seniorDepositAssets), observedEpoch);
        assertEq(_requestDeposit(juniorVault, DAVE, juniorDepositAssets), observedEpoch);
        assertEq(_requestRedeem(seniorVault, ALICE, seniorRedeemShares), observedEpoch);
        assertEq(_requestRedeem(juniorVault, BOB, juniorRedeemShares), observedEpoch);

        SettlementMonitorViewTypes.SettlementStatus memory beforeCutoff = monitorLens.getSettlementStatus(observedEpoch);
        assertFalse(beforeCutoff.clock.additionsClosed);
        assertFalse(beforeCutoff.clock.matured);
        assertEq(beforeCutoff.clock.secondsUntilAdditionsClose, 1);
        assertEq(beforeCutoff.clock.secondsUntilMaturity, REQUEST_CUTOFF + 1);
        assertEq(beforeCutoff.senior.observedDepositAssets, seniorDepositAssets);
        assertEq(beforeCutoff.senior.observedDepositPendingAssets, seniorDepositAssets);
        assertEq(beforeCutoff.junior.observedDepositAssets, juniorDepositAssets);
        assertEq(beforeCutoff.junior.observedDepositPendingAssets, juniorDepositAssets);
        assertEq(beforeCutoff.senior.observedRedeemShares, seniorRedeemShares);
        assertEq(beforeCutoff.senior.observedRedeemFundableShares, seniorRedeemShares);
        assertEq(beforeCutoff.junior.observedRedeemShares, juniorRedeemShares);
        assertEq(beforeCutoff.junior.observedRedeemFundableShares, juniorRedeemShares);

        vm.warp(boundary - REQUEST_CUTOFF);
        SettlementMonitorViewTypes.SettlementStatus memory atCutoff = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(atCutoff.clock.additionsClosed);
        assertFalse(atCutoff.clock.matured);
        assertEq(atCutoff.clock.secondsUntilAdditionsClose, 0);
        assertEq(atCutoff.clock.secondsUntilMaturity, REQUEST_CUTOFF);
        assertEq(atCutoff.senior.nextRequestEpoch, observedEpoch + 1);
        assertEq(atCutoff.junior.nextRequestEpoch, observedEpoch + 1);
        assertTrue(_hasWarning(atCutoff.warningMask, SettlementMonitorViewTypes.Warning.ObservationCanStillShrink));

        uint256 rolledAssets = 17_000e6;
        assertEq(_requestDeposit(juniorVault, EVE, rolledAssets), observedEpoch + 1);
        vm.prank(DAVE);
        juniorVault.cancelPendingDeposit(observedEpoch, DAVE, DAVE);
        vm.prank(BOB);
        juniorVault.cancelRedeemRequest(observedEpoch, BOB, BOB);

        SettlementMonitorViewTypes.SettlementStatus memory afterCancellation =
            monitorLens.getSettlementStatus(observedEpoch);
        assertEq(
            afterCancellation.clock.observedEpoch, observedEpoch, "explicit observation must not follow request roll"
        );
        assertEq(afterCancellation.junior.observedDepositAssets, 0);
        assertEq(afterCancellation.junior.observedDepositPendingAssets, 0);
        assertEq(afterCancellation.junior.observedRedeemShares, 0);
        assertEq(afterCancellation.junior.observedRedeemFundableShares, 0);
        assertEq(afterCancellation.senior.observedDepositAssets, seniorDepositAssets);
        assertEq(afterCancellation.senior.observedRedeemShares, seniorRedeemShares);

        SettlementMonitorViewTypes.SettlementStatus memory rolled = monitorLens.getSettlementStatus(observedEpoch + 1);
        assertEq(rolled.junior.observedDepositAssets, rolledAssets);
        assertEq(rolled.junior.observedDepositPendingAssets, rolledAssets);
    }

    function testFuzz_ClockAndVaultWindowsMatchEverySecondOfTheHour(
        uint16 rawOffset
    ) public {
        uint256 offset = bound(uint256(rawOffset), 0, EPOCH_DURATION - 1);
        uint256 currentEpochStart = ((block.timestamp + 2 hours) / EPOCH_DURATION) * EPOCH_DURATION;
        vm.warp(currentEpochStart + offset);

        uint256 currentEpoch = pool.currentLpEpoch();
        uint256 imminentEpoch = currentEpoch + 1;
        uint256 imminentCutoff = pool.lpEpochStart(imminentEpoch) - REQUEST_CUTOFF;
        uint256 expectedNextEpoch = block.timestamp < imminentCutoff ? imminentEpoch : imminentEpoch + 1;
        uint256 expectedNextCutoff = pool.lpEpochStart(expectedNextEpoch) - REQUEST_CUTOFF;

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(imminentEpoch);
        assertEq(status.clock.currentEpoch, currentEpoch);
        assertEq(status.clock.observedEpoch, imminentEpoch);
        assertEq(status.clock.observedEpochStart, pool.lpEpochStart(imminentEpoch));
        assertEq(status.clock.observedEpochRequestCutoff, imminentCutoff);
        assertEq(status.clock.additionsClosed, block.timestamp >= imminentCutoff);
        assertEq(
            status.clock.secondsUntilAdditionsClose,
            block.timestamp < imminentCutoff ? imminentCutoff - block.timestamp : 0
        );
        assertEq(status.clock.secondsUntilMaturity, pool.lpEpochStart(imminentEpoch) - block.timestamp);
        assertEq(status.senior.nextRequestEpoch, expectedNextEpoch);
        assertEq(status.junior.nextRequestEpoch, expectedNextEpoch);
        assertEq(status.senior.nextRequestCutoffTime, expectedNextCutoff);
        assertEq(status.junior.nextRequestCutoffTime, expectedNextCutoff);
    }

    function test_FutureObservedEpochIsNotMisreportedAsOpenForAdditions() public view {
        (uint256 canonicalTarget,) = juniorVault.getRequestEpochWindow();
        uint256 futureObservedEpoch = canonicalTarget + 1;

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(futureObservedEpoch);

        assertFalse(status.clock.additionsClosed);
        assertFalse(status.clock.isCurrentRequestTarget);
        assertFalse(status.clock.additionsOpenByClock);
        assertFalse(_hasWarning(status.warningMask, SettlementMonitorViewTypes.Warning.AdditionsStillOpen));
    }

    function test_ObservedEpochDomainUsesExplicitNonpanicBehavior() public view {
        SettlementMonitorViewTypes.SettlementStatus memory epochZero = monitorLens.getSettlementStatus(0);
        assertEq(epochZero.clock.observedEpoch, 0);
        assertTrue(epochZero.clock.matured);
        assertEq(epochZero.senior.faultMask, 0);
        assertEq(epochZero.junior.faultMask, 0);
    }

    function test_HugeObservedEpochRevertsWithTypedDomainError() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementMonitorLens.SettlementMonitorLens__InvalidObservedEpoch.selector, type(uint256).max
            )
        );
        monitorLens.getSettlementStatus(type(uint256).max);

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();
        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertEq(health.criticalFaultMask, 0);
    }

    function test_MaturedNoPositionWorkUsesCachedMarkPath() public {
        uint256 assets = 25_000e6;
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, assets);
        vm.warp(pool.lpEpochStart(observedEpoch));

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(status.clock.additionsClosed);
        assertTrue(status.clock.matured);
        assertTrue(status.hasMaturedWork);
        assertFalse(status.hasOpenPositions);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.junior.maturedDepositHeadEpoch, observedEpoch);
        assertEq(status.junior.maturedDepositHeadAssets, assets);
        assertFalse(_hasWarning(status.warningMask, SettlementMonitorViewTypes.Warning.ObservationCanStillShrink));
    }

    function test_ObservedTailBehindPhaseCapReportsFifoHeadWithoutClaimingTargetReachability() public {
        uint256 firstEpochStart = ((block.timestamp + 2 hours) / EPOCH_DURATION) * EPOCH_DURATION;
        uint256 firstEpoch;
        uint256 observedEpoch;
        uint256 assetsPerEpoch = 1000e6;

        for (uint256 i; i < 17; ++i) {
            vm.warp(firstEpochStart + i * EPOCH_DURATION - REQUEST_CUTOFF - 1);
            uint256 requestEpoch = _requestDeposit(juniorVault, ALICE, assetsPerEpoch);
            if (i == 0) {
                firstEpoch = requestEpoch;
            }
            assertEq(requestEpoch, firstEpoch + i);
            observedEpoch = requestEpoch;
        }

        vm.warp(pool.lpEpochStart(observedEpoch));
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(status.hasMaturedWork);
        assertEq(status.junior.depositQueueHead, firstEpoch);
        assertEq(status.junior.depositQueueTail, observedEpoch);
        assertEq(status.junior.maturedDepositHeadEpoch, firstEpoch);
        assertTrue(status.junior.maturedDepositHeadEpoch != observedEpoch);
        assertEq(status.junior.observedDepositAssets, assetsPerEpoch);
        assertTrue(status.junior.observedDepositQueued);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark),
            "route describes the next FIFO attempt, not reachability of the observed tail"
        );

        IHousePool.LpEpochSettlementResult memory firstPass = _settleLpEpochForTest();
        assertEq(firstPass.juniorDepositAssets, 16 * assetsPerEpoch);
        assertTrue(firstPass.entriesDeferred);

        SettlementMonitorViewTypes.SettlementStatus memory remaining = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(remaining.hasMaturedWork);
        assertEq(remaining.junior.maturedDepositHeadEpoch, observedEpoch);
        assertEq(uint8(remaining.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));

        IHousePool.LpEpochSettlementResult memory secondPass = _settleLpEpochForTest();
        assertEq(secondPass.juniorDepositAssets, assetsPerEpoch);
        SettlementMonitorViewTypes.SettlementStatus memory cleared = monitorLens.getSettlementStatus(observedEpoch);
        assertFalse(cleared.hasMaturedWork);
        assertEq(uint8(cleared.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork));
    }

    function test_LivePositionSelectsAtomicPathAndOracleFloor() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        _setCurrentBasket(110_000_000, 50_000, block.timestamp);

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(status.hasMaturedWork, "matured work");
        assertTrue(status.hasOpenPositions, "open positions");
        assertFalse(status.oracleFrozen, "live oracle");
        assertEq(
            uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertEq(status.clock.minimumAtomicPublishTime, pool.lpEpochStart(pool.currentLpEpoch()));

        SettlementMonitorViewTypes.OracleStatus memory oracleStatus = monitorLens.getPoolReconcileOracleStatus();
        assertTrue(oracleStatus.readSucceeded, "oracle read");
        assertTrue(oracleStatus.policyValid, "oracle policy");
        assertTrue(oracleStatus.publishTimeMeetsEpochFloor, "epoch floor");
        assertEq(oracleStatus.oracle, address(router.pletherOracle()));
        assertEq(oracleStatus.pyth, address(baseMockPyth));
        assertEq(oracleStatus.price, 110_000_000);
        assertEq(oracleStatus.markPrice, 110_000_000);
        assertEq(oracleStatus.confidence, 50_000);
        assertEq(oracleStatus.publishTime, block.timestamp);
        assertEq(oracleStatus.failureSelector, bytes4(0));
        assertEq(oracleStatus.dependencyFailureMask, 0);

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);
        assertTrue(observation.observationComplete, "complete observation");
        assertTrue(observation.observationDigest != bytes32(0), "raw digest");
        assertTrue(observation.completeObservationDigest != bytes32(0), "complete digest");
    }

    function test_LiveOracleBeforeEpochBoundaryBlocksAtomicReadinessUntilExactBoundary() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        uint256 boundary = pool.lpEpochStart(observedEpoch);
        vm.warp(boundary);
        _setCurrentBasket(110_000_000, 50_000, boundary - 1);

        SettlementMonitorViewTypes.SettlementObservation memory early =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(
            uint8(early.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertEq(early.status.clock.minimumAtomicPublishTime, boundary);
        assertTrue(early.oracle.readSucceeded);
        assertTrue(early.oracle.policyValid);
        assertFalse(early.oracle.publishTimeMeetsEpochFloor);
        assertTrue(
            _hasOperationalBlocker(
                early.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
            )
        );
        assertFalse(early.observationComplete);
        assertEq(early.completeObservationDigest, bytes32(0));

        _setCurrentBasket(110_000_000, 50_000, boundary);
        SettlementMonitorViewTypes.SettlementObservation memory ready =
            monitorLens.getSettlementObservation(observedEpoch);
        assertTrue(ready.oracle.publishTimeMeetsEpochFloor);
        assertFalse(
            _hasOperationalBlocker(
                ready.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
            )
        );
        assertTrue(ready.observationComplete);
    }

    function test_FrozenPositionSelectsCachedOrAtomicRecoveryFromMarkAge() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(SATURDAY_FROZEN);
        assertGe(pool.currentLpEpoch(), observedEpoch);
        assertTrue(engine.isOracleFrozen());

        SettlementMonitorViewTypes.SettlementStatus memory stale = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(stale.hasMaturedWork);
        assertTrue(stale.hasOpenPositions);
        assertTrue(stale.oracleFrozen);
        assertFalse(stale.markFresh);
        assertEq(
            uint8(stale.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertTrue(_hasWarning(stale.warningMask, SettlementMonitorViewTypes.Warning.OracleFrozen));

        vm.prank(address(router));
        engine.updateMarkPrice(100_000_000, uint64(block.timestamp));

        SettlementMonitorViewTypes.SettlementStatus memory fresh = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(fresh.markFresh);
        assertEq(uint8(fresh.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
    }

    function test_FrozenStaleRecoveryDoesNotRequireCurrentRoundHourPublishFloor() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(SATURDAY_FROZEN);
        uint256 currentEpochStart = pool.lpEpochStart(pool.currentLpEpoch());
        uint256 preBoundaryPublishTime = currentEpochStart - 1;
        _setCurrentBasket(100_000_000, 50_000, preBoundaryPublishTime);

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(status.oracleFrozen);
        assertFalse(status.markFresh);
        assertEq(
            uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertEq(status.clock.minimumAtomicPublishTime, 0, "frozen recovery uses PoolReconcile freshness only");
        assertFalse(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
            )
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);
        assertTrue(observation.oracle.policyValid);
        assertEq(observation.oracle.publishTime, preBoundaryPublishTime);
        assertTrue(observation.oracle.publishTimeMeetsEpochFloor);
        assertFalse(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
            )
        );
        assertTrue(observation.observationComplete);
    }

    function test_RequiredInvalidOracleIsFailSoftAndNotActionable() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        _setCurrentBasket(100_000_000, 200_000, block.timestamp);

        SettlementMonitorViewTypes.OracleStatus memory oracleStatus = monitorLens.getPoolReconcileOracleStatus();
        assertFalse(oracleStatus.readSucceeded);
        assertFalse(oracleStatus.policyValid);
        assertEq(oracleStatus.failureSelector, IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        assertTrue(oracleStatus.failureHash != bytes32(0));
        assertEq(oracleStatus.dependencyFailureMask, 0, "recognized oracle rejection is not an unreadable dependency");

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertEq(
            uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredOracleInvalid
            )
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(observation.completeObservationDigest, bytes32(0));
        assertTrue(observation.observationDigest != bytes32(0));
        assertEq(
            uint8(observation.health.state),
            uint8(SettlementMonitorViewTypes.HealthState.Healthy),
            "bad current feed data is operational, not structural health corruption"
        );
    }

    function test_UnreadableRequiredOracleSetsOnlyUnknownDependencyBlocker() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            hex"01"
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertEq(
            uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertFalse(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredOracleInvalid
            )
        );
        assertFalse(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
            )
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_FailedEssentialQueueReadSelectsUnknownPath() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        bytes4 maturedDepositHeadSelector = bytes4(keccak256("getMaturedDepositHead(uint256)"));
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(maturedDepositHeadSelector, observedEpoch), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertTrue(
            _hasDependency(status.executionPathDependencyMask, SettlementMonitorViewTypes.Dependency.JuniorVault)
        );
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
    }

    function test_OptionalDiagnosticReadFailureDoesNotEraseKnownCachedRoute() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("unassignedAssets()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(status.hasMaturedWork);
        assertFalse(status.hasOpenPositions);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertEq(status.executionPathDependencyMask, 0);
        assertFalse(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
    }

    function test_FailedEndpointReadOnEmptyQueueExposesZeroWithoutFalseQueueFault() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_HEAD_SELECTOR), abi.encode(uint256(777))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertEq(status.junior.depositQueueHead, 0, "failed scalar must not expose revert data");
        assertTrue(
            _hasDependency(status.junior.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault)
        );
        assertFalse(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "an unreadable endpoint is unknown, not contradictory"
        );
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork),
            "the canonical matured getter independently proves no work"
        );
        assertEq(status.executionPathDependencyMask, 0);
    }

    function test_FailedEndpointReadOnNonemptyQueueExposesZeroWithoutFalseQueueFault() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        assertEq(juniorVault.depositQueueHead(), observedEpoch);
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_HEAD_SELECTOR), abi.encode(uint256(888))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertEq(status.junior.depositQueueHead, 0, "failed scalar must not expose revert data");
        assertEq(status.junior.depositQueueTail, observedEpoch, "independently readable endpoint remains visible");
        assertTrue(
            _hasDependency(status.junior.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault)
        );
        assertFalse(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "one unreadable endpoint cannot prove corruption"
        );
        assertTrue(status.hasMaturedWork, "the canonical matured getter independently proves work");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.executionPathDependencyMask, 0);
    }

    function test_PositiveMatureEvidenceKeepsRouteWhenPayloadGetterFails() public {
        uint256 headEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        vm.warp(pool.lpEpochStart(headEpoch));
        vm.mockCallRevert(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, headEpoch),
            bytes("unreadable payload")
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);

        assertTrue(status.hasMaturedWork);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.executionPathDependencyMask, 0, "auxiliary integrity evidence cannot erase canonical work");
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertFalse(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "unreadable payload is unknown, not contradictory"
        );
    }

    function test_NoWorkMalformedOracleAbiMakesObservationIncomplete() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            hex"01"
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork)
        );
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_CachedPathLegacyOracleAbiMakesObservationIncomplete() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        vm.warp(pool.lpEpochStart(observedEpoch));
        IPletherOracle.PriceSnapshot memory legacySnapshot = IPletherOracle.PriceSnapshot({
            price: 100_000_000,
            markPrice: 100_000_000,
            publishTime: uint64(block.timestamp),
            updateFee: 0,
            maxStaleness: pool.markStalenessLimit(),
            closeOnly: false,
            oracleFrozen: false,
            isFadWindow: false
        });
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encode(legacySnapshot)
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(
            uint8(observation.status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark)
        );
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_AtomicMalformedOracleKeepsKnownRouteAndSetsBroadDependency() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            hex"01"
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh)
        );
        assertTrue(
            _hasDependency(observation.status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle),
            "required oracle failure belongs in the broad status dependency mask"
        );
        assertEq(observation.status.executionPathDependencyMask, 0, "oracle failure does not erase a known route");
        assertTrue(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_ExactLengthImpossibleOracleSnapshotsAreDependenciesAndIncomplete() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        _setCurrentBasket(100_000_000, 50_000, block.timestamp);

        IPletherOracle.PriceSnapshot memory impossible = _validPoolReconcileSnapshot();
        impossible.price = 0;
        impossible.markPrice = 0;
        _assertMalformedOracleSnapshot(observedEpoch, impossible);

        impossible = _validPoolReconcileSnapshot();
        impossible.markPrice += 1;
        _assertMalformedOracleSnapshot(observedEpoch, impossible);

        impossible = _validPoolReconcileSnapshot();
        impossible.price = engine.CAP_PRICE() + 1;
        impossible.markPrice = engine.CAP_PRICE() + 1;
        _assertMalformedOracleSnapshot(observedEpoch, impossible);

        impossible = _validPoolReconcileSnapshot();
        impossible.publishTime = uint64(block.timestamp + 1);
        _assertMalformedOracleSnapshot(observedEpoch, impossible);

        impossible = _validPoolReconcileSnapshot();
        impossible.publishTime = uint64(block.timestamp - impossible.maxStaleness - 1);
        _assertMalformedOracleSnapshot(observedEpoch, impossible);

        impossible = _validPoolReconcileSnapshot();
        impossible.maxStaleness += 1;
        impossible.closeOnly = true;
        impossible.oracleFrozen = !engine.isOracleFrozen();
        impossible.isFadWindow = !engine.isFadWindow();
        _assertMalformedOracleSnapshot(observedEpoch, impossible);
    }

    function test_TruncatedKnownOracleErrorIsMalformedDependency() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCallRevert(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encodePacked(IPletherOracle.PletherOracle__StalePrice.selector)
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(observation.oracle.failureSelector, IPletherOracle.PletherOracle__StalePrice.selector);
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle),
            "a selector without its canonical arguments is unreadable dependency output"
        );
        assertTrue(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertFalse(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredOracleInvalid
            )
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_ExactCanonicalOraclePolicyErrorRemainsOperationalInvalid() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        bytes memory canonicalError = abi.encodeWithSelector(
            IPletherOracle.PletherOracle__StalePrice.selector,
            IPletherOracle.PriceMode.PoolReconcile,
            BASE_PYTH_FEED_A,
            block.timestamp - 1,
            uint256(0),
            block.timestamp
        );
        vm.mockCallRevert(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            canonicalError
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(observation.oracle.failureSelector, IPletherOracle.PletherOracle__StalePrice.selector);
        assertEq(observation.oracle.dependencyFailureMask, 0, "canonical policy rejection is readable");
        assertTrue(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredOracleInvalid
            )
        );
        assertFalse(
            _hasOperationalBlocker(
                observation.status.operationalBlockerMask,
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_WrongModeOraclePolicyErrorIsMalformedDependency() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        bytes memory wrongModeError = abi.encodeWithSelector(
            IPletherOracle.PletherOracle__StalePrice.selector,
            IPletherOracle.PriceMode.OrderExecution,
            BASE_PYTH_FEED_A,
            block.timestamp - 1,
            uint256(0),
            block.timestamp
        );
        vm.mockCallRevert(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            wrongModeError
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(observation.oracle.failureSelector, IPletherOracle.PletherOracle__StalePrice.selector);
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle),
            "an exact-size error for another price mode is not authentic PoolReconcile evidence"
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function test_NoncanonicalNarrowOracleErrorsRemainUnknownDependencies() public {
        bytes memory malformedOutOfOrder = abi.encodePacked(
            IPletherOracle.PletherOracle__PriceOutOfOrder.selector,
            bytes32(uint256(type(uint64).max) + 1),
            bytes32(uint256(1))
        );
        _assertMalformedNarrowOracleError(malformedOutOfOrder);

        bytes memory malformedInvalidPrice = abi.encodePacked(
            IPletherOracle.PletherOracle__InvalidPrice.selector,
            bytes32(uint256(BASE_PYTH_FEED_A)),
            bytes32(uint256(type(uint64).max))
        );
        _assertMalformedNarrowOracleError(malformedInvalidPrice);
    }

    function test_OraclePolicyEngineReadFailureIsAttributedToEngine() public {
        _setCurrentBasket(100_000_000, 50_000, block.timestamp);
        IPletherOracle.PriceSnapshot memory snapshot = _validPoolReconcileSnapshot();
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encode(snapshot, uint256(50_000))
        );
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("CAP_PRICE()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.OracleStatus memory oracleStatus = monitorLens.getPoolReconcileOracleStatus();

        assertTrue(_hasDependency(oracleStatus.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
        assertFalse(_hasDependency(oracleStatus.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle));
        assertFalse(oracleStatus.readSucceeded);
    }

    function test_OraclePolicyPoolReadFailureIsAttributedToPool() public {
        _setCurrentBasket(100_000_000, 50_000, block.timestamp);
        IPletherOracle.PriceSnapshot memory snapshot = _validPoolReconcileSnapshot();
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encode(snapshot, uint256(50_000))
        );
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("markStalenessLimit()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.OracleStatus memory oracleStatus = monitorLens.getPoolReconcileOracleStatus();

        assertTrue(_hasDependency(oracleStatus.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertFalse(_hasDependency(oracleStatus.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle));
        assertFalse(oracleStatus.readSucceeded);
    }

    function test_HealthClassifiesCustodyDeficitsAndBenignSurplus() public {
        uint256 branch = vm.snapshotState();

        usdc.mint(address(pool), 3e6);
        SettlementMonitorViewTypes.SettlementHealth memory surplus = monitorLens.getSettlementHealth();
        assertEq(uint8(surplus.state), uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertEq(surplus.criticalFaultMask, 0);
        assertEq(surplus.poolCustodyDeficitUsdc, 0);
        assertEq(surplus.poolCustodySurplusUsdc, 3e6);

        vm.revertToState(branch);
        usdc.burn(address(pool), 1e6);
        SettlementMonitorViewTypes.SettlementHealth memory poolDeficit = monitorLens.getSettlementHealth();
        assertEq(uint8(poolDeficit.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                poolDeficit.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.PoolCustodyDeficit
            )
        );
        assertEq(poolDeficit.poolCustodyDeficitUsdc, 1e6);

        vm.revertToState(branch);
        uint256 assets = 10e6;
        _requestDeposit(juniorVault, ALICE, assets);
        usdc.burn(address(juniorVault), 1);
        SettlementMonitorViewTypes.SettlementHealth memory vaultDeficit = monitorLens.getSettlementHealth();
        assertEq(uint8(vaultDeficit.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                vaultDeficit.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorAssetEscrowDeficit
            )
        );
        assertEq(vaultDeficit.juniorRequiredAssetEscrowUsdc, assets);
        assertEq(vaultDeficit.juniorActualAssetEscrowUsdc, assets - 1);
    }

    function test_ObservedDepositFieldsTrackFinalizedClaimsAndRejection() public {
        uint256 assets = 20_000e6;
        uint256 shares = assets * 1e12;
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, assets);
        vm.warp(pool.lpEpochStart(observedEpoch));
        uint256 pendingBranch = vm.snapshotState();

        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(observedEpoch, shares), assets);

        uint256 claimedAssets = assets / 2;
        vm.prank(ALICE);
        assertEq(juniorVault.claimDeposit(observedEpoch, claimedAssets, ALICE, ALICE), shares / 2);

        SettlementMonitorViewTypes.TrancheQueueStatus memory finalized =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertFalse(finalized.observedDepositQueued);
        assertTrue(finalized.observedDepositFinalized);
        assertFalse(finalized.observedDepositRejected);
        assertEq(finalized.observedDepositAssets, assets);
        assertEq(finalized.observedDepositPendingAssets, 0);
        assertEq(finalized.observedDepositClaimableAssets, assets - claimedAssets);
        assertEq(finalized.observedDepositClaimableShares, shares / 2);
        assertEq(finalized.observedDepositRefundableAssets, 0);
        assertEq(finalized.faultMask, 0);

        vm.revertToState(pendingBranch);
        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(observedEpoch, 0), assets);

        SettlementMonitorViewTypes.TrancheQueueStatus memory rejected =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertFalse(rejected.observedDepositQueued);
        assertFalse(rejected.observedDepositFinalized);
        assertTrue(rejected.observedDepositRejected);
        assertEq(rejected.observedDepositAssets, assets);
        assertEq(rejected.observedDepositPendingAssets, 0);
        assertEq(rejected.observedDepositClaimableAssets, 0);
        assertEq(rejected.observedDepositClaimableShares, 0);
        assertEq(rejected.observedDepositRefundableAssets, assets);
        assertEq(rejected.faultMask, 0);

        vm.prank(ALICE);
        assertEq(juniorVault.cancelPendingDeposit(observedEpoch), assets);

        SettlementMonitorViewTypes.TrancheQueueStatus memory fullyRefunded =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertTrue(fullyRefunded.observedDepositRejected, "rejection remains terminal after its last refund");
        assertEq(fullyRefunded.observedDepositAssets, 0);
        assertEq(fullyRefunded.observedDepositRefundableAssets, 0);
        assertEq(fullyRefunded.faultMask, 0, "a fully refunded rejection is a valid terminal state");
    }

    function test_ObservedRedeemFieldsTrackPartialFullAndRefundableFunding() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 shares = juniorVault.balanceOf(ALICE) / 4;
        uint256 observedEpoch = _requestRedeem(juniorVault, ALICE, shares);
        vm.warp(pool.lpEpochStart(observedEpoch));

        uint256 partialShares = shares / 2;
        uint256 partialAssets = 6000e6;
        usdc.mint(address(juniorVault), partialAssets);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(observedEpoch, partialShares, partialAssets);

        SettlementMonitorViewTypes.TrancheQueueStatus memory partialStatus =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertTrue(partialStatus.observedRedeemQueued);
        assertFalse(partialStatus.observedRedeemRefundEnabled);
        assertEq(partialStatus.observedRedeemShares, shares);
        assertEq(partialStatus.observedRedeemFundedShares, partialShares);
        assertEq(partialStatus.observedRedeemFundedAssets, partialAssets);
        assertEq(partialStatus.observedRedeemFundableShares, shares - partialShares);
        assertEq(partialStatus.observedRedeemClaimableShares, partialShares);
        assertEq(partialStatus.observedRedeemClaimableAssets, partialAssets);
        assertEq(partialStatus.observedRedeemRefundableShares, 0);
        assertEq(partialStatus.faultMask, 0);

        uint256 partialBranch = vm.snapshotState();
        uint256 remainingShares = shares - partialShares;
        uint256 remainingAssets = 7000e6;
        usdc.mint(address(juniorVault), remainingAssets);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(observedEpoch, remainingShares, remainingAssets);

        SettlementMonitorViewTypes.TrancheQueueStatus memory fullyFunded =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertFalse(fullyFunded.observedRedeemQueued);
        assertFalse(fullyFunded.observedRedeemRefundEnabled);
        assertEq(fullyFunded.observedRedeemFundedShares, shares);
        assertEq(fullyFunded.observedRedeemFundedAssets, partialAssets + remainingAssets);
        assertEq(fullyFunded.observedRedeemFundableShares, 0);
        assertEq(fullyFunded.observedRedeemClaimableShares, shares);
        assertEq(fullyFunded.observedRedeemClaimableAssets, partialAssets + remainingAssets);
        assertEq(fullyFunded.observedRedeemRefundableShares, 0);
        assertEq(fullyFunded.faultMask, 0);

        vm.revertToState(partialBranch);
        vm.prank(address(pool));
        assertEq(juniorVault.refundRedeemEpochRemainder(observedEpoch, remainingShares), remainingShares);

        SettlementMonitorViewTypes.TrancheQueueStatus memory refundable =
        monitorLens.getSettlementStatus(observedEpoch).junior;
        assertFalse(refundable.observedRedeemQueued);
        assertTrue(refundable.observedRedeemRefundEnabled);
        assertEq(refundable.observedRedeemFundedShares, partialShares);
        assertEq(refundable.observedRedeemFundedAssets, partialAssets);
        assertEq(refundable.observedRedeemFundableShares, 0);
        assertEq(refundable.observedRedeemClaimableShares, partialShares);
        assertEq(refundable.observedRedeemClaimableAssets, partialAssets);
        assertEq(refundable.observedRedeemRefundableShares, remainingShares);
        assertEq(refundable.faultMask, 0);
    }

    function test_ObservedUnqueuedNonterminalDepositIsCriticalOrphanState() public {
        uint256 observedEpoch = pool.currentLpEpoch() + 1;
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, observedEpoch),
            abi.encode(uint256(100e6), uint256(0), uint256(0), uint256(0), false)
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, observedEpoch),
            abi.encode(uint256(0), uint256(0), false, false)
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue =
        monitorLens.getSettlementStatus(observedEpoch).junior;

        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "unowned nonterminal deposit assets cannot exist outside the queue"
        );
    }

    function test_ObservedUnqueuedPartiallyFundedRedeemIsCriticalOrphanState() public {
        uint256 observedEpoch = pool.currentLpEpoch() + 1;
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, observedEpoch),
            abi.encode(
                uint256(100),
                uint256(40),
                uint256(40),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                false
            )
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_QUEUE_STATE_SELECTOR, observedEpoch),
            abi.encode(uint256(0), uint256(0), false, false)
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue =
        monitorLens.getSettlementStatus(observedEpoch).junior;

        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "an unfunded remainder must stay queued or enter refund mode"
        );
    }

    function test_ObservedQueuedNodeOutsideGlobalEndpointsIsCritical() public {
        uint256 observedEpoch = pool.currentLpEpoch() + 1;
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, observedEpoch),
            abi.encode(uint256(100e6), uint256(0), uint256(0), uint256(0), false)
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, observedEpoch),
            abi.encode(uint256(0), uint256(0), true, false)
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue =
        monitorLens.getSettlementStatus(observedEpoch).junior;

        assertEq(queue.depositQueueHead, 0);
        assertEq(queue.depositQueueTail, 0);
        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "a queued observed node must lie within nonempty global endpoints"
        );
    }

    function test_KnownEmptyQueuesKeepNoWorkRouteWhenTerminalReadFails() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        vm.mockCallRevert(
            address(engine),
            abi.encodeWithSelector(bytes4(keccak256("terminalNavSnapshot()"))),
            abi.encode(uint256(999))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertFalse(status.hasMaturedWork);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork),
            "terminal state is irrelevant after every queue proves empty"
        );
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
        assertEq(status.executionPathDependencyMask, 0);
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            ),
            "withdrawal-gate evidence is independently required for operational readiness"
        );
    }

    function test_PositiveMatureHeadKeepsCachedRouteWhenSiblingGetterFails() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        vm.warp(pool.lpEpochStart(observedEpoch));
        vm.mockCallRevert(
            address(juniorVault),
            abi.encodeWithSelector(MATURED_REDEEM_HEAD_SELECTOR, pool.currentLpEpoch()),
            abi.encode(uint256(999), uint256(999))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(status.hasMaturedWork);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark),
            "one validated positive head proves work exists"
        );
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertEq(status.executionPathDependencyMask, 0);
    }

    function test_PositiveMatureHeadKeepsAtomicRouteWhenSiblingGetterFails() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 25_000e6);
        _openMonitorPosition();
        vm.warp(pool.lpEpochStart(observedEpoch));
        _setCurrentBasket(100_000_000, 50_000, block.timestamp);
        vm.mockCallRevert(
            address(juniorVault),
            abi.encodeWithSelector(MATURED_REDEEM_HEAD_SELECTOR, pool.currentLpEpoch()),
            abi.encode(uint256(999), uint256(999))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(status.hasMaturedWork);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh),
            "known work plus live positions fully determines the route"
        );
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertEq(status.executionPathDependencyMask, 0);
    }

    function test_MalformedMaturePairIsCriticalAndRouteUnknown() public {
        uint256 currentEpoch = pool.currentLpEpoch();
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(MATURED_DEPOSIT_HEAD_SELECTOR, currentEpoch),
            abi.encode(uint256(0), uint256(1))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(currentEpoch);

        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "zero epoch and positive amount is impossible"
        );
        assertFalse(status.hasMaturedWork, "malformed output must not be exposed as work");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
    }

    function test_ImmatureMaturePairIsCriticalAndRouteUnknown() public {
        uint256 currentEpoch = pool.currentLpEpoch();
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(MATURED_DEPOSIT_HEAD_SELECTOR, currentEpoch),
            abi.encode(currentEpoch + 1, uint256(1))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(currentEpoch);

        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "a mature getter cannot return a future epoch"
        );
        assertFalse(status.hasMaturedWork);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
    }

    function test_StuckCorruptDepositHeadIsCriticalButCanonicalRouteReportsNoWork() public {
        uint256 headEpoch = pool.currentLpEpoch();
        uint256 observedEpoch = headEpoch + 1;
        vm.mockCall(address(juniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_HEAD_SELECTOR), abi.encode(headEpoch));
        vm.mockCall(address(juniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_TAIL_SELECTOR), abi.encode(headEpoch));
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, headEpoch),
            abi.encode(uint256(0), uint256(0), true, false)
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, headEpoch),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), false)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "a mature queued deposit head with no activatable assets is stuck"
        );
        assertFalse(status.hasMaturedWork);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork),
            "route follows the canonical matured getter while health reports the stuck auxiliary head"
        );
    }

    function test_StuckCorruptRedeemHeadIsCriticalButCanonicalRouteReportsNoWork() public {
        uint256 headEpoch = pool.currentLpEpoch();
        uint256 observedEpoch = headEpoch + 1;
        vm.mockCall(address(juniorVault), abi.encodeWithSelector(REDEEM_QUEUE_HEAD_SELECTOR), abi.encode(headEpoch));
        vm.mockCall(address(juniorVault), abi.encodeWithSelector(REDEEM_QUEUE_TAIL_SELECTOR), abi.encode(headEpoch));
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_QUEUE_STATE_SELECTOR, headEpoch),
            abi.encode(uint256(0), uint256(0), true, false)
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, headEpoch),
            abi.encode(
                uint256(100),
                uint256(100),
                uint256(100),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                false
            )
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "a mature queued redeem head with no fundable shares is stuck"
        );
        assertFalse(status.hasMaturedWork);
        assertEq(
            uint8(status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork),
            "route follows the canonical matured getter while health reports the stuck auxiliary head"
        );
    }

    function test_CorruptPendingDepositHeadIsCriticalButKeepsCanonicalRoute() public {
        uint256 assets = 25_000e6;
        uint256 headEpoch = _requestDeposit(juniorVault, ALICE, assets);
        vm.warp(pool.lpEpochStart(headEpoch));

        uint256[4] memory epoch;
        epoch[0] = assets;
        for (uint256 i = 1; i < 4; ++i) {
            epoch[i] = 1;
            _assertCorruptPendingDepositHead(headEpoch, epoch);
            epoch[i] = 0;
        }
    }

    function test_CorruptPendingRedeemHeadIsCriticalButKeepsCanonicalRoute() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 shares = juniorVault.balanceOf(ALICE) / 4;
        uint256 headEpoch = _requestRedeem(juniorVault, ALICE, shares);
        vm.warp(pool.lpEpochStart(headEpoch));

        uint256[9] memory epoch;
        epoch[0] = shares;
        uint256[7] memory corruptIndexes = [uint256(2), 3, 4, 5, 6, 7, 8];
        for (uint256 i; i < corruptIndexes.length; ++i) {
            uint256 field = corruptIndexes[i];
            epoch[field] = 1;
            _assertCorruptPendingRedeemHead(headEpoch, epoch);
            epoch[field] = 0;
        }
    }

    function test_ObservedQueuedRedeemRejectsConsumedFundingBasis() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 shares = juniorVault.balanceOf(ALICE) / 4;
        uint256 observedEpoch = _requestRedeem(juniorVault, ALICE, shares);
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, observedEpoch),
            abi.encode(
                shares,
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(1),
                uint256(0),
                false
            )
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue =
        monitorLens.getSettlementStatus(observedEpoch).junior;

        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "a queued epoch cannot have consumed funding basis"
        );
    }

    function test_ObservedQueuedDepositRejectsFinalizationFields() public {
        uint256 assets = 25_000e6;
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, assets);
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, observedEpoch),
            abi.encode(assets, uint256(1), uint256(0), uint256(0), false)
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue =
        monitorLens.getSettlementStatus(observedEpoch).junior;

        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "a queued deposit cannot carry finalization or claim fields"
        );
    }

    function test_MalformedAuxiliaryHeadBooleansAreUnknownWithoutErasingCanonicalWork() public {
        uint256 assets = 25_000e6;
        uint256 headEpoch = _requestDeposit(juniorVault, ALICE, assets);
        vm.warp(pool.lpEpochStart(headEpoch));

        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, headEpoch),
            abi.encode(uint256(0), uint256(0), uint256(2), uint256(0))
        );
        _assertAuxiliaryHeadUnknownKeepsWork(headEpoch);
        vm.clearMockedCalls();

        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, headEpoch),
            abi.encode(assets, uint256(0), uint256(0), uint256(0), uint256(2))
        );
        _assertAuxiliaryHeadUnknownKeepsWork(headEpoch);
    }

    function test_MalformedRedeemRefundBooleanIsUnknownWithoutErasingCanonicalWork() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 shares = juniorVault.balanceOf(ALICE) / 4;
        uint256 headEpoch = _requestRedeem(juniorVault, ALICE, shares);
        vm.warp(pool.lpEpochStart(headEpoch));
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, headEpoch),
            abi.encode(
                shares,
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(2)
            )
        );

        _assertAuxiliaryHeadUnknownKeepsWork(headEpoch);
    }

    function test_LinkedRejectedNeighborIsCriticalObservedState() public {
        (uint256 firstEpoch, uint256 secondEpoch) = _requestTwoDepositEpochs();
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, firstEpoch),
            abi.encode(uint256(0), secondEpoch, true, true)
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue = monitorLens.getSettlementStatus(secondEpoch).junior;

        assertTrue(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "a linked neighbor cannot be queued and rejected"
        );
    }

    function test_MalformedLinkedNeighborBooleanIsUnknownNotCritical() public {
        (uint256 firstEpoch, uint256 secondEpoch) = _requestTwoDepositEpochs();
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, firstEpoch),
            abi.encode(uint256(0), secondEpoch, uint256(2), uint256(0))
        );

        SettlementMonitorViewTypes.TrancheQueueStatus memory queue = monitorLens.getSettlementStatus(secondEpoch).junior;

        assertTrue(_hasDependency(queue.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertFalse(
            _hasCriticalFault(queue.faultMask, SettlementMonitorViewTypes.CriticalFault.ObservedEpochState),
            "malformed ABI evidence is unknown rather than a proven state contradiction"
        );
    }

    function test_FailedSidecarScalarExposesZeroWithoutFalseCriticalFault() public {
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("CAP_PRICE()"))), abi.encode(type(uint256).max)
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(health.engineCapPrice, 0, "failed scalar must not expose revert data");
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertEq(health.criticalFaultMask, 0, "failed evidence must not fabricate a contradiction");
    }

    function test_ExactConsumedSeniorReservationDoesNotReportActivationDeferral() public {
        uint256 configuredHeadroom = 25_000e6;
        _setSeniorCapacity(pool.seniorPrincipal() + configuredHeadroom, TEST_MAX_SENIOR_SHARE_BPS);
        uint256 reservation = pool.getSeniorDepositCapacity();
        assertGt(reservation, 0, "fixture must expose reservable capacity");
        uint256 observedEpoch = _requestDeposit(seniorVault, ALICE, reservation);

        assertEq(pool.reservedSeniorDepositAssetsUsdc(), reservation);
        assertEq(pool.getSeniorDepositCapacity(), 0, "reservation consumes all new-admission capacity");
        assertTrue(pool.areSeniorDepositReservationsWithinLimits(), "accepted reservation remains activatable");

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertFalse(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.SeniorCapacityUnavailable
            ),
            "new-admission capacity is not an activation gate"
        );
        assertFalse(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
    }

    function test_MaturedJuniorRedemptionMakesSeniorActivationUnconfirmed() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        config.maxSeniorExposureUsdc = TEST_MAX_SENIOR_EXPOSURE_USDC;
        config.maxSeniorShareBps = 5000;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();
        vm.prank(address(seniorVault));
        pool.reconcile();

        uint256 reservation = pool.getSeniorDepositCapacity();
        assertGt(reservation, 0, "fixture must expose ratio-bound Senior capacity");
        uint256 observedEpoch = _requestDeposit(seniorVault, BOB, reservation);
        uint256 redeemShares = juniorVault.balanceOf(address(this)) / 1000;
        assertGt(redeemShares, 0);
        assertEq(_requestRedeem(juniorVault, address(this), redeemShares), observedEpoch);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits(), "reservation starts within the live covenant");

        vm.warp(pool.lpEpochStart(observedEpoch));
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);
        assertGt(status.junior.maturedRedeemHeadShares, 0);
        assertFalse(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.SeniorCapacityUnavailable
            ),
            "pre-redemption capacity remains valid"
        );
        assertTrue(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            ),
            "Junior funding can reduce Senior capacity before activation"
        );
        assertFalse(
            _hasDeferral(
                status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            ),
            "Junior funding does not change the common tranche gate"
        );

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        assertGt(result.juniorFundedAssets, 0);
        assertEq(result.seniorDepositAssets, 0);
        assertEq(seniorVault.pendingDepositRequest(observedEpoch, BOB), reservation);
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());
    }

    function test_NoCodePlannerCannotReportHealthyOrCompleteConfig() public {
        address missingPlanner = address(0xBADDCAFE);
        assertEq(missingPlanner.code.length, 0);
        vm.mockCall(address(engine), abi.encodeWithSelector(bytes4(keccak256("planner()"))), abi.encode(missingPlanner));

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertTrue(uint8(health.state) != uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
        assertEq(monitorLens.observableConfigDigest(), bytes32(0), "invalid child wiring cannot be committed as config");
    }

    function test_CodeBearingReplacementPlannerCannotReportHealthyOrCompleteConfig() public {
        address incompatiblePlanner = address(0xBADDCAFE);
        vm.etch(incompatiblePlanner, hex"00");
        assertGt(incompatiblePlanner.code.length, 0);
        vm.mockCall(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("planner()"))), abi.encode(incompatiblePlanner)
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertTrue(uint8(health.state) != uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertTrue(
            health.criticalFaultMask != 0
                || _hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine)
        );
        assertEq(monitorLens.observableConfigDigest(), bytes32(0), "an incompatible planner cannot enter config");
    }

    function test_BoundPlannerCarryProbeFailureCannotReportHealthyOrCompleteConfig() public {
        address planner = address(engine.planner());
        vm.mockCall(
            planner,
            abi.encodeWithSelector(
                bytes4(keccak256("computeCurrentCarryIndex(uint256,uint64,uint256,uint256,uint256,uint256)")),
                uint256(7),
                uint64(11),
                uint256(11),
                uint256(13),
                uint256(17),
                uint256(19)
            ),
            abi.encode(uint256(8))
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertTrue(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.BindingMismatch)
        );
        assertEq(monitorLens.observableConfigDigest(), bytes32(0));
    }

    function test_BoundPlannerCalendarProbeFailureCannotReportHealthyOrCompleteConfig() public {
        address planner = address(engine.planner());
        vm.mockCall(
            planner,
            abi.encodeWithSelector(
                bytes4(keccak256("marketCalendarStatus(uint256,bool,bool,uint256)")),
                uint256(0),
                true,
                false,
                uint256(0)
            ),
            abi.encode(false, false)
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertTrue(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.BindingMismatch)
        );
        assertEq(monitorLens.observableConfigDigest(), bytes32(0));
    }

    function test_BoundPlannerCodehashDriftCannotReportHealthyOrCompleteConfig() public {
        address planner = address(engine.planner());
        vm.etch(planner, hex"00");

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertTrue(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.BindingMismatch)
        );
        assertEq(monitorLens.observableConfigDigest(), bytes32(0));
    }

    function test_VaultSelfSeedFloorCannotDoubleCountShareEscrowBacking() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 requestedShares = juniorVault.balanceOf(ALICE) / 4;
        _requestRedeem(juniorVault, ALICE, requestedShares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), requestedShares);

        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("seedReceiver()"))),
            abi.encode(address(juniorVault))
        );
        vm.mockCall(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("seedShareFloor()"))), abi.encode(uint256(1))
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(health.juniorRequiredShareEscrow, requestedShares + 1);
        assertEq(health.juniorActualShareEscrow, requestedShares);
        assertTrue(
            _hasCriticalFault(
                health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorShareEscrowDeficit
            )
        );
        assertFalse(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorSeedFloor),
            "the single share exists but cannot back two obligations"
        );
    }

    function test_PartialUninitializedSeedConfigurationIsCritical() public {
        vm.mockCall(address(pool), abi.encodeWithSelector(bytes4(keccak256("isTradingActive()"))), abi.encode(false));
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("juniorSeedInitialized()"))), abi.encode(false)
        );
        vm.mockCall(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("seedReceiver()"))), abi.encode(address(this))
        );
        vm.mockCall(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("seedShareFloor()"))), abi.encode(uint256(0))
        );

        SettlementMonitorViewTypes.SettlementHealth memory receiverOnly = monitorLens.getSettlementHealth();
        assertTrue(
            _hasCriticalFault(receiverOnly.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorSeedFloor),
            "receiver and floor must be configured atomically"
        );

        vm.clearMockedCalls();
        vm.mockCall(address(pool), abi.encodeWithSelector(bytes4(keccak256("isTradingActive()"))), abi.encode(false));
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("juniorSeedInitialized()"))), abi.encode(false)
        );
        vm.mockCall(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("seedReceiver()"))), abi.encode(address(0))
        );
        vm.mockCall(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("seedShareFloor()"))), abi.encode(uint256(1))
        );

        SettlementMonitorViewTypes.SettlementHealth memory floorOnly = monitorLens.getSettlementHealth();
        assertTrue(
            _hasCriticalFault(floorOnly.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorSeedFloor),
            "receiver and floor must be configured atomically"
        );
    }

    function test_ObservableConfigDigestChangesWithFadRunway() public {
        bytes32 beforeDigest = monitorLens.observableConfigDigest();
        uint256 changedRunway = engine.fadRunwaySeconds() + 1;
        vm.mockCall(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("fadRunwaySeconds()"))), abi.encode(changedRunway)
        );

        bytes32 afterDigest = monitorLens.observableConfigDigest();

        assertTrue(beforeDigest != bytes32(0));
        assertTrue(afterDigest != bytes32(0));
        assertTrue(afterDigest != beforeDigest, "FAD runway changes calendar policy and must change the digest");
    }

    function test_ObservableConfigDigestChangesWithJuniorMaintenanceFeeConfig() public {
        bytes32 beforeDigest = monitorLens.observableConfigDigest();
        assertTrue(beforeDigest != bytes32(0));

        vm.mockCall(address(juniorVault), abi.encodeWithSelector(MAINTENANCE_FEE_APR_BPS_SELECTOR), abi.encode(100));
        bytes32 rateDigest = monitorLens.observableConfigDigest();
        assertTrue(rateDigest != bytes32(0));
        assertTrue(rateDigest != beforeDigest, "maintenance-fee APR must be observable configuration");

        vm.clearMockedCalls();
        vm.mockCall(address(juniorVault), abi.encodeWithSelector(MAINTENANCE_FEE_RECIPIENT_SELECTOR), abi.encode(ALICE));
        bytes32 recipientDigest = monitorLens.observableConfigDigest();
        assertTrue(recipientDigest != bytes32(0));
        assertTrue(recipientDigest != beforeDigest, "maintenance-fee recipient must be observable configuration");
        assertTrue(recipientDigest != rateDigest);
    }

    function test_PendingJuniorMaintenanceFeeKeepsQueueSupplyRawAndHealthHealthy() public {
        _fundJunior(ALICE, 500_000e6);
        bytes32 defaultConfigDigest = monitorLens.observableConfigDigest();
        assertTrue(defaultConfigDigest != bytes32(0));

        juniorVault.proposeMaintenanceFeeConfig(1000, EVE);
        assertEq(
            monitorLens.observableConfigDigest(),
            defaultConfigDigest,
            "a pending fee proposal is not active observable configuration"
        );
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();

        assertEq(juniorVault.maintenanceFeeAprBps(), 1000);
        assertEq(juniorVault.maintenanceFeeRecipient(), EVE);
        bytes32 activeConfigDigest = monitorLens.observableConfigDigest();
        assertTrue(activeConfigDigest != bytes32(0));
        assertTrue(activeConfigDigest != defaultConfigDigest);

        uint256 requestedShares = juniorVault.balanceOf(ALICE) / 4;
        uint256 observedEpoch = _requestRedeem(juniorVault, ALICE, requestedShares);
        uint256 rawSupply = juniorVault.totalSupply();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);

        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(pendingFeeShares, 0, "one completed fee hour must create pending dilution");
        assertEq(juniorVault.totalSupply(), rawSupply, "a view-only pending fee must not mint shares");
        assertEq(juniorVault.accruedTotalSupply(), rawSupply + pendingFeeShares);
        assertEq(juniorVault.balanceOf(EVE), 0, "monitoring must not crystallize the pending fee");

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(observation.status.junior.totalSupply, rawSupply, "queue invariants require raw ERC20 supply");
        assertTrue(observation.status.junior.totalSupply != juniorVault.accruedTotalSupply());
        assertEq(observation.observableConfigDigest, activeConfigDigest);
        assertEq(monitorLens.observableConfigDigest(), activeConfigDigest, "pending dilution is not configuration");
        assertEq(juniorVault.maintenanceFeeAprBps(), 1000);
        assertEq(juniorVault.maintenanceFeeRecipient(), EVE);

        assertEq(uint8(observation.health.state), uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertEq(observation.health.criticalFaultMask, 0);
        assertEq(observation.health.dependencyFailureMask, 0);
        assertEq(observation.health.juniorRequiredShareEscrow, requestedShares);
        assertEq(observation.health.juniorActualShareEscrow, requestedShares);
    }

    function test_ObservationFailsClosedWhenJuniorMaintenanceFeeConfigIsUnreadable() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        uint256 branch = vm.snapshotState();

        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(MAINTENANCE_FEE_APR_BPS_SELECTOR), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementObservation memory missingRate =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(missingRate.observableConfigDigest, bytes32(0));
        assertFalse(missingRate.observationComplete);

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(MAINTENANCE_FEE_RECIPIENT_SELECTOR), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementObservation memory missingRecipient =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(missingRecipient.observableConfigDigest, bytes32(0));
        assertFalse(missingRecipient.observationComplete);
    }

    function test_ObservableConfigDigestChangesWithSettlementBuffer() public {
        bytes32 beforeDigest = monitorLens.observableConfigDigest();
        vm.mockCall(
            address(engine),
            abi.encodeWithSelector(bytes4(keccak256("settlementBufferBps()"))),
            abi.encode(engine.settlementBufferBps() + 1)
        );

        bytes32 afterDigest = monitorLens.observableConfigDigest();

        assertTrue(beforeDigest != bytes32(0));
        assertTrue(afterDigest != bytes32(0));
        assertTrue(afterDigest != beforeDigest, "settlement buffer policy must change the observable config digest");
    }

    function test_SharedClockFaultIsReflectedByBothTranches() public {
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()"))),
            abi.encode(REQUEST_CUTOFF + 1)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());

        assertTrue(
            _hasCriticalFault(status.senior.faultMask, SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula)
        );
        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula)
        );
    }

    function test_UnreadableEpochDurationMakesStandaloneHealthUnknown() public {
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("LP_EPOCH_DURATION()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertEq(health.criticalFaultMask, 0);
    }

    function test_StatusAggregatesBroadUnreadableDependencySurface() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        bytes memory unreadable = bytes("unreadable");
        bytes4[15] memory vaultSelectors = [
            bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()")),
            bytes4(keccak256("getRequestEpochWindow()")),
            DEPOSIT_QUEUE_HEAD_SELECTOR,
            DEPOSIT_QUEUE_TAIL_SELECTOR,
            REDEEM_QUEUE_HEAD_SELECTOR,
            REDEEM_QUEUE_TAIL_SELECTOR,
            MATURED_DEPOSIT_HEAD_SELECTOR,
            MATURED_REDEEM_HEAD_SELECTOR,
            bytes4(keccak256("totalSupply()")),
            bytes4(keccak256("pendingDepositEscrowAssets()")),
            bytes4(keccak256("withdrawalEscrowAssets()")),
            bytes4(keccak256("pendingRedeemEscrowShares()")),
            bytes4(keccak256("depositClaimEscrowShares()")),
            DEPOSIT_EPOCHS_SELECTOR,
            REDEEM_EPOCHS_SELECTOR
        ];
        for (uint256 i; i < vaultSelectors.length; ++i) {
            vm.mockCallRevert(address(seniorVault), abi.encodeWithSelector(vaultSelectors[i]), unreadable);
            vm.mockCallRevert(address(juniorVault), abi.encodeWithSelector(vaultSelectors[i]), unreadable);
        }
        vm.mockCallRevert(
            address(seniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, observedEpoch), unreadable
        );
        vm.mockCallRevert(
            address(seniorVault), abi.encodeWithSelector(REDEEM_QUEUE_STATE_SELECTOR, observedEpoch), unreadable
        );
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(DEPOSIT_QUEUE_STATE_SELECTOR, observedEpoch), unreadable
        );
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(REDEEM_QUEUE_STATE_SELECTOR, observedEpoch), unreadable
        );

        bytes4[9] memory poolSelectors = [
            bytes4(keccak256("getPoolLiquidityView()")),
            bytes4(keccak256("isWithdrawalLive()")),
            bytes4(keccak256("paused()")),
            bytes4(keccak256("canSettleDepositEntries()")),
            bytes4(keccak256("canAcceptOrdinaryDeposits()")),
            bytes4(keccak256("unassignedAssets()")),
            bytes4(keccak256("isSeniorImpairedAfterPendingDepositReconcile()")),
            bytes4(keccak256("getPendingDepositTrancheState()")),
            bytes4(keccak256("areSeniorDepositReservationsWithinLimits()"))
        ];
        for (uint256 i; i < poolSelectors.length; ++i) {
            vm.mockCallRevert(address(pool), abi.encodeWithSelector(poolSelectors[i]), unreadable);
        }
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("terminalNavSnapshot()"))), unreadable
        );
        vm.mockCallRevert(address(engine), abi.encodeWithSelector(bytes4(keccak256("isFadWindow()"))), unreadable);

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(observedEpoch);

        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Engine));
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertTrue(
            _hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.PoolAccountingPreview)
        );
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.SeniorVault));
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            )
        );
        assertTrue(
            _hasDeferral(status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown)
        );
        assertTrue(
            _hasDeferral(status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown)
        );
    }

    function test_MaturedWorkMakesUnreadableRouteInputsExecutionCritical() public {
        uint256 observedEpoch = _requestDeposit(juniorVault, ALICE, 10_000e6);
        vm.warp(pool.lpEpochStart(observedEpoch));
        _openMonitorPosition();
        uint256 branch = vm.snapshotState();

        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("getPoolLiquidityView()"))), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementStatus memory missingLiquidity =
            monitorLens.getSettlementStatus(observedEpoch);
        assertEq(uint8(missingLiquidity.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
        assertTrue(
            _hasDependency(
                missingLiquidity.executionPathDependencyMask,
                SettlementMonitorViewTypes.Dependency.PoolAccountingPreview
            )
        );

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("terminalNavSnapshot()"))), bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementStatus memory missingTerminal =
            monitorLens.getSettlementStatus(observedEpoch);
        assertEq(uint8(missingTerminal.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.Unknown));
        assertTrue(
            _hasDependency(missingTerminal.executionPathDependencyMask, SettlementMonitorViewTypes.Dependency.Engine)
        );
    }

    function test_HealthAggregatesRuntimeBindingAndOracleDependencyFailures() public {
        vm.mockCall(address(router), abi.encodeWithSelector(bytes4(keccak256("admin()"))), abi.encode(address(0)));
        vm.mockCall(
            address(router), abi.encodeWithSelector(bytes4(keccak256("pletherOracle()"))), abi.encode(address(0))
        );

        SettlementMonitorViewTypes.SettlementHealth memory missingComponents = monitorLens.getSettlementHealth();
        assertEq(uint8(missingComponents.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                missingComponents.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.BindingMismatch
            )
        );
        assertTrue(
            _hasDependency(missingComponents.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Router)
        );
        assertTrue(
            _hasDependency(missingComponents.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );

        vm.clearMockedCalls();
        address oracle = address(router.pletherOracle());
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("engine()"))), bytes("unreadable"));
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("housePool()"))), bytes("unreadable"));
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("pyth()"))), bytes("unreadable"));

        SettlementMonitorViewTypes.SettlementHealth memory unreadableOracle = monitorLens.getSettlementHealth();
        assertEq(uint8(unreadableOracle.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertTrue(_hasDependency(unreadableOracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle));
        assertTrue(_hasDependency(unreadableOracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pyth));

        vm.clearMockedCalls();
        vm.mockCall(oracle, abi.encodeWithSelector(bytes4(keccak256("engine()"))), abi.encode(address(0xBAD)));
        vm.mockCall(oracle, abi.encodeWithSelector(bytes4(keccak256("housePool()"))), abi.encode(address(0xBAD)));

        SettlementMonitorViewTypes.SettlementHealth memory mismatchedOracle = monitorLens.getSettlementHealth();
        assertEq(uint8(mismatchedOracle.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                mismatchedOracle.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.BindingMismatch
            )
        );
    }

    function test_ConfigDigestFailsClosedWhenEachConfigDomainIsUnreadable() public {
        address oracle = address(router.pletherOracle());
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("LP_EPOCH_DURATION()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(bytes4(keccak256("riskParams()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            oracle, abi.encodeWithSelector(bytes4(keccak256("orderExecutionStalenessLimit()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("seniorRateBps()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            address(seniorVault), abi.encodeWithSelector(bytes4(keccak256("seedReceiver()"))), bytes("unreadable")
        );

        assertEq(monitorLens.observableConfigDigest(), bytes32(0));
    }

    function test_EngineConfigDigestFailsClosedWhenEachScalarPolicyFieldIsUnreadable() public {
        assertTrue(monitorLens.observableConfigDigest() != bytes32(0), "baseline config digest must be available");

        address[6] memory targets = [
            address(engine),
            address(terminalNavBook),
            address(engine),
            address(engine),
            address(engine),
            address(engine)
        ];
        bytes4[6] memory selectors = [
            bytes4(keccak256("CAP_PRICE()")),
            bytes4(keccak256("SIZE_QUANTUM()")),
            bytes4(keccak256("engineMarkStalenessLimit()")),
            bytes4(keccak256("fadMaxStaleness()")),
            bytes4(keccak256("fadRunwaySeconds()")),
            bytes4(keccak256("settlementBufferBps()"))
        ];

        for (uint256 i; i < targets.length; ++i) {
            vm.mockCallRevert(targets[i], abi.encodeWithSelector(selectors[i]), bytes("unreadable"));
            assertEq(
                monitorLens.observableConfigDigest(),
                bytes32(0),
                "an unreadable Engine policy field must fail the config digest closed"
            );
            vm.clearMockedCalls();
        }
    }

    function test_HealthAggregatesCustodySeedAndHwmReadFailures() public {
        vm.mockCallRevert(
            address(seniorVault),
            abi.encodeWithSelector(bytes4(keccak256("pendingDepositEscrowAssets()"))),
            bytes("unreadable")
        );
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(juniorVault)),
            bytes("unreadable")
        );
        vm.mockCallRevert(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(juniorVault)),
            bytes("unreadable")
        );
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("seniorSeedInitialized()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("juniorSeedInitialized()"))), bytes("unreadable")
        );
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("seniorPrincipal()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertEq(health.criticalFaultMask, 0);
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.SeniorVault));
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
    }

    function test_ClockValidationAndStandaloneOracleViewsFailClosed() public {
        uint256 observedEpoch = pool.currentLpEpoch();
        uint256 branch = vm.snapshotState();

        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("LP_EPOCH_DURATION()"))), abi.encode(uint256(0))
        );
        SettlementMonitorViewTypes.SettlementStatus memory zeroDuration = monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasCriticalFault(
                zeroDuration.senior.faultMask, SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula
            )
        );

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("LP_EPOCH_DURATION()"))), bytes("unreadable")
        );
        SettlementMonitorViewTypes.OracleStatus memory missingDuration = monitorLens.getPoolReconcileOracleStatus();
        assertTrue(_hasDependency(missingDuration.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(seniorVault),
            abi.encodeWithSelector(bytes4(keccak256("getRequestEpochWindow()"))),
            bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementStatus memory missingSeniorWindow =
            monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasDependency(missingSeniorWindow.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.SeniorVault)
        );

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("getRequestEpochWindow()"))),
            bytes("unreadable")
        );
        SettlementMonitorViewTypes.SettlementStatus memory missingJuniorWindow =
            monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasDependency(missingJuniorWindow.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault)
        );

        vm.revertToState(branch);
        vm.clearMockedCalls();
        (uint256 nextEpoch, uint256 nextCutoff) = seniorVault.getRequestEpochWindow();
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("getRequestEpochWindow()"))),
            abi.encode(nextEpoch + 1, nextCutoff + EPOCH_DURATION)
        );
        SettlementMonitorViewTypes.SettlementStatus memory mismatchedWindows =
            monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasCriticalFault(
                mismatchedWindows.senior.faultMask, SettlementMonitorViewTypes.CriticalFault.RequestWindowMismatch
            )
        );

        vm.revertToState(branch);
        vm.clearMockedCalls();
        vm.mockCall(
            address(seniorVault),
            abi.encodeWithSelector(bytes4(keccak256("getRequestEpochWindow()"))),
            abi.encode(nextEpoch + 1, nextCutoff + EPOCH_DURATION)
        );
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(bytes4(keccak256("getRequestEpochWindow()"))),
            abi.encode(nextEpoch + 1, nextCutoff + EPOCH_DURATION)
        );
        SettlementMonitorViewTypes.SettlementStatus memory invalidFormula =
            monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasCriticalFault(
                invalidFormula.senior.faultMask, SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula
            )
        );
    }

    function test_StandaloneOracleStatusAttributesMissingAndUnreadableBindings() public {
        uint256 branch = vm.snapshotState();
        vm.mockCall(
            address(router), abi.encodeWithSelector(bytes4(keccak256("pletherOracle()"))), abi.encode(address(0))
        );

        SettlementMonitorViewTypes.OracleStatus memory missingOracle = monitorLens.getPoolReconcileOracleStatus();
        assertTrue(_hasDependency(missingOracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle));

        vm.revertToState(branch);
        vm.clearMockedCalls();
        address oracle = address(router.pletherOracle());
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("engine()"))), bytes("unreadable"));
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("housePool()"))), bytes("unreadable"));
        vm.mockCallRevert(oracle, abi.encodeWithSelector(bytes4(keccak256("pyth()"))), bytes("unreadable"));
        vm.mockCallRevert(
            oracle, abi.encodeWithSelector(bytes4(keccak256("basketMaxConfidenceRatioBps()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.OracleStatus memory unreadableBindings = monitorLens.getPoolReconcileOracleStatus();
        assertTrue(
            _hasDependency(unreadableBindings.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertTrue(_hasDependency(unreadableBindings.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pyth));
    }

    function test_StatusReportsCombinedOperationalWarningsAndDepositDeferrals() public {
        IHousePool.PoolLiquidityView memory liquidity = pool.getPoolLiquidityView();
        liquidity.freeUsdc = 0;
        liquidity.currentTerminalDeficitUsdc = 1;
        liquidity.degradedMode = true;
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("getPoolLiquidityView()"))), abi.encode(liquidity)
        );
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("canAcceptOrdinaryDeposits()"))), abi.encode(false)
        );
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("unassignedAssets()"))), abi.encode(uint256(1))
        );
        vm.mockCall(address(pool), abi.encodeWithSelector(bytes4(keccak256("paused()"))), abi.encode(true));

        SettlementMonitorViewTypes.SettlementStatus memory status =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());

        assertTrue(
            _hasDeferral(status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.LifecycleInactive)
        );
        assertTrue(
            _hasDeferral(status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.UnassignedAssets)
        );
        assertTrue(
            _hasDeferral(status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.PoolPaused)
        );
        assertTrue(
            _hasDeferral(status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.EngineDegraded)
        );
        assertTrue(
            _hasDeferral(status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.TerminalDeficit)
        );
        assertTrue(_hasWarning(status.warningMask, SettlementMonitorViewTypes.Warning.PoolPaused));
        assertTrue(_hasWarning(status.warningMask, SettlementMonitorViewTypes.Warning.TerminalDeficit));
        assertTrue(_hasWarning(status.warningMask, SettlementMonitorViewTypes.Warning.NoFreeCash));
        assertTrue(
            _hasOperationalBlocker(
                status.operationalBlockerMask, SettlementMonitorViewTypes.OperationalBlocker.EngineDegraded
            )
        );
    }

    function test_UnreadableSeniorReservationGateDoesNotPoisonJuniorDeferral() public {
        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(bytes4(keccak256("areSeniorDepositReservationsWithinLimits()"))),
            bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementStatus memory status =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());

        assertTrue(
            _hasDeferral(status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown)
        );
        assertFalse(
            _hasDeferral(
                status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown
            ),
            "senior reservation evidence is irrelevant to Junior activation"
        );
    }

    function test_ResidualPendingClaimantValueReportsConservativeActivationGate() public {
        assertEq(pool.unassignedAssets(), 0);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            1e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.AlreadyRetained
        );
        assertEq(pool.unassignedAssets(), 0, "the residual bucket is distinct from current unassigned assets");
        assertFalse(pool.canAcceptTrancheDeposits(false), "the canonical projected gate must close");

        SettlementMonitorViewTypes.SettlementStatus memory status =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());

        assertTrue(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
        assertTrue(
            _hasDeferral(
                status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IHousePool.getPendingDepositTrancheState.selector),
            abi.encode(pool.seniorPrincipal(), uint256(0))
        );
        SettlementMonitorViewTypes.SettlementStatus memory combined =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());
        assertTrue(
            _hasDeferral(
                combined.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ZeroPrincipalWithSupply
            )
        );
        assertTrue(
            _hasDeferral(
                combined.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            ),
            "a Junior-specific zero-principal blocker cannot hide the simultaneous common gate"
        );
    }

    function test_ConservativeActivationGateProjectsUnreconciledSeniorImpairment() public {
        uint256 retainedAssets = pool.seniorPrincipal() / 2;
        usdc.burn(address(pool), pool.rawAssets() - retainedAssets);

        assertEq(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "stored Senior accounting is not yet impaired");
        assertFalse(pool.canSettleDepositEntries(), "the diagnostic must project the settlement-time reconcile");

        SettlementMonitorViewTypes.SettlementStatus memory beforeReconcile =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());
        assertTrue(
            _hasDeferral(
                beforeReconcile.seniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
        assertTrue(
            _hasDeferral(
                beforeReconcile.juniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertLt(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "reconcile must realize the projected impairment");
        assertFalse(pool.canSettleDepositEntries(), "the projected and committed gates must agree");
    }

    function test_ConservativeActivationGateProjectsExactlyRestorativeRecapitalization() public {
        uint256 retainedAssets = pool.seniorPrincipal() / 2;
        usdc.burn(address(pool), pool.rawAssets() - retainedAssets);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 recapitalization = pool.seniorHighWaterMark() - pool.seniorPrincipal();
        assertGt(recapitalization, 0, "fixture must begin with committed Senior impairment");
        usdc.mint(address(pool), recapitalization);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapitalization,
            IHousePool.ClaimantInflowKind.Recapitalization,
            IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertTrue(pool.canSettleDepositEntries(), "the diagnostic must project the pending restorative reconcile");
        SettlementMonitorViewTypes.SettlementStatus memory beforeReconcile =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());
        assertFalse(
            _hasDeferral(
                beforeReconcile.seniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
        assertFalse(
            _hasDeferral(
                beforeReconcile.juniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "reconcile must consume the restorative bucket");
        assertTrue(pool.canSettleDepositEntries(), "the projected and committed gates must agree");
    }

    function test_ConservativeActivationGateReopensAfterSeniorRedemptionRoundingCure() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        _fundSenior(ALICE, 1_001_695);
        vm.warp(block.timestamp + seniorVault.DEPOSIT_COOLDOWN());
        uint256 observedEpoch = _requestDeposit(seniorVault, BOB, 1e6);
        assertEq(_requestRedeem(seniorVault, ALICE, seniorVault.balanceOf(ALICE)), observedEpoch);

        usdc.burn(address(pool), pool.rawAssets() - (pool.seniorPrincipal() - 1));
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(
            pool.seniorHighWaterMark() - pool.seniorPrincipal(),
            1,
            "fixture must create the one-atom impairment cured by redemption rounding"
        );
        assertFalse(pool.canSettleDepositEntries());

        vm.warp(pool.lpEpochStart(observedEpoch));
        IHousePool.LpEpochSettlementResult memory firstPass = _settleLpEpochForTest();
        assertGt(firstPass.seniorFundedAssets, 0, "the matured Senior redemption must still be funded");
        assertTrue(firstPass.entriesDeferred, "tranche-specific capacity must keep the Senior deposit pending");
        assertEq(
            pool.seniorPrincipal(),
            pool.seniorHighWaterMark(),
            "Senior redemption rounding must cure the one-atom impairment"
        );
        assertEq(
            monitorLens.getSettlementStatus(observedEpoch).senior.observedDepositPendingAssets,
            1e6,
            "the independently capacity-constrained Senior deposit must remain pending"
        );
        assertTrue(pool.canSettleDepositEntries(), "the conservative common gate may reopen after Senior funding");
    }

    function test_SettlementRechecksActivationGateAfterSeniorRedemptionCreatesImpairment() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        uint256 juniorBacking = 100e6;
        uint256 seniorBootstrapAssets = 3e6;
        uint256 targetRawAssets = juniorBacking + seniorBootstrapAssets;
        uint256 rawAssets = pool.rawAssets();
        if (rawAssets > targetRawAssets) {
            usdc.burn(address(pool), rawAssets - targetRawAssets);
        } else {
            usdc.mint(address(pool), targetRawAssets - rawAssets);
        }
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(juniorBacking);
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(targetRawAssets);
        stdstore.target(address(pool)).sig("unassignedAssets()").checked_write(seniorBootstrapAssets);

        address rebootLp = address(0xB007);
        uint256 oldSeniorSupply = seniorVault.totalSupply();
        pool.assignUnassignedAssets(true, rebootLp);
        uint256 rebootShares = seniorVault.balanceOf(rebootLp);
        assertEq(rebootShares, seniorBootstrapAssets * (oldSeniorSupply + 1000));
        assertEq(pool.seniorPrincipal(), seniorBootstrapAssets);
        assertEq(pool.seniorHighWaterMark(), seniorBootstrapAssets);

        uint256 redeemShares = (seniorBootstrapAssets - 1) * (oldSeniorSupply + 1000);
        assertLt(redeemShares, rebootShares, "the reboot LP must retain shares after the partial redemption");
        vm.warp(block.timestamp + seniorVault.DEPOSIT_COOLDOWN());
        uint256 observedEpoch = _requestDeposit(seniorVault, BOB, 1e6);
        assertEq(_requestRedeem(seniorVault, rebootLp, redeemShares), observedEpoch);
        assertTrue(pool.canSettleDepositEntries(), "an immature Senior redemption cannot change this pass");

        vm.warp(pool.lpEpochStart(observedEpoch));
        assertTrue(
            pool.canSettleDepositEntries(),
            "the Pool diagnostic deliberately projects only the pre-redemption common gate"
        );
        SettlementMonitorViewTypes.SettlementStatus memory beforeSettlement =
            monitorLens.getSettlementStatus(observedEpoch);
        assertTrue(
            _hasDeferral(
                beforeSettlement.seniorDepositDeferralMask,
                SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        assertEq(result.seniorFundedShares, redeemShares);
        assertEq(result.seniorFundedAssets, seniorBootstrapAssets - 1);
        assertEq(pool.seniorPrincipal(), 1, "virtual-offset pricing leaves one principal atom");
        assertEq(pool.seniorHighWaterMark(), 2, "pro-rata HWM removal leaves two protected atoms");
        assertEq(result.seniorDepositAssets, 0, "post-redemption impairment must block activation");
        assertTrue(result.entriesDeferred);
        assertEq(seniorVault.pendingDepositRequest(observedEpoch, BOB), 1e6);
    }

    function test_JuniorZeroPrincipalDoesNotFabricateACommonActivationDeferral() public {
        assertTrue(pool.canSettleDepositEntries());
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IHousePool.getPendingDepositTrancheState.selector),
            abi.encode(pool.seniorPrincipal(), uint256(0))
        );

        SettlementMonitorViewTypes.SettlementStatus memory status =
            monitorLens.getSettlementStatus(pool.currentLpEpoch());

        assertTrue(
            _hasDeferral(
                status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ZeroPrincipalWithSupply
            )
        );
        assertFalse(
            _hasDeferral(
                status.seniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
        assertFalse(
            _hasDeferral(
                status.juniorDepositDeferralMask, SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed
            )
        );
    }

    function test_UnreadableReservationMakesHealthUnknownWithoutFalseCriticalFault() public {
        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(bytes4(keccak256("reservedSeniorDepositAssetsUsdc()"))),
            bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertEq(health.criticalFaultMask, 0);
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Pool));
        assertFalse(
            _hasCriticalFault(
                health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.SeniorReservationExceedsEscrow
            )
        );
    }

    function test_HealthDetectsIndividualSideDivisibilityAndZeroSideAggregateCorruption() public {
        bytes memory bullSideCall = abi.encodeWithSelector(bytes4(keccak256("sides(uint256)")), uint256(0));
        uint256 branch = vm.snapshotState();

        vm.mockCall(address(engine), bullSideCall, abi.encode(uint256(0), uint256(1), uint256(0), uint256(0)));
        SettlementMonitorViewTypes.SettlementHealth memory indivisible = monitorLens.getSettlementHealth();
        assertEq(uint8(indivisible.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(indivisible.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.NavLotsMismatch)
        );

        vm.revertToState(branch);
        vm.mockCall(address(engine), bullSideCall, abi.encode(uint256(0), uint256(0), uint256(0), uint256(1)));
        SettlementMonitorViewTypes.SettlementHealth memory emptySide = monitorLens.getSettlementHealth();
        assertEq(uint8(emptySide.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                emptySide.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.NavActiveEmptyMismatch
            )
        );
    }

    function test_NoncanonicalBookStateCapIsUnknownWithoutFalseNavMismatch() public {
        vm.mockCall(
            address(terminalNavBook),
            abi.encodeWithSelector(bytes4(keccak256("bookState()"))),
            abi.encode(
                uint256(type(uint32).max) + 1,
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                int256(0),
                int256(0)
            )
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Unknown));
        assertEq(health.criticalFaultMask, 0);
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.TerminalNavBook));
        assertFalse(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.NavCapMismatch)
        );
    }

    function test_KnownCriticalFaultOutranksAnUnrelatedUnknownRead() public {
        usdc.burn(address(pool), 1e6);
        vm.mockCallRevert(
            address(juniorVault), abi.encodeWithSelector(bytes4(keccak256("depositQueueHead()"))), bytes("unreadable")
        );

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();

        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.PoolCustodyDeficit)
        );
        assertTrue(_hasDependency(health.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
    }

    function test_HealthDetectsVaultShareEscrowDeficitWithoutStorageMutation() public {
        _fundJunior(ALICE, 50_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 requestedShares = juniorVault.balanceOf(ALICE) / 4;
        _requestRedeem(juniorVault, ALICE, requestedShares);

        vm.prank(address(juniorVault));
        juniorVault.transfer(DAVE, 1);

        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();
        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Critical));
        assertTrue(
            _hasCriticalFault(
                health.criticalFaultMask, SettlementMonitorViewTypes.CriticalFault.JuniorShareEscrowDeficit
            )
        );
        assertEq(health.juniorRequiredShareEscrow, requestedShares);
        assertEq(health.juniorActualShareEscrow, requestedShares - 1);
    }

    function test_ValidFrozenSeniorFeeRetainedAboveHwmIsNotAHealthFault() public {
        _fundSenior(ALICE, 500_000e6);
        _fundJunior(BOB, 500_000e6);
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen());

        uint256 requestedShares = seniorVault.balanceOf(ALICE) / 5;
        uint256 requestId = _requestRedeem(seniorVault, ALICE, requestedShares);
        vm.warp(pool.lpEpochStart(requestId));
        assertTrue(engine.isOracleFrozen());
        vm.prank(address(router));
        engine.updateMarkPrice(100_000_000, uint64(block.timestamp));
        _settleLpEpochForTest();

        assertGt(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "frozen fee should be retained by Senior");
        SettlementMonitorViewTypes.SettlementHealth memory health = monitorLens.getSettlementHealth();
        assertEq(uint8(health.state), uint8(SettlementMonitorViewTypes.HealthState.Healthy));
        assertEq(health.criticalFaultMask, 0);
        assertEq(health.seniorImpairmentUsdc, 0);
        assertEq(health.seniorPrincipalAboveHighWaterMarkUsdc, pool.seniorPrincipal() - pool.seniorHighWaterMark());
    }

    function test_ObservationAndConfigDigestsAreDeterministicAndDomainSensitive() public {
        uint256 observedEpoch = juniorVault.currentLpEpoch() + 1;
        bytes32 configBefore = monitorLens.observableConfigDigest();
        SettlementMonitorViewTypes.SettlementObservation memory first =
            monitorLens.getSettlementObservation(observedEpoch);
        SettlementMonitorViewTypes.SettlementObservation memory repeated =
            monitorLens.getSettlementObservation(observedEpoch);

        assertTrue(configBefore != bytes32(0));
        assertEq(first.observableConfigDigest, configBefore);
        assertEq(repeated.observableConfigDigest, configBefore);
        assertEq(first.observationDigest, repeated.observationDigest);
        assertEq(first.completeObservationDigest, repeated.completeObservationDigest);
        assertEq(first.schemaVersion, monitorLens.CONFIG_SCHEMA_VERSION());

        SettlementMonitorViewTypes.SettlementObservation memory differentEpoch =
            monitorLens.getSettlementObservation(observedEpoch + 1);
        assertEq(differentEpoch.observableConfigDigest, configBefore);
        assertTrue(differentEpoch.observationDigest != first.observationDigest);

        vm.warp(block.timestamp + 1);
        SettlementMonitorViewTypes.SettlementObservation memory later =
            monitorLens.getSettlementObservation(observedEpoch);
        assertEq(later.observableConfigDigest, configBefore);
        assertTrue(later.observationDigest != first.observationDigest);
    }

    function _assertCorruptPendingDepositHead(
        uint256 headEpoch,
        uint256[4] memory epoch
    ) internal {
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, headEpoch),
            abi.encode(epoch[0], epoch[1], epoch[2], epoch[3], false)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);

        assertTrue(status.hasMaturedWork, "canonical getter still exposes the real pending head");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "impossible pending-deposit lifecycle fields must be critical"
        );
        vm.clearMockedCalls();
    }

    function _assertCorruptPendingRedeemHead(
        uint256 headEpoch,
        uint256[9] memory epoch
    ) internal {
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, headEpoch),
            abi.encode(epoch[0], epoch[1], epoch[2], epoch[3], epoch[4], epoch[5], epoch[6], epoch[7], epoch[8], false)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);

        assertTrue(status.hasMaturedWork, "canonical getter still exposes the real pending head");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "impossible pending-redeem lifecycle fields must be critical"
        );
        vm.clearMockedCalls();
    }

    function _assertAuxiliaryHeadUnknownKeepsWork(
        uint256 headEpoch
    ) internal view {
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);
        assertTrue(status.hasMaturedWork);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.executionPathDependencyMask, 0);
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertFalse(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "noncanonical ABI booleans are unreadable rather than proven corruption"
        );
    }

    function _requestTwoDepositEpochs() internal returns (uint256 firstEpoch, uint256 secondEpoch) {
        uint256 firstStart = ((block.timestamp + 2 hours) / EPOCH_DURATION) * EPOCH_DURATION;
        vm.warp(firstStart - REQUEST_CUTOFF - 1);
        firstEpoch = _requestDeposit(juniorVault, ALICE, 10_000e6);
        vm.warp(firstStart + EPOCH_DURATION - REQUEST_CUTOFF - 1);
        secondEpoch = _requestDeposit(juniorVault, BOB, 10_000e6);
        assertEq(secondEpoch, firstEpoch + 1);
    }

    function _requestDeposit(
        TrancheVault vault,
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _requestRedeem(
        TrancheVault vault,
        address owner,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
    }

    function _openMonitorPosition() internal {
        _fundTrader(TRADER, 200e6);
        _open(TRADER, CfdTypes.Side.BULL, 1000e18, 100e6, 100_000_000);
    }

    function _setCurrentBasket(
        uint256 price,
        uint64 confidence,
        uint256 publishTime
    ) internal {
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), confidence, int32(-8), publishTime);
    }

    function _validPoolReconcileSnapshot() internal returns (IPletherOracle.PriceSnapshot memory snapshot) {
        vm.clearMockedCalls();
        (snapshot,) = router.pletherOracle().getLatestPoolReconcilePrice();
    }

    function _assertMalformedOracleSnapshot(
        uint256 observedEpoch,
        IPletherOracle.PriceSnapshot memory snapshot
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encode(snapshot, uint256(50_000))
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh),
            "malformed oracle output must not erase a known atomic route"
        );
        assertFalse(observation.oracle.readSucceeded);
        assertFalse(observation.oracle.policyValid);
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertTrue(
            _hasDependency(observation.status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertEq(observation.status.executionPathDependencyMask, 0);
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function _assertMalformedNarrowOracleError(
        bytes memory revertData
    ) internal {
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            revertData
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(pool.currentLpEpoch());

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork)
        );
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle),
            "noncanonical narrow ABI words are not authentic policy evidence"
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function _hasWarning(
        uint256 mask,
        SettlementMonitorViewTypes.Warning warning
    ) internal pure returns (bool) {
        return mask & (1 << uint256(warning)) != 0;
    }

    function _hasOperationalBlocker(
        uint256 mask,
        SettlementMonitorViewTypes.OperationalBlocker blocker
    ) internal pure returns (bool) {
        return mask & (1 << uint256(blocker)) != 0;
    }

    function _hasCriticalFault(
        uint256 mask,
        SettlementMonitorViewTypes.CriticalFault fault
    ) internal pure returns (bool) {
        return mask & (1 << uint256(fault)) != 0;
    }

    function _hasDependency(
        uint256 mask,
        SettlementMonitorViewTypes.Dependency dependency
    ) internal pure returns (bool) {
        return mask & (1 << uint256(dependency)) != 0;
    }

    function _hasDeferral(
        uint256 mask,
        SettlementMonitorViewTypes.DepositDeferral deferral
    ) internal pure returns (bool) {
        return mask & (1 << uint256(deferral)) != 0;
    }

}
