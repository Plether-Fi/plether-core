// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";

contract SettlementBufferAccountingHarness {

    function target(
        uint256 maxLiabilityUsdc,
        uint256 settlementBufferBps
    ) external pure returns (uint256) {
        return SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, settlementBufferBps);
    }

    function isCovered(
        uint256 effectiveAssetsUsdc,
        uint256 maxLiabilityUsdc,
        uint256 settlementBufferBps
    ) external pure returns (bool) {
        return
            SolvencyAccountingLib.hasRequiredSettlementBuffer(
                effectiveAssetsUsdc, maxLiabilityUsdc, settlementBufferBps
            );
    }

}

contract SettlementBufferAccountingTest is Test {

    SettlementBufferAccountingHarness internal harness;

    function setUp() public {
        harness = new SettlementBufferAccountingHarness();
    }

    function test_SettlementBufferTarget_RoundsUpAndPreservesZeroBoundaries() public view {
        assertEq(harness.target(0, 25), 0, "zero liability must not create a buffer");
        assertEq(harness.target(1, 0), 0, "disabled policy must not create a buffer");
        assertEq(harness.target(1, 25), 1, "a nonzero fractional atom must round up");
        assertEq(harness.target(399, 25), 1, "sub-atom fractions must round up");
        assertEq(harness.target(400, 25), 1, "an exact atom must remain exact");
        assertEq(harness.target(401, 25), 2, "a fraction above an exact atom must round up");
        assertEq(harness.target(400_000e6, 25), 1000e6, "25 bps liability target");
    }

    function test_HasRequiredSettlementBuffer_AcceptsEqualityAndRejectsOneAtomLess() public view {
        uint256 liabilityUsdc = 400_000e6;
        uint256 bufferUsdc = harness.target(liabilityUsdc, 25);
        uint256 exactRequirementUsdc = liabilityUsdc + bufferUsdc;

        assertTrue(
            harness.isCovered(exactRequirementUsdc, liabilityUsdc, 25), "exact liability-plus-buffer equality must pass"
        );
        assertFalse(
            harness.isCovered(exactRequirementUsdc - 1, liabilityUsdc, 25), "one atom below the buffer must fail"
        );
        assertFalse(
            harness.isCovered(liabilityUsdc, liabilityUsdc, 25), "raw solvency equality is intentionally under-buffer"
        );
        assertTrue(
            harness.isCovered(liabilityUsdc, liabilityUsdc, 0), "disabled buffer must preserve raw solvency equality"
        );
        assertFalse(
            harness.isCovered(liabilityUsdc - 1, liabilityUsdc, 0),
            "disabled buffer must not weaken the raw insolvency boundary"
        );
    }

}

contract SettlementBufferIntegrationTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_DefaultSettlementBufferIsTwentyFiveBps() public view {
        assertEq(engine.settlementBufferBps(), 25, "testnet deployments must start with the 25 bps buffer");
    }

    function test_AdminAcceptsZeroTwentyFiveAndHundredBpsThroughTimelock() public {
        _finalizeSettlementBufferBps(0);
        assertEq(engine.settlementBufferBps(), 0, "governance must be able to disable the buffer");

        _finalizeSettlementBufferBps(25);
        assertEq(engine.settlementBufferBps(), 25, "governance must accept the release default");

        _finalizeSettlementBufferBps(100);
        assertEq(engine.settlementBufferBps(), 100, "governance must accept the configured maximum");
    }

    function test_AdminRejectsSettlementBufferAboveHundredBps() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.settlementBufferBps = 101;

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);

        assertEq(engine.settlementBufferBps(), 25, "a rejected proposal must not change the live buffer");
    }

    function test_RawSolvencyCanClearDegradedModeWhileNewExposureRemainsBufferBlocked() public {
        address incumbent = address(0xB0FF01);
        address freshTrader = address(0xB0FF02);
        _fundTrader(incumbent, 10_000e6);
        _fundTrader(freshTrader, 10_000e6);
        _open(incumbent, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 settlementBufferUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engine.settlementBufferBps());
        uint256 poolAssetsUsdc = pool.totalAssets();
        assertGt(poolAssetsUsdc, maxLiabilityUsdc, "setup must have drainable raw-solvency headroom");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssetsUsdc - maxLiabilityUsdc);
        assertEq(pool.totalAssets(), maxLiabilityUsdc, "setup must stop at raw solvency equality");

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        engine.clearDegradedMode();
        assertFalse(engine.degradedMode(), "raw solvency equality must be sufficient to clear degraded mode");

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory accounting =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(accounting.effectiveSolvencyAssetsUsdc, maxLiabilityUsdc, "raw effective assets");
        assertEq(
            accounting.withdrawalReservedUsdc,
            maxLiabilityUsdc + settlementBufferUsdc,
            "LP withdrawal reserve must retain the settlement buffer"
        );
        assertEq(accounting.freeUsdc, 0, "under-buffer raw solvency must expose no LP withdrawal cash");

        uint8 revertCode = engineLens.previewOpenRevertCode(
            freshTrader, CfdTypes.Side.BEAR, 10_000e18, 1000e6, 1e8, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "non-dominant new exposure must remain blocked until the buffer is restored"
        );
        assertFalse(engine.degradedMode(), "buffer deficiency alone must not relatch degraded mode");
    }

    function test_QueuedOpenIsRevalidatedAndTerminallyFailsAfterBufferIncrease() public {
        IOrderRouterAdminHost.RouterConfig memory routerConfig = _routerConfig();
        routerConfig.maxOrderAge = 1 hours;
        _setRouterConfig(routerConfig);

        ICfdEngineAdminHost.EngineRiskConfig memory riskConfig = _engineRiskConfig();
        riskConfig.settlementBufferBps = 100;
        engineAdmin.proposeRiskConfig(riskConfig);
        uint256 activationTime = engineAdmin.riskConfigActivationTime();
        vm.warp(activationTime - 30 minutes);

        address incumbent = address(0xB0FF03);
        address queuedTrader = address(0xB0FF04);
        _fundTrader(incumbent, 10_000e6);
        _fundTrader(queuedTrader, 10_000e6);
        _open(incumbent, CfdTypes.Side.BEAR, 300_000e18, 5000e6, 1e8);

        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 bufferAtCommitUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engine.settlementBufferBps());
        uint256 assetsAtCommitUsdc = maxLiabilityUsdc + bufferAtCommitUsdc;
        uint256 poolAssetsUsdc = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssetsUsdc - assetsAtCommitUsdc);

        uint256 queuedSize = 10_000e18;
        uint256 queuedMarginUsdc = 1000e6;
        uint8 commitCode = engineLens.previewOpenRevertCode(
            queuedTrader, CfdTypes.Side.BULL, queuedSize, queuedMarginUsdc, 1e8, uint64(block.timestamp)
        );
        assertEq(commitCode, uint8(CfdEnginePlanTypes.OpenRevertCode.OK), "25 bps commit preflight must pass");

        uint64 orderId = router.nextCommitId();
        vm.prank(queuedTrader);
        router.commitOrder(CfdTypes.Side.BULL, queuedSize, queuedMarginUsdc, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(orderId);

        vm.warp(activationTime);
        engineAdmin.finalizeRiskConfig();

        uint8 executionCode = engineLens.previewOpenRevertCode(
            queuedTrader, CfdTypes.Side.BULL, queuedSize, queuedMarginUsdc, 1e8, pending.commitTime + 1
        );
        assertEq(
            executionCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "the live 100 bps policy must invalidate the queued open"
        );

        bytes[] memory updateData = _mockPythUpdateData();
        router.executeOrder(orderId, updateData);

        (uint256 openedSize,,,,,,) = engine.positions(queuedTrader);
        assertEq(openedSize, 0, "execution-time revalidation must not create the position");
        assertEq(router.pendingOrderCounts(queuedTrader), 0, "terminal failure must unlink the account queue");
        assertEq(router.nextExecuteId(), 0, "terminal failure must advance the global queue");
        assertEq(
            uint256(OrderRouterDebugLens.loadOrderStatus(vm, router, orderId)),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "SOLVENCY_EXCEEDED must be a terminal execution failure"
        );
    }

    function _finalizeSettlementBufferBps(
        uint256 settlementBufferBps
    ) internal {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.settlementBufferBps = settlementBufferBps;
        engineAdmin.proposeRiskConfig(config);
        vm.warp(engineAdmin.riskConfigActivationTime());
        engineAdmin.finalizeRiskConfig();
    }

}
