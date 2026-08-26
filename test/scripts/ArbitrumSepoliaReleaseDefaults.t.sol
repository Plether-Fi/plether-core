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
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
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
        return RELEASE_SENIOR_SEED_USDC;
    }

    function defaultJuniorSeedUsdc() external pure returns (uint256) {
        return RELEASE_JUNIOR_SEED_USDC;
    }

    function verifyRedemptionMathSidecar(
        address redemptionMathSidecar
    ) external view {
        _verifyRedemptionMathSidecar(redemptionMathSidecar);
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

    function verifyInitialReleaseConfig(
        HousePool housePool,
        OrderRouter router
    ) external view {
        _verifyInitialReleaseConfig(housePool, router, OrderRouterAdmin(router.admin()));
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

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;

    function test_DeployScriptRiskDefaults_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();

        CfdTypes.RiskParams memory params = deployScript.riskParams();

        assertEq(params.vpiFactor, 0.01e18, "vpi factor");
        assertEq(deployScript.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(params.maxSkewRatio, 0.4e18, "max skew");
        assertEq(params.maintMarginBps, 10, "maintenance margin");
        assertEq(params.initMarginBps, 20, "initial margin");
        assertEq(params.fadMarginBps, 300, "fad margin");
        assertEq(params.baseCarryBps, 500, "base carry");
        assertEq(params.minBountyUsdc, 1e6, "min bounty");
        assertEq(params.bountyBps, 10, "bounty bps");
        assertEq(params.keeperShareBps, 5000, "keeper share bps");
        assertEq(params.protocolShareBps, 0, "protocol share bps");
    }

    function test_GenericCoreDefaultsRemainUnchangedOutsideReleaseWrappers() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        HousePool genericPool = new HousePool(address(usdc), address(engine), address(redemptionMathSidecar));

        assertEq(engine.executionFeeBps(), 4, "execution fee");
        assertEq(engine.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(engine.settlementBufferBps(), 25, "settlement buffer");
        assertEq(engine.fadRunwaySeconds(), 1 hours, "fad runway");
        assertEq(address(engine.terminalNavBook()), address(terminalNavBook), "terminal NAV book");
        assertEq(terminalNavBook.SIZE_QUANTUM(), 1e20, "position size quantum");
        assertEq(genericPool.maxSeniorExposureUsdc(), type(uint256).max, "generic maximum Senior exposure");
        assertEq(genericPool.maxSeniorShareBps(), 10_000, "generic maximum Senior share");

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        bool[] memory inversions = new bool[](1);

        MockPyth pyth = new MockPyth();
        PletherOracle oracle = new PletherOracle(
            address(engine), address(genericPool), address(pyth), feedIds, quantities, basePrices, inversions
        );
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterV2ExecutionSidecar executionSidecar = new OrderRouterV2ExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address expectedRouter = vm.computeCreateAddress(address(this), uint256(routerDependencyNonce) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(expectedRouter, address(engine), address(clearinghouse), address(genericPool));
        OrderRouterLiquidationBatchSidecar sidecar = new OrderRouterLiquidationBatchSidecar(expectedRouter);
        OrderRouter router = new OrderRouter(
            address(engine),
            address(0xCAFE),
            address(genericPool),
            address(oracle),
            address(sidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );

        assertEq(address(router), expectedRouter, "predicted Router CREATE address");
        assertEq(address(router.lifecycleBook()), address(lifecycleBook), "predeployed lifecycle book");
        assertEq(router.minOpenNotionalUsdc(), 100_000_000, "generic minimum opening notional");
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
        vm.etch(RELEASE_PYTH, address(pyth).code);
        PletherOracle oracle = new PletherOracle(
            address(engine), address(pool), RELEASE_PYTH, feedIds, quantities, basePrices, inversions
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

        assertEq(bootstrapScript.defaultSeniorSeedUsdc(), 10_000_000e6, "senior seed");
        assertEq(bootstrapScript.defaultJuniorSeedUsdc(), 10_000_000e6, "junior seed");
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

    function test_AsyncVaultReleaseDefaults_InitializeJuniorMaintenanceFeeAtProtocolTreasury() public {
        (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault) = _deployAsyncVaultPair();

        assertEq(seniorVault.maintenanceFeeAprBps(), 0, "Senior maintenance fee APR");
        assertEq(seniorVault.maintenanceFeeRecipient(), address(0), "Senior maintenance fee recipient");
        assertEq(juniorVault.maintenanceFeeAprBps(), 100, "Junior maintenance fee APR");
        assertEq(
            juniorVault.maintenanceFeeRecipient(),
            CfdEngine(address(pool.ENGINE())).protocolTreasury(),
            "Junior maintenance fee recipient"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0, "Junior pending maintenance fee shares");
        assertEq(juniorVault.accruedTotalSupply(), juniorVault.totalSupply(), "Junior effective supply");

        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        deployScript.verifyAsyncVaultPair(pool, seniorVault, juniorVault, usdc);
        bootstrapScript.verifyAsyncVaultPair(pool, address(usdc));
    }

    function test_DeploymentAndBootstrapRejectUnexpectedMaintenanceFeeRecipient() public {
        (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault) = _deployAsyncVaultPair();
        juniorVault.proposeMaintenanceFeeConfig(100, address(0xFEE));
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();

        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        vm.expectRevert(bytes("TrancheVault maintenance fee recipient mismatch"));
        deployScript.verifyAsyncVaultPair(pool, seniorVault, juniorVault, usdc);

        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        vm.expectRevert(bytes("TrancheVault maintenance fee recipient mismatch"));
        bootstrapScript.verifyAsyncVaultPair(pool, address(usdc));
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

    function test_ReleaseDeploymentStartsWithExactPoolAndRouterValuesWithoutProposals() public {
        vm.chainId(421_614);
        MockPyth pyth = new MockPyth();
        vm.etch(RELEASE_PYTH, address(pyth).code);
        vm.setEnv("TEST_PRIVATE_KEY", vm.toString(uint256(0xA11CE)));

        DeployPerpsArbitrumSepolia deployScript = new DeployPerpsArbitrumSepolia();
        DeployPerpsArbitrumSepolia.DeployedContracts memory deployed = deployScript.run();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        bootstrapScript.verifyInitialReleaseConfig(deployed.housePool, deployed.router);
        assertEq(deployed.housePool.maxSeniorExposureUsdc(), 40_000_000e6);
        assertEq(deployed.housePool.maxSeniorShareBps(), 8000);
        assertEq(deployed.router.minOpenNotionalUsdc(), 1000e6);
        assertEq(deployed.router.pletherOracle().adverseConfidenceMultiplierBps(), 2500);
        assertEq(deployed.housePool.poolConfigActivationTime(), 0);
        OrderRouterAdmin routerAdmin = OrderRouterAdmin(deployed.router.admin());
        assertEq(routerAdmin.routerConfigActivationTime(), 0);
        assertEq(deployed.housePool.TIMELOCK_DELAY(), 48 hours);
        assertEq(routerAdmin.TIMELOCK_DELAY(), 48 hours);

        address owner = vm.addr(0xA11CE);
        IHousePool.PoolConfig memory nextPoolConfig = IHousePool.PoolConfig({
            seniorRateBps: deployed.housePool.seniorRateBps(),
            markStalenessLimit: deployed.housePool.markStalenessLimit(),
            seniorFrozenLpFeeBps: deployed.housePool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: deployed.housePool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: 41_000_000e6,
            maxSeniorShareBps: 8000
        });
        vm.prank(owner);
        deployed.housePool.proposePoolConfig(nextPoolConfig);
        assertEq(deployed.housePool.poolConfigActivationTime(), block.timestamp + 48 hours);
        assertEq(deployed.housePool.maxSeniorExposureUsdc(), 40_000_000e6, "proposal changed live pool config");
        vm.expectRevert(bytes("Outstanding HousePool config proposal"));
        bootstrapScript.verifyInitialReleaseConfig(deployed.housePool, deployed.router);
        vm.prank(owner);
        deployed.housePool.cancelPoolConfigProposal();

        IOrderRouterAdminHost.RouterConfig memory nextRouterConfig = _activeRouterConfig(deployed.router);
        nextRouterConfig.minOpenNotionalUsdc = 999e6;
        vm.prank(owner);
        routerAdmin.proposeRouterConfig(nextRouterConfig);
        assertEq(routerAdmin.routerConfigActivationTime(), block.timestamp + 48 hours);
        assertEq(deployed.router.minOpenNotionalUsdc(), 1000e6, "proposal changed live Router config");
        vm.expectRevert(bytes("Outstanding Router config proposal"));
        bootstrapScript.verifyInitialReleaseConfig(deployed.housePool, deployed.router);
    }

    function _activeRouterConfig(
        OrderRouter router
    ) internal view returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config.maxOrderAge = router.maxOrderAge();
        config.orderExecutionStalenessLimit = router.pletherOracle().orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = router.pletherOracle().liquidationStalenessLimit();
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalUsdc = router.minOpenNotionalUsdc();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        config.maxOpenOrderExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        config.closeOrderExecutionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        config.positionProtectionCommitsEnabled = router.positionProtectionCommitsEnabled();
        config.positionProtectionTriggerBountyUsdc = router.positionProtectionTriggerBountyUsdc();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
    }

    function _deployAsyncVaultPair()
        internal
        returns (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault)
    {
        usdc = new MockUSDC();
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        HousePoolRedemptionMathSidecar redemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        pool = new HousePool(address(usdc), address(engine), address(redemptionMathSidecar));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "senior", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Junior", "junior", 100, engine.protocolTreasury()
        );
        pool.setJuniorVault(address(juniorVault));
    }

}
