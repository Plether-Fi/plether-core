// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {PletherOracle} from "@plether/perps/PletherOracle.sol";

import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterOracleConfigurationTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_RouterConfig_RejectsConfidenceThatCanConsumeWholePrice() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        uint256[3] memory ratios = [uint256(10_000), 4000, type(uint256).max];
        uint256[3] memory multipliers = [uint256(10_000), 30_000, type(uint256).max];
        for (uint256 i; i < ratios.length; i++) {
            config.basketMaxConfidenceRatioBps = ratios[i];
            config.adverseConfidenceMultiplierBps = multipliers[i];
            vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidConfidenceRatio.selector);
            routerAdmin.proposeRouterConfig(config);
            assertEq(routerAdmin.routerConfigActivationTime(), 0, "invalid proposal must not be staged");
        }
    }

    function test_RouterConfig_FinalizesStrictPositiveConfidenceBoundary() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 9999;
        config.adverseConfidenceMultiplierBps = 10_000;
        _setRouterConfig(config);
        assertEq(router.pletherOracle().basketMaxConfidenceRatioBps(), 9999);
        assertEq(router.pletherOracle().adverseConfidenceMultiplierBps(), 10_000);
    }

    function test_OracleConfigTimelock_RotatesPythBasket() public {
        _startRecordingLogs();
        MockPyth newPyth = new MockPyth();
        newPyth.setSynchronizeLegacyUniquePrices(true);
        bytes32[] memory newFeedIds = new bytes32[](2);
        uint256[] memory newWeights = new uint256[](2);
        uint256[] memory newBases = new uint256[](2);
        bool[] memory newInversions = new bool[](2);

        newFeedIds[0] = bytes32(uint256(101));
        newFeedIds[1] = bytes32(uint256(202));
        newWeights[0] = 0.7e18;
        newWeights[1] = 0.3e18;
        newBases[0] = 1e8;
        newBases[1] = 1e8;

        PletherOracle newOracle = new PletherOracle(
            address(engine), address(pool), address(newPyth), newFeedIds, newWeights, newBases, newInversions
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(newOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__TimelockNotReady.selector);
        routerAdmin.finalizeOracleConfig();

        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeOracleConfig();

        assertEq(address(router.pletherOracle().pyth()), address(newPyth), "Pyth endpoint should rotate after timelock");
        PletherOracle rotatedOracle = PletherOracle(address(router.pletherOracle()));
        assertEq(address(rotatedOracle), address(newOracle), "Oracle endpoint should rotate after timelock");
        assertEq(rotatedOracle.pythFeedIds(0), newFeedIds[0], "First feed id should rotate");
        assertEq(rotatedOracle.pythFeedIds(1), newFeedIds[1], "Second feed id should rotate");
        assertEq(rotatedOracle.quantities(0), newWeights[0], "First weight should rotate");
        assertEq(rotatedOracle.quantities(1), newWeights[1], "Second weight should rotate");
    }

    function test_OracleConfigTimelock_RejectsOracleForDifferentEngine() public {
        _startRecordingLogs();
        PletherOracle wrongEngineOracle = new PletherOracle(
            address(0xE111), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(wrongEngineOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        routerAdmin.finalizeOracleConfig();
    }

    function test_OracleConfigTimelock_RejectsOracleForDifferentPool() public {
        _startRecordingLogs();
        PletherOracle wrongPoolOracle = new PletherOracle(
            address(engine), address(0xB001), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(wrongPoolOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        routerAdmin.finalizeOracleConfig();
    }

    function test_OracleRotation_PreservesAllSixNondefaultPolicyFields() public {
        IPletherOracle.OracleConfig memory policy = _nondefaultPolicy();
        _finalizePolicy(policy);
        PletherOracle candidate = _newOracle();
        _proposeRotation(address(candidate));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        uint64 versionBefore = routerAdmin.activeConfigVersion();

        vm.expectCall(address(candidate), abi.encodeCall(IPletherOracle.applyConfig, (policy)));
        uint256 gasBefore = gasleft();
        routerAdmin.finalizeOracleConfig();
        uint256 rotationGas = gasBefore - gasleft();

        assertEq(address(router.pletherOracle()), address(candidate));
        _assertPolicy(candidate, policy);
        _assertPolicy(pletherOracle, policy);
        assertEq(routerAdmin.activeConfigVersion(), versionBefore + 1);
        assertEq(routerAdmin.oracleConfigActivationTime(), 0);
        assertEq(routerAdmin.getPendingOracleConfig().pletherOracle, address(0));
        emit log_named_uint("Oracle rotation finalization gas", rotationGas);
    }

    function test_OracleRotation_UsesPolicyFinalizedDuringOracleTimelock() public {
        IPletherOracle.OracleConfig memory initialPolicy = _nondefaultPolicy();
        _finalizePolicy(initialPolicy);
        PletherOracle candidate = _newOracle();
        IPletherOracle.OracleConfig memory latestPolicy = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 81,
            liquidationStalenessLimit: 41,
            basketMaxConfidenceRatioBps: 271,
            orderSettlementWindow: 49,
            maxComponentPublishTimeDivergence: 7,
            adverseConfidenceMultiplierBps: 15_100
        });
        routerAdmin.proposeRouterConfig(_routerConfigWithPolicy(latestPolicy));
        vm.warp(block.timestamp + 1 hours);
        _proposeRotation(address(candidate));
        uint256 oracleActivation = routerAdmin.oracleConfigActivationTime();
        vm.warp(routerAdmin.routerConfigActivationTime());
        routerAdmin.finalizeRouterConfig();
        assertLt(block.timestamp, oracleActivation);
        _assertPolicy(pletherOracle, latestPolicy);

        vm.warp(oracleActivation);
        routerAdmin.finalizeOracleConfig();

        _assertPolicy(candidate, latestPolicy);
        assertEq(address(router.pletherOracle()), address(candidate));
    }

    function test_OracleRotation_RejectingCandidatePreservesProposalAndCanRetry() public {
        IPletherOracle.OracleConfig memory policy = _nondefaultPolicy();
        _finalizePolicy(policy);
        PletherOracle candidate = _newOracle();
        IPletherOracle.OracleConfig memory candidateBefore = _readPolicy(candidate);
        _proposeRotation(address(candidate));
        uint256 activationTime = routerAdmin.oracleConfigActivationTime();
        vm.warp(activationTime);
        uint64 versionBefore = routerAdmin.activeConfigVersion();
        bytes memory failure = abi.encodeWithSelector(IPletherOracle.PletherOracle__InvalidSettlementConfig.selector);
        vm.mockCallRevert(address(candidate), abi.encodeWithSelector(IPletherOracle.applyConfig.selector), failure);

        vm.expectRevert(failure);
        routerAdmin.finalizeOracleConfig();

        _assertRotationUnchanged(address(candidate), activationTime, versionBefore, policy);
        _assertPolicy(candidate, candidateBefore);
        vm.clearMockedCalls();
        routerAdmin.finalizeOracleConfig();
        _assertPolicy(candidate, policy);
        assertEq(address(router.pletherOracle()), address(candidate));
    }

    function test_OracleRotation_IgnoringCandidateCannotResetPolicy() public {
        IPletherOracle.OracleConfig memory policy = _nondefaultPolicy();
        _finalizePolicy(policy);
        PletherOracle candidate = _newOracle();
        IPletherOracle.OracleConfig memory candidateBefore = _readPolicy(candidate);
        _proposeRotation(address(candidate));
        uint256 activationTime = routerAdmin.oracleConfigActivationTime();
        vm.warp(activationTime);
        uint64 versionBefore = routerAdmin.activeConfigVersion();
        vm.mockCall(address(candidate), abi.encodeWithSelector(IPletherOracle.applyConfig.selector), bytes(""));

        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        routerAdmin.finalizeOracleConfig();

        _assertRotationUnchanged(address(candidate), activationTime, versionBefore, policy);
        _assertPolicy(candidate, candidateBefore);
    }

    function test_OracleRotation_EveryPolicyFieldMustMatchAndCandidateWritesRollBack() public {
        IPletherOracle.OracleConfig memory policy = _nondefaultPolicy();
        _finalizePolicy(policy);
        PletherOracle candidate = _newOracle();
        IPletherOracle.OracleConfig memory candidateBefore = _readPolicy(candidate);
        _proposeRotation(address(candidate));
        uint256 activationTime = routerAdmin.oracleConfigActivationTime();
        vm.warp(activationTime);
        uint64 versionBefore = routerAdmin.activeConfigVersion();
        bytes4[6] memory getters = [
            IPletherOracle.orderExecutionStalenessLimit.selector,
            IPletherOracle.liquidationStalenessLimit.selector,
            IPletherOracle.basketMaxConfidenceRatioBps.selector,
            IPletherOracle.orderSettlementWindow.selector,
            IPletherOracle.maxComponentPublishTimeDivergence.selector,
            IPletherOracle.adverseConfidenceMultiplierBps.selector
        ];

        for (uint256 i; i < getters.length; ++i) {
            vm.mockCall(address(candidate), abi.encodeWithSelector(getters[i]), abi.encode(type(uint256).max));
            vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
            routerAdmin.finalizeOracleConfig();
            vm.clearMockedCalls();
            _assertRotationUnchanged(address(candidate), activationTime, versionBefore, policy);
            _assertPolicy(candidate, candidateBefore);
        }
    }

    function test_OracleRotation_SameAddressPreservesPolicyAndAdvancesVersion() public {
        IPletherOracle.OracleConfig memory policy = _nondefaultPolicy();
        _finalizePolicy(policy);
        _proposeRotation(address(pletherOracle));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        uint64 versionBefore = routerAdmin.activeConfigVersion();

        routerAdmin.finalizeOracleConfig();

        _assertPolicy(pletherOracle, policy);
        assertEq(address(router.pletherOracle()), address(pletherOracle));
        assertEq(routerAdmin.activeConfigVersion(), versionBefore + 1);
    }

    function test_OracleRotation_RequiresRouterAdminAndExactDelegateContext() public {
        PletherOracle candidate = _newOracle();
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(candidate)});
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        vm.prank(alice);
        router.applyOracleConfig(config);

        address sidecar = router.liquidationBatchSidecar();
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        IOrderRouterAdminHost(sidecar).applyOracleConfig(config);

        (bool success, bytes memory result) =
            sidecar.delegatecall(abi.encodeCall(IOrderRouterAdminHost.applyOracleConfig, (config)));
        assertFalse(success, "a foreign delegate context must not apply oracle policy");
        assertEq(result, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__Unauthorized.selector));
        assertEq(address(router.pletherOracle()), address(pletherOracle));
    }

    function test_OracleRotation_InvalidatesConfigPinnedOrderWithAuthenticatedReceipt() public {
        _startRecordingLogs();
        // Tuesday plus the 48-hour timelock remains outside the FX weekend close-only window.
        vm.warp(1_700_000_000);
        PletherOracle candidate = _newOracle();
        _proposeRotation(address(candidate));
        uint256 activationTime = routerAdmin.oracleConfigActivationTime();
        vm.warp(activationTime - 1);
        IOrderLifecycleBook book = IOrderLifecycleBook(address(router.lifecycleBook()));
        OrderV3Types.OrderRequest memory request;
        request.clientOrderId = bytes32("oracle-rotation");
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = 10_000e18;
        request.marginDelta = 1000e6;
        request.targetPrice = 1;
        request.bounds.submitBy = uint64(block.timestamp + 60);
        request.bounds.executionWindowSeconds = 60;
        request.bounds.allowedExecutionModes = 7;
        request.bounds.expectedConfigHash = book.currentExecutionConfigHash();
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;
        vm.prank(alice);
        uint64 orderId = router.commitOrder(request);
        uint256 bounty = book.pendingIntent(orderId).executionBountyUsdc;
        uint256 keeperBefore = _settlementBalance(bob);
        uint256 updatesBefore = mockPyth.updatePriceFeedsCallCount();
        uint256 parsesBefore = mockPyth.parseUniqueCallCount();
        vm.warp(activationTime);
        routerAdmin.finalizeOracleConfig();

        vm.prank(bob);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, new bytes[](0));

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.ConfigMismatch));
        assertEq(mockPyth.updatePriceFeedsCallCount(), updatesBefore);
        assertEq(mockPyth.parseUniqueCallCount(), parsesBefore);
        assertEq(_settlementBalance(bob), keeperBefore + bounty);
        assertEq(router.pendingOrderCounts(alice), 0);
        assertEq(router.accountHeadOrderId(alice), 0);
        assertEq(_remainingCommittedMargin(orderId), 0);
        assertEq(book.pendingIntent(orderId).account, address(0));
        (uint256 positionSize,,,,,,) = engine.positions(alice);
        assertEq(positionSize, 0);
        OrderV3Types.CompactOutcome memory outcome = _verifiedOutcome(book, orderId);
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.ConfigMismatch));
        assertEq(outcome.expectedConfigHash, request.bounds.expectedConfigHash);
        assertEq(outcome.observedConfigHash, book.currentExecutionConfigHash());
        assertTrue(outcome.expectedConfigHash != outcome.observedConfigHash);
        assertEq(uint8(outcome.priceSource), uint8(OrderV3Types.PriceSource.None));
        assertEq(outcome.executionPrice, 0);
        assertEq(outcome.executor, bob);
        assertEq(outcome.bountyUsdc, bounty);
    }

    function _newOracle() private returns (PletherOracle) {
        return
            new PletherOracle(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
    }

    function _proposeRotation(
        address candidate
    ) private {
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig({pletherOracle: candidate}));
    }

    function _nondefaultPolicy() private pure returns (IPletherOracle.OracleConfig memory policy) {
        policy = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: 79,
            liquidationStalenessLimit: 43,
            basketMaxConfidenceRatioBps: 137,
            orderSettlementWindow: 47,
            maxComponentPublishTimeDivergence: 9,
            adverseConfidenceMultiplierBps: 12_345
        });
    }

    function _finalizePolicy(
        IPletherOracle.OracleConfig memory policy
    ) private {
        _setRouterConfig(_routerConfigWithPolicy(policy));
    }

    function _routerConfigWithPolicy(
        IPletherOracle.OracleConfig memory policy
    ) private view returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config = _routerConfig();
        config.orderExecutionStalenessLimit = policy.orderExecutionStalenessLimit;
        config.liquidationStalenessLimit = policy.liquidationStalenessLimit;
        config.basketMaxConfidenceRatioBps = policy.basketMaxConfidenceRatioBps;
        config.orderSettlementWindow = policy.orderSettlementWindow;
        config.maxComponentPublishTimeDivergence = policy.maxComponentPublishTimeDivergence;
        config.adverseConfidenceMultiplierBps = policy.adverseConfidenceMultiplierBps;
    }

    function _readPolicy(
        IPletherOracle oracle
    ) private view returns (IPletherOracle.OracleConfig memory policy) {
        policy = IPletherOracle.OracleConfig({
            orderExecutionStalenessLimit: oracle.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: oracle.liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: oracle.basketMaxConfidenceRatioBps(),
            orderSettlementWindow: oracle.orderSettlementWindow(),
            maxComponentPublishTimeDivergence: oracle.maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: oracle.adverseConfidenceMultiplierBps()
        });
    }

    function _assertPolicy(
        IPletherOracle oracle,
        IPletherOracle.OracleConfig memory expected
    ) private view {
        assertEq(oracle.orderExecutionStalenessLimit(), expected.orderExecutionStalenessLimit);
        assertEq(oracle.liquidationStalenessLimit(), expected.liquidationStalenessLimit);
        assertEq(oracle.basketMaxConfidenceRatioBps(), expected.basketMaxConfidenceRatioBps);
        assertEq(oracle.orderSettlementWindow(), expected.orderSettlementWindow);
        assertEq(oracle.maxComponentPublishTimeDivergence(), expected.maxComponentPublishTimeDivergence);
        assertEq(oracle.adverseConfidenceMultiplierBps(), expected.adverseConfidenceMultiplierBps);
    }

    function _assertRotationUnchanged(
        address candidate,
        uint256 activationTime,
        uint64 version,
        IPletherOracle.OracleConfig memory activePolicy
    ) private view {
        assertEq(address(router.pletherOracle()), address(pletherOracle));
        assertEq(routerAdmin.getPendingOracleConfig().pletherOracle, candidate);
        assertEq(routerAdmin.oracleConfigActivationTime(), activationTime);
        assertEq(routerAdmin.activeConfigVersion(), version);
        _assertPolicy(pletherOracle, activePolicy);
    }

}
