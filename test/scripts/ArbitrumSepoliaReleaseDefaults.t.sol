// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BootstrapPerpsArbitrumSepolia} from "../../script/BootstrapPerpsArbitrumSepolia.s.sol";
import {DeployPerpsArbitrumSepolia, MockUSDC} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderRouterV2ExecutionSidecar} from "@plether/perps/OrderRouterV2ExecutionSidecar.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPerpsArbitrumSepoliaHarness is DeployPerpsArbitrumSepolia {

    function riskParams() external pure returns (CfdTypes.RiskParams memory) {
        return _riskParams();
    }

    function frozenCloseSpreadBps() external pure returns (uint256) {
        return FROZEN_CLOSE_SPREAD_BPS;
    }

    function verifyAsyncVaultPair(
        HousePool housePool,
        TrancheVault seniorVault,
        TrancheVault juniorVault,
        MockUSDC usdc
    ) external view {
        _verifyAsyncVaultPair(housePool, seniorVault, juniorVault, usdc);
    }

    function verifyPositionProtectionBook(
        OrderRouter router,
        CfdEngine engine
    ) external view returns (address book) {
        return _verifyPositionProtectionBook(router, engine);
    }

    function verifyV2OrderStack(
        CfdEngine engine,
        MarginClearinghouse clearinghouse,
        HousePool housePool,
        CfdOrderPolicyEvaluator orderPolicyEvaluator,
        OrderRouterV2ExecutionSidecar orderExecutionSidecar,
        OrderRouter router
    ) external view returns (OrderLifecycleBook lifecycleBook) {
        return
            _verifyV2OrderStack(engine, clearinghouse, housePool, orderPolicyEvaluator, orderExecutionSidecar, router);
    }

}

contract BootstrapPerpsArbitrumSepoliaHarness is BootstrapPerpsArbitrumSepolia {

    function defaultSeniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_SENIOR_SEED_USDC;
    }

    function defaultJuniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_JUNIOR_SEED_USDC;
    }

    function validateSeniorLimits(
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) external pure {
        _validateSeniorLimits(maxSeniorExposureUsdc, maxSeniorShareBps);
    }

    function deployConfigTestPool(
        address usdc
    ) external returns (HousePool) {
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        return new HousePool(usdc, address(0xE11E), address(redemptionMathSidecar));
    }

    function verifyRedemptionMathSidecar(
        address redemptionMathSidecar
    ) external view {
        _verifyRedemptionMathSidecar(redemptionMathSidecar);
    }

    function configureSeniorLimits(
        HousePool housePool,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) external returns (bool) {
        return _configureSeniorLimits(housePool, maxSeniorExposureUsdc, maxSeniorShareBps);
    }

    function verifyTerminalNavBook(
        HousePool housePool
    ) external view {
        _verifyTerminalNavBook(housePool);
    }

    function verifyRouterWiring(
        HousePool housePool,
        OrderRouter router
    ) external view {
        _verifyRouterWiring(housePool, router);
    }

    function verifyAsyncVaultPair(
        HousePool housePool,
        address usdc
    ) external view {
        _verifyAsyncVaultPair(housePool, usdc);
    }

    function validateGuardian(
        address guardian
    ) external pure {
        _validateGuardian(guardian);
    }

    function verifyEmergencyCoordinator(
        HousePool housePool,
        OrderRouterAdmin routerAdmin,
        EmergencyPauseCoordinator coordinator
    ) external view {
        _verifyEmergencyCoordinator(housePool, routerAdmin, coordinator);
    }

    function configureGuardian(
        EmergencyPauseCoordinator coordinator,
        address guardian,
        address broadcaster
    ) external {
        _configureGuardian(coordinator, guardian, broadcaster);
    }

    function activateTrading(
        HousePool housePool,
        OrderRouterAdmin routerAdmin,
        EmergencyPauseCoordinator coordinator
    ) external {
        _activateTrading(housePool, routerAdmin, coordinator, true);
    }

}

