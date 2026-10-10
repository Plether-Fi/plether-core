// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract OrderRouterAccountBehaviorTest is BasePerpTest {

    enum LifecycleBookFault {
        NoCode,
        Router,
        Engine,
        Clearinghouse,
        Pool
    }

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _expectInvalidLifecycleBook(
        LifecycleBookFault fault
    ) internal {
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);

        address boundRouter = fault == LifecycleBookFault.Router ? address(0xBAD1) : predictedRouter;
        address boundEngine = fault == LifecycleBookFault.Engine ? address(0xBAD2) : address(engine);
        address boundClearinghouse =
            fault == LifecycleBookFault.Clearinghouse ? address(0xBAD3) : address(clearinghouse);
        address boundPool = fault == LifecycleBookFault.Pool ? address(0xBAD4) : address(pool);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(boundRouter, boundEngine, boundClearinghouse, boundPool);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);

        address lifecycleBookCandidate = fault == LifecycleBookFault.NoCode ? address(0xB00C) : address(lifecycleBook);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidLifecycleBook.selector);
        new OrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(pletherOracle),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            lifecycleBookCandidate
        );
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_CloseSlippageFailurePreservesPosition() public {
        _startRecordingLogs();
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 0, 0.9e8, true);

        bytes[] memory pythData = _mockPythUpdateData(1.5e8);
        (IOrderRouterAccounting.PendingOrderView memory closeOrder,) = router.getPendingOrderView(2);
        vm.roll(uint256(closeOrder.commitBlock) + 1);
        router.executeOrder(2, pythData);

        address carolAccount = carol;
        (uint256 size,,,,,,) = engine.positions(carolAccount);
        assertGt(size, 0, "Close at bad price should have been rejected by slippage check");
    }

    function test_Constructor_ZeroPletherOracleReverts() public {
        _startRecordingLogs();
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        new OrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(0),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
    }

    function test_Constructor_LifecycleBookWithoutCodeReverts() public {
        _startRecordingLogs();
        _expectInvalidLifecycleBook(LifecycleBookFault.NoCode);
    }

    function test_Constructor_LifecycleBookRouterMismatchReverts() public {
        _startRecordingLogs();
        _expectInvalidLifecycleBook(LifecycleBookFault.Router);
    }

    function test_Constructor_LifecycleBookEngineMismatchReverts() public {
        _startRecordingLogs();
        _expectInvalidLifecycleBook(LifecycleBookFault.Engine);
    }

    function test_Constructor_LifecycleBookClearinghouseMismatchReverts() public {
        _startRecordingLogs();
        _expectInvalidLifecycleBook(LifecycleBookFault.Clearinghouse);
    }

    function test_Constructor_LifecycleBookPoolMismatchReverts() public {
        _startRecordingLogs();
        _expectInvalidLifecycleBook(LifecycleBookFault.Pool);
    }

    // stale order executes via executeOrder
    function test_StaleOrderExecutesViaExecuteOrder() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        address account = alice;
        uint64 commitId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 600);

        bytes[] memory priceData = _mockPythUpdateData();
        router.executeOrder(commitId, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Expired order must not execute via executeOrder");
    }

    // Regression: order commits should not require ETH
    function test_ZeroEthCommitAllowed() public {
        _startRecordingLogs();
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 1000e6, 1e8, false);

        assertEq(router.nextCommitId(), 2, "Commit should succeed without an ETH execution fee");
    }

    // close order allowed while paused
    function test_CloseOrderAllowedWhilePaused() public {
        _startRecordingLogs();
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;
        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Position should be open");

        routerAdmin.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.LONG, 1000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, size, 0, 0, true);

        routerAdmin.unpause();
        bytes[] memory closeData = _mockPythUpdateData();
        (IOrderRouterAccounting.PendingOrderView memory closeOrder,) = router.getPendingOrderView(2);
        vm.roll(uint256(closeOrder.commitBlock) + 1);
        router.executeOrder(2, closeData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Position should be fully closed");
    }

}
