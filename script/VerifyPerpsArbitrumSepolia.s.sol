// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
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
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";
import {SettlementMonitorLensSidecar} from "@plether/perps/SettlementMonitorLensSidecar.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import "forge-std/Script.sol";

/// @notice Read-only release verifier for the complete Arbitrum Sepolia Perps deployment graph.
/// @dev The script never starts a broadcast. `VERIFY_PHASE` must be one of deployed, seeded, or active.
contract VerifyPerpsArbitrumSepolia is Script {

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant RELEASE_SENIOR_SEED_USDC = 10_000_000e6;
    uint256 internal constant RELEASE_JUNIOR_SEED_USDC = 10_000_000e6;
    uint256 internal constant RELEASE_MAX_SENIOR_EXPOSURE_USDC = 40_000_000e6;
    uint256 internal constant RELEASE_MAX_SENIOR_SHARE_BPS = 8000;
    uint256 internal constant RELEASE_MIN_OPEN_NOTIONAL_USDC = 1000e6;
    uint256 internal constant RELEASE_ADVERSE_CONFIDENCE_MULTIPLIER_BPS = 2500;
    uint256 internal constant RELEASE_JUNIOR_MAINTENANCE_FEE_APR_BPS = 100;

    bytes32 internal constant PHASE_DEPLOYED = keccak256("deployed");
    bytes32 internal constant PHASE_SEEDED = keccak256("seeded");
    bytes32 internal constant PHASE_ACTIVE = keccak256("active");

    struct Deployment {
        address owner;
        address guardian;
        address usdc;
        MarginClearinghouse clearinghouse;
        CfdEngine engine;
        TerminalNavBookV2 terminalNavBook;
        address planner;
        CfdEngineSettlementSidecar settlementSidecar;
        CfdEngineAdmin engineAdmin;
        HousePoolRedemptionMathSidecar redemptionMathSidecar;
        HousePool housePool;
        TrancheVault seniorVault;
        TrancheVault juniorVault;
        CfdEngineAccountLens accountLens;
        CfdEngineLens engineLens;
        CfdOrderPolicyEvaluator orderPolicyEvaluator;
        OrderRouterV2ExecutionSidecar orderExecutionSidecar;
        OrderRouter router;
        OrderRouterLiquidationBatchSidecar liquidationBatchSidecar;
        OrderLifecycleBook lifecycleBook;
        PositionProtectionBook positionProtectionBook;
        PletherOracle oracle;
        OrderRouterAdmin routerAdmin;
        PerpsPublicLens publicLens;
        SettlementMonitorLens monitor;
        SettlementMonitorLensSidecar monitorSidecar;
        EmergencyPauseCoordinator emergencyCoordinator;
    }

    function run() external {
        require(block.chainid == 421_614, "Unexpected chain id");
        bytes32 phase = keccak256(bytes(vm.envString("VERIFY_PHASE")));
        require(phase == PHASE_DEPLOYED || phase == PHASE_SEEDED || phase == PHASE_ACTIVE, "Invalid VERIFY_PHASE");

        Deployment memory deployed = _loadDeployment();
        _verifyCode(deployed);
        _verifyCoreGraph(deployed);
        _verifyReleaseEconomics(deployed);
        _verifyGovernanceAndPhase(deployed, phase);

        console.log("Arbitrum Sepolia Perps release verification passed");
        console.log("Phase:", vm.envString("VERIFY_PHASE"));
        console.log("Engine:", address(deployed.engine));
        console.log("HousePool:", address(deployed.housePool));
        console.log("OrderRouter:", address(deployed.router));
        console.log("Junior effective supply:", deployed.juniorVault.accruedTotalSupply());
        console.log("Junior pending fee shares:", deployed.juniorVault.pendingMaintenanceFeeShares());
    }

    function _loadDeployment() internal view returns (Deployment memory deployed) {
        deployed.owner = vm.envAddress("PERPS_OWNER");
        deployed.guardian = vm.envAddress("PERPS_GUARDIAN");
        deployed.usdc = vm.envAddress("PERPS_USDC");
        deployed.clearinghouse = MarginClearinghouse(vm.envAddress("PERPS_CLEARINGHOUSE"));
        deployed.engine = CfdEngine(vm.envAddress("PERPS_ENGINE"));
        deployed.terminalNavBook = TerminalNavBookV2(vm.envAddress("PERPS_TERMINAL_NAV_BOOK"));
        deployed.planner = vm.envAddress("PERPS_ENGINE_PLANNER");
        deployed.settlementSidecar = CfdEngineSettlementSidecar(vm.envAddress("PERPS_ENGINE_SETTLEMENT_SIDECAR"));
        deployed.engineAdmin = CfdEngineAdmin(vm.envAddress("PERPS_ENGINE_ADMIN"));
        deployed.redemptionMathSidecar =
            HousePoolRedemptionMathSidecar(vm.envAddress("PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR"));
        deployed.housePool = HousePool(vm.envAddress("PERPS_HOUSE_POOL"));
        deployed.seniorVault = TrancheVault(vm.envAddress("PERPS_SENIOR_VAULT"));
        deployed.juniorVault = TrancheVault(vm.envAddress("PERPS_JUNIOR_VAULT"));
        deployed.accountLens = CfdEngineAccountLens(vm.envAddress("PERPS_ACCOUNT_LENS"));
        deployed.engineLens = CfdEngineLens(vm.envAddress("PERPS_ENGINE_LENS"));
        deployed.orderPolicyEvaluator = CfdOrderPolicyEvaluator(vm.envAddress("PERPS_ORDER_POLICY_EVALUATOR"));
        deployed.orderExecutionSidecar = OrderRouterV2ExecutionSidecar(vm.envAddress("PERPS_ORDER_EXECUTION_SIDECAR"));
        deployed.router = OrderRouter(vm.envAddress("PERPS_ORDER_ROUTER"));
        deployed.liquidationBatchSidecar =
            OrderRouterLiquidationBatchSidecar(vm.envAddress("PERPS_LIQUIDATION_BATCH_SIDECAR"));
        deployed.lifecycleBook = OrderLifecycleBook(vm.envAddress("PERPS_ORDER_LIFECYCLE_BOOK"));
        deployed.positionProtectionBook = PositionProtectionBook(vm.envAddress("PERPS_POSITION_PROTECTION_BOOK"));
        deployed.oracle = PletherOracle(vm.envAddress("PERPS_ORACLE"));
        deployed.routerAdmin = OrderRouterAdmin(vm.envAddress("PERPS_ORDER_ROUTER_ADMIN"));
        deployed.publicLens = PerpsPublicLens(vm.envAddress("PERPS_PUBLIC_LENS"));
        deployed.monitor = SettlementMonitorLens(vm.envAddress("PERPS_SETTLEMENT_MONITOR_LENS"));
        deployed.monitorSidecar = SettlementMonitorLensSidecar(vm.envAddress("PERPS_SETTLEMENT_MONITOR_SIDECAR"));
        deployed.emergencyCoordinator = EmergencyPauseCoordinator(vm.envAddress("PERPS_EMERGENCY_COORDINATOR"));
    }

    function _verifyCode(
        Deployment memory deployed
    ) internal view {
        require(deployed.owner != address(0), "Owner is zero");
        require(deployed.guardian != address(0), "Guardian is zero");
        _requireCode(deployed.usdc, "USDC has no code");
        _requireCode(address(deployed.clearinghouse), "Clearinghouse has no code");
        _requireCode(address(deployed.engine), "Engine has no code");
        _requireCode(address(deployed.terminalNavBook), "Terminal NAV book has no code");
        _requireCode(deployed.planner, "Planner has no code");
        _requireCode(address(deployed.settlementSidecar), "Settlement sidecar has no code");
        _requireCode(address(deployed.engineAdmin), "Engine admin has no code");
        _requireCode(address(deployed.redemptionMathSidecar), "Redemption math sidecar has no code");
        _requireCode(address(deployed.housePool), "HousePool has no code");
        _requireCode(address(deployed.seniorVault), "Senior vault has no code");
        _requireCode(address(deployed.juniorVault), "Junior vault has no code");
        _requireCode(address(deployed.accountLens), "Account lens has no code");
        _requireCode(address(deployed.engineLens), "Engine lens has no code");
        _requireCode(address(deployed.orderPolicyEvaluator), "Order policy evaluator has no code");
        _requireCode(address(deployed.orderExecutionSidecar), "Order execution sidecar has no code");
        _requireCode(address(deployed.router), "Router has no code");
        _requireCode(address(deployed.liquidationBatchSidecar), "Liquidation sidecar has no code");
        _requireCode(address(deployed.lifecycleBook), "Order lifecycle book has no code");
        _requireCode(address(deployed.positionProtectionBook), "Position protection book has no code");
        _requireCode(address(deployed.oracle), "Oracle has no code");
        _requireCode(address(deployed.routerAdmin), "Router admin has no code");
        _requireCode(address(deployed.publicLens), "Public lens has no code");
        _requireCode(address(deployed.monitor), "Settlement monitor has no code");
        _requireCode(address(deployed.monitorSidecar), "Settlement monitor sidecar has no code");
        _requireCode(address(deployed.emergencyCoordinator), "Emergency coordinator has no code");
        _requireCode(RELEASE_PYTH, "Release Pyth has no code");
    }

    function _verifyCoreGraph(
        Deployment memory deployed
    ) internal view {
        require(IERC20Metadata(deployed.usdc).decimals() == 6, "USDC decimals mismatch");
        require(deployed.clearinghouse.settlementAsset() == deployed.usdc, "Clearinghouse asset mismatch");
        require(deployed.clearinghouse.engine() == address(deployed.engine), "Clearinghouse engine mismatch");
        require(address(deployed.engine.USDC()) == deployed.usdc, "Engine USDC mismatch");
        require(
            address(deployed.engine.clearinghouse()) == address(deployed.clearinghouse), "Engine clearinghouse mismatch"
        );
        require(address(deployed.engine.pool()) == address(deployed.housePool), "Engine pool mismatch");
        require(address(deployed.engine.planner()) == deployed.planner, "Engine planner mismatch");
        require(
            address(deployed.engine.settlementSidecar()) == address(deployed.settlementSidecar),
            "Engine settlement sidecar mismatch"
        );
        require(deployed.engine.admin() == address(deployed.engineAdmin), "Engine admin mismatch");
        require(
            address(deployed.engine.terminalNavBook()) == address(deployed.terminalNavBook), "Terminal NAV mismatch"
        );
        require(deployed.engine.orderRouter() == address(deployed.router), "Engine Router mismatch");
        require(deployed.settlementSidecar.ENGINE() == address(deployed.engine), "Settlement sidecar binding mismatch");
        require(address(deployed.engineAdmin.engine()) == address(deployed.engine), "Engine admin binding mismatch");
        require(deployed.terminalNavBook.ENGINE() == address(deployed.engine), "Terminal NAV engine mismatch");
        require(
            deployed.terminalNavBook.CAP_PRICE() == uint32(deployed.engine.CAP_PRICE()), "Terminal NAV cap mismatch"
        );
        require(deployed.terminalNavBook.SIZE_QUANTUM() == 1e20, "Position quantum mismatch");
        require(
            deployed.redemptionMathSidecar.implementationId() == keccak256("Plether.HousePoolRedemptionMathSidecar.v1"),
            "Redemption math implementation mismatch"
        );

        require(address(deployed.housePool.USDC()) == deployed.usdc, "HousePool USDC mismatch");
        require(address(deployed.housePool.ENGINE()) == address(deployed.engine), "HousePool engine mismatch");
        require(deployed.housePool.seniorVault() == address(deployed.seniorVault), "Senior vault mismatch");
        require(deployed.housePool.juniorVault() == address(deployed.juniorVault), "Junior vault mismatch");
        require(
            address(CfdEngineProtocolLens(address(deployed.housePool.ENGINE_PROTOCOL_LENS())).engineContract())
                == address(deployed.engine),
            "Protocol lens engine mismatch"
        );
        _verifyVault(deployed.seniorVault, deployed, true);
        _verifyVault(deployed.juniorVault, deployed, false);

        require(address(deployed.accountLens.engineContract()) == address(deployed.engine), "Account lens mismatch");
        require(deployed.engineLens.engine() == address(deployed.engine), "Engine lens mismatch");
        require(address(deployed.router.engine()) == address(deployed.engine), "Router engine mismatch");
        require(
            deployed.router.policyEvaluator() == address(deployed.orderPolicyEvaluator),
            "Router policy evaluator mismatch"
        );
        require(
            deployed.router.executionSidecar() == address(deployed.orderExecutionSidecar),
            "Router execution sidecar mismatch"
        );
        require(
            deployed.orderExecutionSidecar.SELF() == address(deployed.orderExecutionSidecar),
            "Execution sidecar self binding mismatch"
        );
        require(address(deployed.router.lifecycleBook()) == address(deployed.lifecycleBook), "Lifecycle book mismatch");
        require(deployed.lifecycleBook.ROUTER() == address(deployed.router), "Lifecycle Router mismatch");
        require(deployed.lifecycleBook.ENGINE() == address(deployed.engine), "Lifecycle Engine mismatch");
        require(
            deployed.lifecycleBook.CLEARINGHOUSE() == address(deployed.clearinghouse),
            "Lifecycle clearinghouse mismatch"
        );
        require(deployed.lifecycleBook.HOUSE_POOL() == address(deployed.housePool), "Lifecycle pool mismatch");
        require(deployed.lifecycleBook.currentExecutionConfigHash() != bytes32(0), "Execution config hash is zero");
        require(deployed.router.admin() == address(deployed.routerAdmin), "Router admin mismatch");
        require(address(deployed.router.pletherOracle()) == address(deployed.oracle), "Router oracle mismatch");
        require(
            deployed.router.liquidationBatchSidecar() == address(deployed.liquidationBatchSidecar),
            "Router sidecar mismatch"
        );
        require(
            address(deployed.router.positionProtectionBook()) == address(deployed.positionProtectionBook),
            "Position protection book mismatch"
        );
        require(
            address(deployed.lifecycleBook) != address(deployed.liquidationBatchSidecar)
                && address(deployed.lifecycleBook) != address(deployed.positionProtectionBook)
                && address(deployed.liquidationBatchSidecar) != address(deployed.positionProtectionBook),
            "Router helper contracts alias"
        );
        require(
            deployed.liquidationBatchSidecar.ROUTER() == address(deployed.router),
            "Liquidation sidecar binding mismatch"
        );
        require(deployed.positionProtectionBook.ROUTER() == address(deployed.router), "Protection Router mismatch");
        require(
            address(deployed.positionProtectionBook.ENGINE()) == address(deployed.engine), "Protection Engine mismatch"
        );
        require(address(deployed.oracle.engine()) == address(deployed.engine), "Oracle engine mismatch");
        require(address(deployed.oracle.housePool()) == address(deployed.housePool), "Oracle pool mismatch");
        require(address(deployed.oracle.pyth()) == RELEASE_PYTH, "Oracle Pyth mismatch");
        require(address(deployed.routerAdmin.router()) == address(deployed.router), "Router admin binding mismatch");

        require(
            address(deployed.publicLens.ACCOUNT_LENS()) == address(deployed.accountLens), "Public account lens mismatch"
        );
        require(address(deployed.publicLens.ENGINE()) == address(deployed.engine), "Public engine mismatch");
        require(address(deployed.publicLens.ORDER_ROUTER()) == address(deployed.router), "Public Router mismatch");
        require(address(deployed.publicLens.HOUSE_POOL()) == address(deployed.housePool), "Public pool mismatch");
        require(address(deployed.monitor.ROUTER()) == address(deployed.router), "Monitor Router mismatch");
        require(address(deployed.monitor.ENGINE()) == address(deployed.engine), "Monitor Engine mismatch");
        require(address(deployed.monitor.HOUSE_POOL()) == address(deployed.housePool), "Monitor pool mismatch");
        require(
            address(deployed.monitor.CLEARINGHOUSE()) == address(deployed.clearinghouse),
            "Monitor clearinghouse mismatch"
        );
        require(
            address(deployed.monitor.TERMINAL_NAV_BOOK()) == address(deployed.terminalNavBook), "Monitor NAV mismatch"
        );
        require(address(deployed.monitor.SENIOR_VAULT()) == address(deployed.seniorVault), "Monitor Senior mismatch");
        require(address(deployed.monitor.JUNIOR_VAULT()) == address(deployed.juniorVault), "Monitor Junior mismatch");
        require(address(deployed.monitor.USDC()) == deployed.usdc, "Monitor USDC mismatch");
        require(address(deployed.monitor.SIDECAR()) == address(deployed.monitorSidecar), "Monitor sidecar mismatch");
        require(deployed.monitorSidecar.MONITOR() == address(deployed.monitor), "Monitor sidecar binding mismatch");

        require(
            address(deployed.emergencyCoordinator.ROUTER_ADMIN()) == address(deployed.routerAdmin),
            "Emergency Router mismatch"
        );
        require(
            address(deployed.emergencyCoordinator.HOUSE_POOL()) == address(deployed.housePool),
            "Emergency pool mismatch"
        );
        require(deployed.housePool.pauser() == address(deployed.emergencyCoordinator), "HousePool pauser mismatch");
        require(deployed.routerAdmin.pauser() == address(deployed.emergencyCoordinator), "Router pauser mismatch");
    }

    function _verifyVault(
        TrancheVault vault,
        Deployment memory deployed,
        bool isSenior
    ) internal view {
        require(address(vault.POOL()) == address(deployed.housePool), "Vault pool mismatch");
        require(vault.IS_SENIOR() == isSenior, "Vault side mismatch");
        require(vault.asset() == deployed.usdc, "Vault asset mismatch");
        require(vault.maintenanceFeeConfigActivationTime() == 0, "Outstanding fee proposal");
        (uint256 pendingAprBps, address pendingRecipient) = vault.pendingMaintenanceFeeConfig();
        require(pendingAprBps == 0 && pendingRecipient == address(0), "Pending fee config is not empty");
        if (isSenior) {
            require(vault.maintenanceFeeAprBps() == 0, "Senior fee is nonzero");
            require(vault.maintenanceFeeRecipient() == address(0), "Senior fee recipient is nonzero");
            require(vault.pendingMaintenanceFeeShares() == 0, "Senior pending fee shares are nonzero");
        } else {
            require(vault.maintenanceFeeAprBps() == RELEASE_JUNIOR_MAINTENANCE_FEE_APR_BPS, "Junior fee mismatch");
            require(
                vault.maintenanceFeeRecipient() == deployed.engine.protocolTreasury(), "Junior fee recipient mismatch"
            );
            require(
                vault.accruedTotalSupply() == vault.totalSupply() + vault.pendingMaintenanceFeeShares(),
                "Junior supply mismatch"
            );
        }
    }

    function _verifyReleaseEconomics(
        Deployment memory deployed
    ) internal view {
        CfdTypes.RiskParams memory params;
        (
            params.vpiFactor,
            params.maxSkewRatio,
            params.maintMarginBps,
            params.initMarginBps,
            params.fadMarginBps,
            params.baseCarryBps,
            params.minBountyUsdc,
            params.bountyBps,
            params.keeperShareBps,
            params.protocolShareBps
        ) = deployed.engine.riskParams();
        require(params.vpiFactor == 0.01e18, "VPI mismatch");
        require(params.maxSkewRatio == 0.4e18, "Maximum skew mismatch");
        require(params.maintMarginBps == 10, "Maintenance margin mismatch");
        require(params.initMarginBps == 20, "Initial margin mismatch");
        require(params.fadMarginBps == 300, "FAD mismatch");
        require(params.baseCarryBps == 500, "Base carry mismatch");
        require(params.minBountyUsdc == 1e6, "Minimum liquidation charge mismatch");
        require(params.bountyBps == 10, "Liquidation charge mismatch");
        require(params.keeperShareBps == 5000, "Keeper share mismatch");
        require(params.protocolShareBps == 0, "Protocol share mismatch");
        require(deployed.engine.executionFeeBps() == 4, "Execution fee mismatch");
        require(deployed.engine.frozenCloseSpreadBps() == 50, "Frozen-close spread mismatch");
        require(deployed.oracle.basketMaxConfidenceRatioBps() == 10, "Basket confidence mismatch");
        require(
            deployed.oracle.adverseConfidenceMultiplierBps() == RELEASE_ADVERSE_CONFIDENCE_MULTIPLIER_BPS,
            "Adverse multiplier mismatch"
        );
        require(deployed.router.maxPendingOrders() == 5, "Pending-order limit mismatch");
        require(deployed.router.minOpenNotionalUsdc() == RELEASE_MIN_OPEN_NOTIONAL_USDC, "Opening notional mismatch");
        require(deployed.housePool.maxSeniorExposureUsdc() == RELEASE_MAX_SENIOR_EXPOSURE_USDC, "Exposure mismatch");
        require(deployed.housePool.maxSeniorShareBps() == RELEASE_MAX_SENIOR_SHARE_BPS, "Senior share mismatch");
    }

    function _verifyGovernanceAndPhase(
        Deployment memory deployed,
        bytes32 phase
    ) internal view {
        require(deployed.engine.owner() == deployed.owner, "Engine owner mismatch");
        require(deployed.engineAdmin.owner() == deployed.owner, "Engine admin owner mismatch");
        require(deployed.housePool.owner() == deployed.owner, "HousePool owner mismatch");
        require(deployed.routerAdmin.owner() == deployed.owner, "Router admin owner mismatch");
        require(deployed.emergencyCoordinator.owner() == deployed.owner, "Emergency owner mismatch");
        require(deployed.engineAdmin.riskConfigActivationTime() == 0, "Outstanding Engine risk proposal");
        require(deployed.engineAdmin.calendarConfigActivationTime() == 0, "Outstanding Engine calendar proposal");
        require(deployed.engineAdmin.freshnessConfigActivationTime() == 0, "Outstanding Engine freshness proposal");
        require(deployed.routerAdmin.oracleConfigActivationTime() == 0, "Outstanding Router oracle proposal");
        require(deployed.housePool.poolConfigActivationTime() == 0, "Outstanding HousePool proposal");
        require(deployed.routerAdmin.routerConfigActivationTime() == 0, "Outstanding Router proposal");

        if (phase == PHASE_DEPLOYED) {
            require(!deployed.housePool.seniorSeedInitialized(), "Senior seed already initialized");
            require(!deployed.housePool.juniorSeedInitialized(), "Junior seed already initialized");
            require(deployed.juniorVault.pendingMaintenanceFeeShares() == 0, "Pre-seed Junior fee shares are nonzero");
            require(!deployed.housePool.isTradingActive(), "Trading active in deployed phase");
            return;
        }

        require(deployed.housePool.seniorSeedInitialized(), "Senior seed missing");
        require(deployed.housePool.juniorSeedInitialized(), "Junior seed missing");
        require(deployed.seniorVault.seedShareFloor() != 0, "Senior seed floor missing");
        require(deployed.juniorVault.seedShareFloor() != 0, "Junior seed floor missing");
        require(
            deployed.seniorVault.seedReceiver() == vm.envAddress("SENIOR_SEED_RECEIVER"), "Senior receiver mismatch"
        );
        require(
            deployed.juniorVault.seedReceiver() == vm.envAddress("JUNIOR_SEED_RECEIVER"), "Junior receiver mismatch"
        );
        require(deployed.housePool.seniorPrincipal() >= RELEASE_SENIOR_SEED_USDC, "Senior seed backing mismatch");
        require(deployed.housePool.juniorPrincipal() >= RELEASE_JUNIOR_SEED_USDC, "Junior seed backing mismatch");
        require(deployed.emergencyCoordinator.guardian() == deployed.guardian, "Guardian mismatch");

        if (phase == PHASE_SEEDED) {
            require(!deployed.housePool.isTradingActive(), "Trading active in seeded phase");
        } else {
            require(deployed.housePool.isTradingActive(), "Trading is not active");
            require(!deployed.housePool.paused(), "HousePool is paused");
            require(!deployed.housePool.lpEpochSettlementPaused(), "LP settlement is paused");
            require(!deployed.routerAdmin.paused(), "Router is paused");
        }
    }

    function _requireCode(
        address target,
        string memory message
    ) internal view {
        require(target != address(0) && target.code.length != 0, message);
    }

}