contract MockEmergencyAdmin {

    address public pauser;
    bool public paused;
    uint64 public riskOffOrderCutoff;

    function setPauser(
        address newPauser
    ) external {
        pauser = newPauser;
    }

    function pause() external {
        paused = true;
        riskOffOrderCutoff = 1;
    }

    function unpause() external {
        paused = false;
    }

}

contract MockWrongRedemptionMathSidecar {

    function implementationId() external pure returns (bytes32) {
        return keccak256("wrong-generation");
    }

}

contract MockBootstrapHousePoolAdmin is MockEmergencyAdmin {

    bool public isTradingActive;
    bool public lpEpochSettlementPaused;
    bool public seniorSeedInitialized = true;
    bool public juniorSeedInitialized = true;

    function pauseLpEpochSettlement() external {
        lpEpochSettlementPaused = true;
    }

    function unpauseLpEpochSettlement() external {
        lpEpochSettlementPaused = false;
    }

    function activateTrading() external {
        isTradingActive = true;
    }

}

contract ArbitrumSepoliaReleaseDefaultsTest is Test {

    function test_DeployScriptRiskDefaults_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();

        CfdTypes.RiskParams memory params = deployScript.riskParams();

        assertEq(params.vpiFactor, 0.005e18, "vpi factor");
        assertEq(deployScript.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(params.maxSkewRatio, 0.4e18, "max skew");
        assertEq(params.maintMarginBps, 30, "maintenance margin");
        assertEq(params.initMarginBps, 45, "initial margin");
        assertEq(params.fadMarginBps, 300, "fad margin");
        assertEq(params.baseCarryBps, 500, "base carry");
        assertEq(params.minBountyUsdc, 1e6, "min bounty");
        assertEq(params.bountyBps, 10, "bounty bps");
        assertEq(params.keeperShareBps, 5000, "keeper share bps");
        assertEq(params.protocolShareBps, 0, "protocol share bps");
    }

    function test_CoreDefaultConfigs_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));

        assertEq(engine.executionFeeBps(), 4, "execution fee");
        assertEq(engine.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(engine.fadRunwaySeconds(), 1 hours, "fad runway");
        assertEq(address(engine.terminalNavBook()), address(terminalNavBook), "terminal NAV book");
        assertEq(terminalNavBook.SIZE_QUANTUM(), 1e20, "position size quantum");

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        bool[] memory inversions = new bool[](1);

        MockPyth pyth = new MockPyth();
        PletherOracle oracle = new PletherOracle(
            address(engine), address(0xBEEF), address(pyth), feedIds, quantities, basePrices, inversions
        );
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterV2ExecutionSidecar executionSidecar = new OrderRouterV2ExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address expectedRouter = vm.computeCreateAddress(address(this), uint256(routerDependencyNonce) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(expectedRouter, address(engine), address(clearinghouse), address(0xBEEF));
        OrderRouterLiquidationBatchSidecar sidecar = new OrderRouterLiquidationBatchSidecar(expectedRouter);
        OrderRouter router = new OrderRouter(
            address(engine),
            address(0xCAFE),
            address(0xBEEF),
            address(oracle),
            address(sidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );

        assertEq(address(router), expectedRouter, "predicted Router CREATE address");
        assertEq(address(router.lifecycleBook()), address(lifecycleBook), "predeployed lifecycle book");
        assertEq(oracle.basketMaxConfidenceRatioBps(), 10, "basket confidence ratio");
        assertEq(oracle.adverseConfidenceMultiplierBps(), 2000, "adverse confidence multiplier");
        assertFalse(router.positionProtectionCommitsEnabled(), "position protection disabled");
        assertEq(router.positionProtectionTriggerBountyUsdc(), 200_000, "position protection trigger bounty");
        assertEq(router.closeOrderExecutionBountyUsdc(), 200_000, "position protection close bounty");
    }

    function test_DeploymentGuardsAcceptDistinctCanonicalPositionProtectionBookAndBoundSidecar() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlementSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlementSidecar), address(engineAdmin));
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        HousePool pool = new HousePool(address(usdc), address(engine), address(redemptionMathSidecar));
        engine.setPool(address(pool));

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        bool[] memory inversions = new bool[](1);
        MockPyth pyth = new MockPyth();
        PletherOracle oracle = new PletherOracle(
            address(engine), address(pool), address(pyth), feedIds, quantities, basePrices, inversions
        );
        CfdEngineLens engineLens = new CfdEngineLens(address(engine));
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterV2ExecutionSidecar executionSidecar = new OrderRouterV2ExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address expectedRouter = vm.computeCreateAddress(address(this), uint256(routerDependencyNonce) + 2);
        OrderLifecycleBook predeployedLifecycleBook =
            new OrderLifecycleBook(expectedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar sidecar = new OrderRouterLiquidationBatchSidecar(expectedRouter);
        OrderRouter router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(oracle),
            address(sidecar),
            address(evaluator),
            address(executionSidecar),
            address(predeployedLifecycleBook)
        );
        engine.setOrderRouter(address(router));
        clearinghouse.setEngine(address(engine));

        address book = deployScript.verifyPositionProtectionBook(router, engine);
        OrderLifecycleBook lifecycleBook =
            deployScript.verifyV2OrderStack(engine, clearinghouse, pool, evaluator, executionSidecar, router);
        assertEq(address(router), expectedRouter, "predicted Router CREATE address");
        assertEq(book, address(router.positionProtectionBook()), "position-protection book discovery");
        assertEq(address(lifecycleBook), address(router.lifecycleBook()), "lifecycle-book discovery");
        assertEq(address(lifecycleBook), address(predeployedLifecycleBook), "predeployed lifecycle-book binding");
        assertEq(router.liquidationBatchSidecar(), address(sidecar), "liquidation batch sidecar discovery");
        assertEq(sidecar.ROUTER(), address(router), "liquidation batch sidecar Router binding");
        assertNotEq(address(sidecar), book, "sidecar and position-protection book must be distinct");
        bootstrapScript.verifyRouterWiring(pool, router);
    }

    function test_DeploymentGuardsAcceptCanonicalV2OrderStackAndRejectMixedPolicyModule() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));

        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlementSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlementSidecar), address(engineAdmin));

        HousePool housePool =
            new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));
        engine.setPool(address(housePool));
        MockPyth pyth = new MockPyth();
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        PletherOracle oracle = new PletherOracle(
            address(engine), address(housePool), address(pyth), feedIds, quantities, basePrices, new bool[](1)
        );

        CfdEngineLens engineLens = new CfdEngineLens(address(engine));
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterV2ExecutionSidecar executionSidecar = new OrderRouterV2ExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address expectedRouter = vm.computeCreateAddress(address(this), uint256(routerDependencyNonce) + 2);
        OrderLifecycleBook predeployedLifecycleBook =
            new OrderLifecycleBook(expectedRouter, address(engine), address(clearinghouse), address(housePool));
        OrderRouterLiquidationBatchSidecar sidecar = new OrderRouterLiquidationBatchSidecar(expectedRouter);
        OrderRouter router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(housePool),
            address(oracle),
            address(sidecar),
            address(evaluator),
            address(executionSidecar),
            address(predeployedLifecycleBook)
        );
        assertEq(address(router), expectedRouter, "predicted Router CREATE address");
        engine.setOrderRouter(address(router));

        vm.expectRevert(bytes("Clearinghouse Engine mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, evaluator, executionSidecar, router);
        vm.expectRevert(bytes("Clearinghouse Engine mismatch"));
        bootstrapScript.verifyRouterWiring(housePool, router);

        clearinghouse.setEngine(address(engine));

        OrderLifecycleBook lifecycleBook =
            deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, evaluator, executionSidecar, router);
        address protectionBook = deployScript.verifyPositionProtectionBook(router, engine);
        bootstrapScript.verifyRouterWiring(housePool, router);
        assertEq(address(lifecycleBook), address(router.lifecycleBook()), "predeployed lifecycle book");
        assertEq(address(lifecycleBook), address(predeployedLifecycleBook), "lifecycle-book binding");
        assertEq(protectionBook, address(router.positionProtectionBook()), "Router-created protection book");
        assertEq(router.liquidationBatchSidecar(), address(sidecar), "prebound liquidation sidecar");
        assertNotEq(lifecycleBook.currentExecutionConfigHash(), bytes32(0), "execution config hash");

        HousePool wrongEngineHousePool =
            new HousePool(address(usdc), address(0xE11E), address(new HousePoolRedemptionMathSidecar()));
        vm.mockCall(address(engine), abi.encodeWithSignature("pool()"), abi.encode(address(wrongEngineHousePool)));
        vm.expectRevert(bytes("HousePool Engine mismatch"));
        deployScript.verifyV2OrderStack(
            engine, clearinghouse, wrongEngineHousePool, evaluator, executionSidecar, router
        );
        vm.clearMockedCalls();

        vm.mockCall(address(engine), abi.encodeWithSignature("clearinghouse()"), abi.encode(address(0xC1EA)));
        vm.expectRevert(bytes("Engine Clearinghouse mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, evaluator, executionSidecar, router);
        vm.clearMockedCalls();

        HousePool wrongHousePool =
            new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));
        vm.expectRevert(bytes("Engine HousePool mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, wrongHousePool, evaluator, executionSidecar, router);
        vm.expectRevert(bytes("Engine HousePool mismatch"));
        bootstrapScript.verifyRouterWiring(wrongHousePool, router);

        MockUSDC wrongUsdc = new MockUSDC();
        vm.mockCall(address(engine), abi.encodeWithSignature("USDC()"), abi.encode(address(wrongUsdc)));
        vm.expectRevert(bytes("Engine settlement asset mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, evaluator, executionSidecar, router);
        vm.expectRevert(bytes("Engine settlement asset mismatch"));
        bootstrapScript.verifyRouterWiring(housePool, router);
        vm.clearMockedCalls();

        vm.mockCall(
            address(clearinghouse), abi.encodeWithSignature("settlementAsset()"), abi.encode(address(wrongUsdc))
        );
        vm.expectRevert(bytes("Clearinghouse settlement asset mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, evaluator, executionSidecar, router);
        vm.expectRevert(bytes("Clearinghouse settlement asset mismatch"));
        bootstrapScript.verifyRouterWiring(housePool, router);
        vm.clearMockedCalls();

        CfdOrderPolicyEvaluator wrongEvaluator = new CfdOrderPolicyEvaluator();
        vm.expectRevert(bytes("OrderRouter policy evaluator mismatch"));
        deployScript.verifyV2OrderStack(engine, clearinghouse, housePool, wrongEvaluator, executionSidecar, router);

        vm.etch(address(evaluator), bytes(""));
        vm.expectRevert(bytes("Order policy evaluator has no code"));
        bootstrapScript.verifyRouterWiring(housePool, router);
    }

    function test_BootstrapDefaults_MatchArbitrumSepoliaReleaseSeeds() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        assertEq(bootstrapScript.defaultSeniorSeedUsdc(), 50_000_000e6, "senior seed");
        assertEq(bootstrapScript.defaultJuniorSeedUsdc(), 50_000_000e6, "junior seed");
    }

    function test_DeploymentUsesExpectedRedemptionMathSidecarAndSettlementStartsLive() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();

        bootstrapScript.verifyRedemptionMathSidecar(address(redemptionMathSidecar));
        HousePool pool = new HousePool(address(usdc), address(0xE11E), address(redemptionMathSidecar));

        assertGt(address(redemptionMathSidecar).code.length, 0, "redemption math sidecar code");
        assertEq(
            redemptionMathSidecar.implementationId(),
            keccak256("Plether.HousePoolRedemptionMathSidecar.v1"),
            "redemption math sidecar ID"
        );
        assertFalse(pool.lpEpochSettlementPaused(), "LP epoch settlement starts paused");
    }

    function test_BootstrapRejectsMissingRedemptionMathSidecarOnRerun() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        vm.expectRevert(bytes("PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR is zero"));
        bootstrapScript.verifyRedemptionMathSidecar(address(0));

        vm.expectRevert(bytes("HousePool redemption math sidecar has no code"));
        bootstrapScript.verifyRedemptionMathSidecar(address(0xBEEF));

        MockWrongRedemptionMathSidecar wrongSidecar = new MockWrongRedemptionMathSidecar();
        vm.expectRevert(bytes("HousePool redemption math sidecar ID mismatch"));
        bootstrapScript.verifyRedemptionMathSidecar(address(wrongSidecar));
    }

    function test_BootstrapRequiresNonzeroEmergencyGuardian() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        bootstrapScript.validateGuardian(address(0xBEEF));
        vm.expectRevert(bytes("PERPS_GUARDIAN is zero"));
        bootstrapScript.validateGuardian(address(0));
    }

    function test_BootstrapVerifiesSharedCoordinatorAndRotatesGuardianIdempotently() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockEmergencyAdmin routerAdmin = new MockEmergencyAdmin();
        MockBootstrapHousePoolAdmin housePool = new MockBootstrapHousePoolAdmin();
        EmergencyPauseCoordinator coordinator =
            new EmergencyPauseCoordinator(address(routerAdmin), address(housePool), address(bootstrapScript));

        routerAdmin.setPauser(address(coordinator));
        housePool.setPauser(address(coordinator));
        bootstrapScript.verifyEmergencyCoordinator(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );

        address guardian = address(0xBEEF);
        bootstrapScript.configureGuardian(coordinator, guardian, address(bootstrapScript));
        bootstrapScript.configureGuardian(coordinator, guardian, address(0xBAD));
        assertEq(coordinator.guardian(), guardian, "matching rerun must not require owner authority");
    }

    function test_BootstrapRejectsPartialCoordinatorPauserBinding() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockEmergencyAdmin routerAdmin = new MockEmergencyAdmin();
        MockBootstrapHousePoolAdmin housePool = new MockBootstrapHousePoolAdmin();
        EmergencyPauseCoordinator coordinator =
            new EmergencyPauseCoordinator(address(routerAdmin), address(housePool), address(this));

        routerAdmin.setPauser(address(coordinator));
        vm.expectRevert(bytes("HousePool pauser is not emergency coordinator"));
        bootstrapScript.verifyEmergencyCoordinator(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );
    }

    function test_BootstrapRejectsCoordinatorBoundToAnotherPool() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockEmergencyAdmin routerAdmin = new MockEmergencyAdmin();
        MockBootstrapHousePoolAdmin housePool = new MockBootstrapHousePoolAdmin();
        MockBootstrapHousePoolAdmin otherHousePool = new MockBootstrapHousePoolAdmin();
        EmergencyPauseCoordinator coordinator =
            new EmergencyPauseCoordinator(address(routerAdmin), address(otherHousePool), address(this));

        routerAdmin.setPauser(address(coordinator));
        housePool.setPauser(address(coordinator));
        vm.expectRevert(bytes("Emergency HousePool mismatch"));
        bootstrapScript.verifyEmergencyCoordinator(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );
    }

    function test_BootstrapRefusesTradingActivationWithoutLiveGuardianOrWhilePaused() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockEmergencyAdmin routerAdmin = new MockEmergencyAdmin();
        MockBootstrapHousePoolAdmin housePool = new MockBootstrapHousePoolAdmin();
        EmergencyPauseCoordinator coordinator =
            new EmergencyPauseCoordinator(address(routerAdmin), address(housePool), address(this));
        routerAdmin.setPauser(address(coordinator));
        housePool.setPauser(address(coordinator));

        vm.expectRevert(bytes("Emergency guardian is disabled"));
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );

        coordinator.setGuardian(address(0xBEEF));
        routerAdmin.pause();
        vm.expectRevert(bytes("OrderRouterAdmin is paused"));
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );

        routerAdmin.unpause();
        housePool.pause();
        vm.expectRevert(bytes("HousePool is paused"));
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );

        housePool.unpause();
        housePool.pauseLpEpochSettlement();
        vm.expectRevert(bytes("LP epoch settlement is paused"));
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );

        housePool.unpauseLpEpochSettlement();
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );
        assertTrue(housePool.isTradingActive());

        housePool.pauseLpEpochSettlement();
        bootstrapScript.activateTrading(
            HousePool(address(housePool)), OrderRouterAdmin(address(routerAdmin)), coordinator
        );
        assertTrue(housePool.lpEpochSettlementPaused(), "bootstrap rerun must not release settlement hold");
    }

    function test_DeploymentGuardsAcceptCanonicalRequestWindowAcrossCutoffs() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault) = _deployAsyncVaultPair();

        uint256 boundary = 10 hours;
        uint256[4] memory timestamps = [boundary - 301 seconds, boundary - 300 seconds, boundary, boundary + 55 minutes];
        for (uint256 i; i < timestamps.length; ++i) {
            vm.warp(timestamps[i]);
            deployScript.verifyAsyncVaultPair(pool, seniorVault, juniorVault, usdc);
            bootstrapScript.verifyAsyncVaultPair(pool, address(usdc));
        }
    }

    function test_BootstrapRejectsStackWithoutTerminalNavBook() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        HousePool pool = new HousePool(address(usdc), address(engine), address(redemptionMathSidecar));

        vm.expectRevert(bytes("TerminalNavBookV2 is not wired"));
        bootstrapScript.verifyTerminalNavBook(pool);

        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));
        bootstrapScript.verifyTerminalNavBook(pool);
    }

    function test_BootstrapRequiresFiniteExplicitSeniorLimits() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        bootstrapScript.validateSeniorLimits(100_000_000e6, 5000);
        bootstrapScript.validateSeniorLimits(0, 0);

        vm.expectRevert(bytes("MAX_SENIOR_EXPOSURE_USDC must be finite"));
        bootstrapScript.validateSeniorLimits(type(uint256).max, 5000);

        vm.expectRevert(bytes("MAX_SENIOR_SHARE_BPS must be below 10000"));
        bootstrapScript.validateSeniorLimits(100_000_000e6, 10_000);
    }

    function test_BootstrapSeniorLimitsUseTwoRunProposalAndFinalizeFlow() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        HousePool pool = bootstrapScript.deployConfigTestPool(address(usdc));
        uint256 maxExposure = 100_000_000e6;
        uint256 maxShareBps = 6000;

        assertFalse(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        uint256 activationTime = pool.poolConfigActivationTime();
        assertEq(activationTime, block.timestamp + pool.TIMELOCK_DELAY());
        (,,,, uint256 pendingMaxExposure, uint256 pendingMaxShareBps) = pool.pendingPoolConfig();
        assertEq(pendingMaxExposure, maxExposure);
        assertEq(pendingMaxShareBps, maxShareBps);

        assertFalse(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        assertEq(pool.poolConfigActivationTime(), activationTime, "matching rerun must not restart the timelock");

        vm.warp(activationTime);
        assertTrue(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        assertEq(pool.poolConfigActivationTime(), 0);
        assertEq(pool.maxSeniorExposureUsdc(), maxExposure);
        assertEq(pool.maxSeniorShareBps(), maxShareBps);

        assertTrue(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
    }

    function _deployAsyncVaultPair()
        internal
        returns (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault)
    {
        usdc = new MockUSDC();
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        pool = new HousePool(address(usdc), address(0xE11E), address(redemptionMathSidecar));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "senior");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "junior");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
    }

}
