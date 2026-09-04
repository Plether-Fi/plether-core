// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderRouterV2ExecutionSidecar} from "@plether/perps/OrderRouterV2ExecutionSidecar.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import {IAsyncTrancheVaultClaimableRedeem} from "@plether/perps/interfaces/IAsyncTrancheVaultClaimableRedeem.sol";
import {IHousePoolRedemptionMathSidecar} from "@plether/perps/interfaces/IHousePoolRedemptionMathSidecar.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import "forge-std/Script.sol";

interface IMintableERC20 {

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
    function mint(
        address to,
        uint256 amount
    ) external;

}

/// @dev Minimal compatibility surface used to reject an old or partially upgraded tranche pair before bootstrap.
interface IAsyncTrancheVaultBootstrapView {

    function POOL() external view returns (address);
    function IS_SENIOR() external view returns (bool);
    function LP_REQUEST_CUTOFF_DURATION() external view returns (uint256);
    function asset() external view returns (address);
    function share() external view returns (address);
    function totalSupply() external view returns (uint256);
    function maintenanceFeeAprBps() external view returns (uint256);
    function maintenanceFeeRecipient() external view returns (address);
    function maintenanceFeeConfigActivationTime() external view returns (uint256);
    function pendingMaintenanceFeeConfig() external view returns (uint256 aprBps, address recipient);
    function pendingMaintenanceFeeShares() external view returns (uint256);
    function accruedTotalSupply() external view returns (uint256);
    function getRequestEpochWindow() external view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);
    function vault(
        address asset_
    ) external view returns (address);
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);

}

/// @dev Minimal immutable-binding surface for the Router-deployed position-protection book.
interface IPositionProtectionBookBootstrapView {

    function ROUTER() external view returns (address);
    function ENGINE() external view returns (address);

}

contract BootstrapPerpsArbitrumSepolia is Script {

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant RELEASE_SENIOR_SEED_USDC = 10_000_000e6;
    uint256 internal constant RELEASE_JUNIOR_SEED_USDC = 10_000_000e6;
    uint256 internal constant RELEASE_MAX_SENIOR_EXPOSURE_USDC = 40_000_000e6;
    uint256 internal constant RELEASE_MAX_SENIOR_SHARE_BPS = 8000;
    uint256 internal constant RELEASE_MIN_OPEN_NOTIONAL_USDC = 1000e6;
    uint256 internal constant RELEASE_ADVERSE_CONFIDENCE_MULTIPLIER_BPS = 2500;
    uint256 internal constant RELEASE_BASKET_MAX_CONFIDENCE_RATIO_BPS = 10;
    uint256 internal constant RELEASE_MAX_PENDING_ORDERS = 5;
    uint256 internal constant RELEASE_JUNIOR_MAINTENANCE_FEE_APR_BPS = 100;

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 internal constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 internal constant ERC7575_SHARE_INTERFACE_ID = 0xf815c03d;
    bytes4 internal constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    bytes4 internal constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    function run() external {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address usdc = vm.envAddress("PERPS_USDC");
        address housePoolAddr = vm.envAddress("PERPS_HOUSE_POOL");
        address redemptionMathSidecarAddr = vm.envAddress("PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR");
        address routerAddr = vm.envAddress("PERPS_ORDER_ROUTER");
        address emergencyCoordinatorAddr = vm.envAddress("PERPS_EMERGENCY_COORDINATOR");
        address desiredGuardian = vm.envAddress("PERPS_GUARDIAN");

        uint256 seniorSeedUsdc = vm.envUint("SENIOR_SEED_USDC");
        uint256 juniorSeedUsdc = vm.envUint("JUNIOR_SEED_USDC");
        address seniorSeedReceiver = vm.envAddress("SENIOR_SEED_RECEIVER");
        address juniorSeedReceiver = vm.envAddress("JUNIOR_SEED_RECEIVER");
        bool activateTrading = vm.envBool("ACTIVATE_TRADING");

        address[] memory testUsers = vm.envOr("TEST_USER_RECIPIENTS", ",", new address[](0));
        uint256[] memory testUserAmounts = vm.envOr("TEST_USER_AMOUNTS", ",", new uint256[](0));

        if (testUsers.length != testUserAmounts.length) {
            revert("TEST_USER_RECIPIENTS/AMOUNTS length mismatch");
        }

        HousePool housePool = HousePool(housePoolAddr);
        OrderRouter router = OrderRouter(routerAddr);
        OrderRouterAdmin routerAdmin = OrderRouterAdmin(router.admin());
        EmergencyPauseCoordinator emergencyCoordinator = EmergencyPauseCoordinator(emergencyCoordinatorAddr);

        _validateGuardian(desiredGuardian);
        _validateReleaseInputs(seniorSeedUsdc, juniorSeedUsdc, seniorSeedReceiver, juniorSeedReceiver);
        _verifyRedemptionMathSidecar(redemptionMathSidecarAddr);
        _verifyAsyncVaultPair(housePool, usdc);
        _verifyTerminalNavBook(housePool);
        _verifyRouterWiring(housePool, router);
        _verifyInitialReleaseConfig(housePool, router, routerAdmin);
        _verifyEmergencyCoordinator(housePool, routerAdmin, emergencyCoordinator);

        console.log("Bootstrapping Plether perps on Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("HousePool:", housePoolAddr);
        console.log("HousePoolRedemptionMathSidecar:", redemptionMathSidecarAddr);
        console.log("OrderRouter:", routerAddr);
        console.log("OrderRouterLiquidationBatchSidecar:", router.liquidationBatchSidecar());
        console.log("PositionProtectionBook:", address(router.positionProtectionBook()));
        console.log("CfdOrderPolicyEvaluator:", router.policyEvaluator());
        console.log("OrderRouterV2ExecutionSidecar:", router.executionSidecar());
        console.log("OrderLifecycleBook:", address(router.lifecycleBook()));
        console.log("OrderExecutionConfigHash:");
        console.logBytes32(router.lifecycleBook().currentExecutionConfigHash());
        console.log("OrderRouterAdmin:", address(routerAdmin));
        console.log("EmergencyPauseCoordinator:", emergencyCoordinatorAddr);
        console.log("Requested guardian:", desiredGuardian);

        vm.startBroadcast(privateKey);

        _configureGuardian(emergencyCoordinator, desiredGuardian, deployer);
        _seedLifecycle(
            housePool,
            IMintableERC20(usdc),
            seniorSeedUsdc,
            juniorSeedUsdc,
            seniorSeedReceiver,
            juniorSeedReceiver,
            deployer
        );
        _fundTestUsers(IMintableERC20(usdc), testUsers, testUserAmounts);
        _activateTrading(housePool, routerAdmin, emergencyCoordinator, activateTrading);

        vm.stopBroadcast();

        console.log("");
        console.log("HousePool trading active:", housePool.isTradingActive());
        console.log("Senior seed initialized:", housePool.seniorSeedInitialized());
        console.log("Junior seed initialized:", housePool.juniorSeedInitialized());
        console.log("HousePool pauser:", housePool.pauser());
        console.log("Router pauser:", routerAdmin.pauser());
        console.log("Position protection commits enabled:", router.positionProtectionCommitsEnabled());
        console.log("Position protection trigger bounty USDC:", router.positionProtectionTriggerBountyUsdc());
        console.log("Emergency guardian:", emergencyCoordinator.guardian());
        console.log("Risk-off order cutoff:", routerAdmin.riskOffOrderCutoff());
        console.log("LP epoch settlement paused:", housePool.lpEpochSettlementPaused());
        console.log("Maximum senior exposure (USDC units):", housePool.maxSeniorExposureUsdc());
        console.log("Maximum senior share (bps):", housePool.maxSeniorShareBps());
        console.log("Minimum opening notional (USDC units):", router.minOpenNotionalUsdc());
        console.log("Adverse confidence multiplier (bps):", router.pletherOracle().adverseConfidenceMultiplierBps());
        console.log("LP epoch duration:", housePool.LP_EPOCH_DURATION());
        console.log("Maximum LP epochs per settlement phase:", housePool.MAX_LP_EPOCHS_PER_PHASE());
        console.log("Current LP epoch:", housePool.currentLpEpoch());
        console.log("Note: this script funds users with mock USDC only; ETH still needs a faucet.");
    }

    /// @dev Keeps bootstrap reruns fail-closed against an omitted or wrong-generation redemption math dependency.
    function _verifyRedemptionMathSidecar(
        address redemptionMathSidecar
    ) internal view {
        require(redemptionMathSidecar != address(0), "PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR is zero");
        require(redemptionMathSidecar.code.length > 0, "HousePool redemption math sidecar has no code");
        require(
            IHousePoolRedemptionMathSidecar(redemptionMathSidecar).implementationId()
                == keccak256("Plether.HousePoolRedemptionMathSidecar.v1"),
            "HousePool redemption math sidecar ID mismatch"
        );
    }

    /// @dev Refuses to seed or activate a stack whose exact terminal-NAV book is absent or misbound.
    function _verifyTerminalNavBook(
        HousePool housePool
    ) internal view {
        CfdEngine engine = CfdEngine(address(housePool.ENGINE()));
        ITerminalNavBookV2 book = engine.terminalNavBook();
        require(address(book) != address(0), "TerminalNavBookV2 is not wired");
        require(address(book).code.length > 0, "TerminalNavBookV2 has no code");
        require(book.ENGINE() == address(engine), "TerminalNavBookV2 engine mismatch");
        require(book.CAP_PRICE() == uint32(engine.CAP_PRICE()), "TerminalNavBookV2 cap mismatch");
        require(book.SIZE_QUANTUM() == 1e20, "TerminalNavBookV2 quantum mismatch");
    }

    /// @dev Refuses to bootstrap a mixed-generation stack. Verifies reciprocal Router/Engine/oracle wiring, the
    ///      separately deployed V2 policy modules, the predeployed lifecycle book, and both delegate sidecars.
    function _verifyRouterWiring(
        HousePool housePool,
        OrderRouter router
    ) internal view {
        CfdEngine engine = CfdEngine(address(housePool.ENGINE()));
        require(address(engine.pool()) == address(housePool), "Engine HousePool mismatch");
        MarginClearinghouse clearinghouse = MarginClearinghouse(address(engine.clearinghouse()));
        require(clearinghouse.engine() == address(engine), "Clearinghouse Engine mismatch");
        require(address(engine.USDC()) == address(housePool.USDC()), "Engine settlement asset mismatch");
        require(clearinghouse.settlementAsset() == address(housePool.USDC()), "Clearinghouse settlement asset mismatch");
        require(engine.orderRouter() == address(router), "Engine OrderRouter mismatch");
        require(address(router.pletherOracle()).code.length > 0, "PletherOracle has no code");
        require(address(router.pletherOracle().engine()) == address(engine), "PletherOracle Engine mismatch");
        require(address(router.pletherOracle().housePool()) == address(housePool), "PletherOracle HousePool mismatch");
        require(address(router.pletherOracle().pyth()) == RELEASE_PYTH, "Unexpected Pyth contract");
        require(address(router.pletherOracle().pyth()).code.length > 0, "Pyth has no code");

        address policyEvaluator = router.policyEvaluator();
        require(policyEvaluator.code.length > 0, "Order policy evaluator has no code");
        address executionSidecar = router.executionSidecar();
        require(executionSidecar.code.length > 0, "Order execution sidecar has no code");
        require(
            OrderRouterV2ExecutionSidecar(executionSidecar).SELF() == executionSidecar,
            "Order execution sidecar self binding mismatch"
        );

        OrderLifecycleBook lifecycleBook = router.lifecycleBook();
        require(address(lifecycleBook).code.length > 0, "Order lifecycle book has no code");
        require(lifecycleBook.ROUTER() == address(router), "Order lifecycle book Router mismatch");
        require(lifecycleBook.ENGINE() == address(engine), "Order lifecycle book Engine mismatch");
        require(
            lifecycleBook.CLEARINGHOUSE() == address(engine.clearinghouse()),
            "Order lifecycle book Clearinghouse mismatch"
        );
        require(lifecycleBook.HOUSE_POOL() == address(housePool), "Order lifecycle book HousePool mismatch");
        require(lifecycleBook.currentExecutionConfigHash() != bytes32(0), "Order config hash is zero");

        address liquidationBatchSidecar = router.liquidationBatchSidecar();
        require(liquidationBatchSidecar != address(0), "OrderRouter sidecar is not wired");
        require(liquidationBatchSidecar.code.length > 0, "OrderRouter liquidation batch sidecar has no code");
        require(
            OrderRouterLiquidationBatchSidecar(liquidationBatchSidecar).ROUTER() == address(router),
            "OrderRouter sidecar router mismatch"
        );

        address positionProtectionBook = address(router.positionProtectionBook());
        require(positionProtectionBook != address(0), "PositionProtectionBook is not wired");
        require(positionProtectionBook.code.length > 0, "PositionProtectionBook has no code");
        require(liquidationBatchSidecar != positionProtectionBook, "OrderRouter sidecar aliases PositionProtectionBook");
        IPositionProtectionBookBootstrapView candidate = IPositionProtectionBookBootstrapView(positionProtectionBook);
        require(candidate.ROUTER() == address(router), "PositionProtectionBook router mismatch");
        require(candidate.ENGINE() == address(engine), "PositionProtectionBook engine mismatch");
    }

    /// @dev Initial release values are constructor-installed. Bootstrap has no privileged initialization path and
    ///      refuses to seed or activate a deployment whose live values differ or whose later governance change is
    ///      already pending.
    function _verifyInitialReleaseConfig(
        HousePool housePool,
        OrderRouter router,
        OrderRouterAdmin routerAdmin
    ) internal view {
        require(
            housePool.maxSeniorExposureUsdc() == RELEASE_MAX_SENIOR_EXPOSURE_USDC, "Unexpected maximum senior exposure"
        );
        require(housePool.maxSeniorShareBps() == RELEASE_MAX_SENIOR_SHARE_BPS, "Unexpected maximum senior share");
        require(housePool.poolConfigActivationTime() == 0, "Outstanding HousePool config proposal");
        require(router.minOpenNotionalUsdc() == RELEASE_MIN_OPEN_NOTIONAL_USDC, "Unexpected opening notional");
        require(
            router.pletherOracle().adverseConfidenceMultiplierBps() == RELEASE_ADVERSE_CONFIDENCE_MULTIPLIER_BPS,
            "Unexpected adverse multiplier"
        );
        require(
            router.pletherOracle().basketMaxConfidenceRatioBps() == RELEASE_BASKET_MAX_CONFIDENCE_RATIO_BPS,
            "Basket confidence changed"
        );
        require(router.maxPendingOrders() == RELEASE_MAX_PENDING_ORDERS, "Pending-order limit changed");
        require(routerAdmin.routerConfigActivationTime() == 0, "Outstanding Router config proposal");
    }

    /// @dev Requires the deploy-time coordinator and both pauser bindings to match this exact stack. Bootstrap never
    ///      repairs a partial binding because doing so could silently combine authority from two deployments.
    function _verifyEmergencyCoordinator(
        HousePool housePool,
        OrderRouterAdmin routerAdmin,
        EmergencyPauseCoordinator coordinator
    ) internal view {
        require(address(coordinator) != address(0), "PERPS_EMERGENCY_COORDINATOR is zero");
        require(address(coordinator).code.length > 0, "EmergencyPauseCoordinator has no code");
        require(address(coordinator.ROUTER_ADMIN()) == address(routerAdmin), "Emergency RouterAdmin mismatch");
        require(address(coordinator.HOUSE_POOL()) == address(housePool), "Emergency HousePool mismatch");
        require(housePool.pauser() == address(coordinator), "HousePool pauser is not emergency coordinator");
        require(routerAdmin.pauser() == address(coordinator), "Router pauser is not emergency coordinator");
    }

    /// @dev Checks all immutable/set-once LP wiring before any governance proposal, seed mint, or activation occurs.
    function _verifyAsyncVaultPair(
        HousePool housePool,
        address usdc
    ) internal view {
        require(address(housePool.USDC()) == usdc, "PERPS_USDC does not match HousePool");
        require(housePool.LP_EPOCH_DURATION() == 1 hours, "Unexpected LP epoch duration");
        require(housePool.MAX_LP_EPOCHS_PER_PHASE() == 16, "Unexpected LP epoch bound");

        uint256 currentEpoch = housePool.currentLpEpoch();
        require(currentEpoch == block.timestamp / housePool.LP_EPOCH_DURATION(), "Invalid current LP epoch");
        require(
            housePool.lpEpochStart(currentEpoch) == currentEpoch * housePool.LP_EPOCH_DURATION(),
            "Invalid LP epoch start"
        );

        uint256 imminentEpoch = currentEpoch + 1;
        require(
            housePool.lpEpochStart(imminentEpoch) == imminentEpoch * housePool.LP_EPOCH_DURATION(),
            "Invalid imminent LP epoch start"
        );

        address seniorVault = housePool.seniorVault();
        address juniorVault = housePool.juniorVault();
        require(seniorVault != address(0) && juniorVault != address(0), "HousePool vault pair is incomplete");
        require(seniorVault != juniorVault, "HousePool vault pair is duplicated");
        address juniorFeeRecipient = CfdEngine(address(housePool.ENGINE())).protocolTreasury();
        require(juniorFeeRecipient != address(0), "Protocol treasury is zero");
        (uint256 seniorNextRequestEpoch, uint256 seniorNextRequestCutoffTime) =
            _verifyAsyncVault(seniorVault, address(housePool), usdc, true, 0, address(0), true);
        (uint256 juniorNextRequestEpoch, uint256 juniorNextRequestCutoffTime) = _verifyAsyncVault(
            juniorVault,
            address(housePool),
            usdc,
            false,
            RELEASE_JUNIOR_MAINTENANCE_FEE_APR_BPS,
            juniorFeeRecipient,
            !housePool.juniorSeedInitialized()
        );
        require(seniorNextRequestEpoch == juniorNextRequestEpoch, "TrancheVault request epoch mismatch");
        require(seniorNextRequestCutoffTime == juniorNextRequestCutoffTime, "TrancheVault request cutoff mismatch");

        uint256 cutoffDuration = 5 minutes;
        uint256 imminentCutoffTime = housePool.lpEpochStart(imminentEpoch) - cutoffDuration;
        uint256 expectedNextRequestEpoch = block.timestamp < imminentCutoffTime ? imminentEpoch : imminentEpoch + 1;
        uint256 expectedNextRequestCutoffTime = housePool.lpEpochStart(expectedNextRequestEpoch) - cutoffDuration;
        require(seniorNextRequestEpoch == expectedNextRequestEpoch, "Unexpected request epoch");
        require(seniorNextRequestCutoffTime == expectedNextRequestCutoffTime, "Unexpected request cutoff");
        require(seniorNextRequestCutoffTime > block.timestamp, "Request cutoff is not future");

        uint256 targetEpochStart = housePool.lpEpochStart(seniorNextRequestEpoch);
        require(
            targetEpochStart == seniorNextRequestEpoch * housePool.LP_EPOCH_DURATION(),
            "Invalid request target epoch start"
        );
        uint256 targetDelay = targetEpochStart - block.timestamp;
        require(targetDelay > cutoffDuration, "Request target is inside cutoff");
        require(targetDelay <= housePool.LP_EPOCH_DURATION() + cutoffDuration, "Request target exceeds routing window");
    }

    function _verifyAsyncVault(
        address vault,
        address housePool,
        address usdc,
        bool isSenior,
        uint256 expectedMaintenanceFeeAprBps,
        address expectedMaintenanceFeeRecipient,
        bool requireZeroPendingFeeShares
    ) internal view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime) {
        IAsyncTrancheVaultBootstrapView candidate = IAsyncTrancheVaultBootstrapView(vault);
        require(candidate.POOL() == housePool, "TrancheVault pool mismatch");
        require(candidate.IS_SENIOR() == isSenior, "TrancheVault side mismatch");
        require(candidate.LP_REQUEST_CUTOFF_DURATION() == 5 minutes, "Unexpected LP request cutoff duration");
        require(candidate.asset() == usdc, "TrancheVault asset mismatch");
        require(candidate.share() == vault, "TrancheVault share mismatch");
        require(candidate.supportsInterface(ERC165_INTERFACE_ID), "TrancheVault missing ERC165");
        require(candidate.supportsInterface(ERC7540_OPERATOR_INTERFACE_ID), "TrancheVault missing ERC7540 operator");
        require(candidate.supportsInterface(ERC7575_INTERFACE_ID), "TrancheVault missing ERC7575");
        require(candidate.supportsInterface(ERC7575_SHARE_INTERFACE_ID), "TrancheVault missing ERC7575 share lookup");
        require(candidate.supportsInterface(ERC7540_DEPOSIT_INTERFACE_ID), "TrancheVault missing async deposit");
        require(candidate.supportsInterface(ERC7540_REDEEM_INTERFACE_ID), "TrancheVault missing async redeem");
        require(
            candidate.supportsInterface(type(IAsyncTrancheVault).interfaceId),
            "TrancheVault missing custom async interface"
        );
        require(
            candidate.supportsInterface(type(IAsyncTrancheVaultClaimableRedeem).interfaceId),
            "TrancheVault missing claimable redeem interface"
        );
        require(!candidate.supportsInterface(0xffffffff), "TrancheVault accepts invalid ERC165 id");
        require(candidate.vault(usdc) == vault, "TrancheVault share lookup mismatch");
        require(
            candidate.maintenanceFeeAprBps() == expectedMaintenanceFeeAprBps,
            "TrancheVault maintenance fee APR mismatch"
        );
        require(
            candidate.maintenanceFeeRecipient() == expectedMaintenanceFeeRecipient,
            "TrancheVault maintenance fee recipient mismatch"
        );
        require(candidate.maintenanceFeeConfigActivationTime() == 0, "Outstanding maintenance fee proposal");
        (uint256 pendingAprBps, address pendingRecipient) = candidate.pendingMaintenanceFeeConfig();
        require(pendingAprBps == 0 && pendingRecipient == address(0), "Pending maintenance fee config is not empty");
        if (requireZeroPendingFeeShares) {
            require(candidate.pendingMaintenanceFeeShares() == 0, "Pending maintenance fee shares must be zero");
            require(candidate.accruedTotalSupply() == candidate.totalSupply(), "Accrued supply must equal raw supply");
        }
        (nextRequestEpoch, nextRequestCutoffTime) = candidate.getRequestEpochWindow();
    }

    function _validateReleaseInputs(
        uint256 seniorSeedUsdc,
        uint256 juniorSeedUsdc,
        address seniorSeedReceiver,
        address juniorSeedReceiver
    ) internal pure {
        require(seniorSeedUsdc == RELEASE_SENIOR_SEED_USDC, "Unexpected senior seed");
        require(juniorSeedUsdc == RELEASE_JUNIOR_SEED_USDC, "Unexpected junior seed");
        require(seniorSeedReceiver != address(0), "SENIOR_SEED_RECEIVER is zero");
        require(juniorSeedReceiver != address(0), "JUNIOR_SEED_RECEIVER is zero");
    }

    function _validateGuardian(
        address guardian
    ) internal pure {
        require(guardian != address(0), "PERPS_GUARDIAN is zero");
    }

    function _configureGuardian(
        EmergencyPauseCoordinator coordinator,
        address desiredGuardian,
        address broadcaster
    ) internal {
        _validateGuardian(desiredGuardian);
        if (coordinator.guardian() == desiredGuardian) {
            return;
        }
        require(coordinator.owner() == broadcaster, "Broadcaster is not emergency coordinator owner");
        coordinator.setGuardian(desiredGuardian);
        require(coordinator.guardian() == desiredGuardian, "Emergency guardian update failed");
        console.log("Set emergency guardian:", desiredGuardian);
    }

    function _seedLifecycle(
        HousePool housePool,
        IMintableERC20 usdc,
        uint256 seniorSeedUsdc,
        uint256 juniorSeedUsdc,
        address seniorSeedReceiver,
        address juniorSeedReceiver,
        address seedFunder
    ) internal {
        uint256 totalSeedUsdc;
        if (!housePool.seniorSeedInitialized() && seniorSeedUsdc > 0) {
            totalSeedUsdc += seniorSeedUsdc;
        }
        if (!housePool.juniorSeedInitialized() && juniorSeedUsdc > 0) {
            totalSeedUsdc += juniorSeedUsdc;
        }

        if (totalSeedUsdc > 0) {
            usdc.mint(seedFunder, totalSeedUsdc);
            usdc.approve(address(housePool), totalSeedUsdc);
            console.log("Minted seed USDC to broadcaster:", seedFunder);
            console.log("Seed USDC amount:", totalSeedUsdc);
        }

        if (!housePool.juniorSeedInitialized() && juniorSeedUsdc > 0) {
            housePool.initializeSeedPosition(false, juniorSeedUsdc, juniorSeedReceiver);
            console.log("Initialized junior seed:", juniorSeedUsdc);
            console.log("Junior seed receiver:", juniorSeedReceiver);
        }

        if (!housePool.seniorSeedInitialized() && seniorSeedUsdc > 0) {
            housePool.initializeSeedPosition(true, seniorSeedUsdc, seniorSeedReceiver);
            console.log("Initialized senior seed:", seniorSeedUsdc);
            console.log("Senior seed receiver:", seniorSeedReceiver);
        }
    }

    function _fundTestUsers(
        IMintableERC20 usdc,
        address[] memory testUsers,
        uint256[] memory testUserAmounts
    ) internal {
        for (uint256 i; i < testUsers.length; ++i) {
            if (testUsers[i] == address(0) || testUserAmounts[i] == 0) {
                continue;
            }
            usdc.mint(testUsers[i], testUserAmounts[i]);
            console.log("Funded test user:", testUsers[i]);
            console.log("Amount:", testUserAmounts[i]);
        }
    }

    function _activateTrading(
        HousePool housePool,
        OrderRouterAdmin routerAdmin,
        EmergencyPauseCoordinator coordinator,
        bool activateTrading
    ) internal {
        if (!activateTrading || housePool.isTradingActive()) {
            return;
        }

        require(coordinator.guardian() != address(0), "Emergency guardian is disabled");
        require(housePool.pauser() == address(coordinator), "HousePool pauser changed before activation");
        require(routerAdmin.pauser() == address(coordinator), "Router pauser changed before activation");
        require(!housePool.paused(), "HousePool is paused");
        require(!housePool.lpEpochSettlementPaused(), "LP epoch settlement is paused");
        require(!routerAdmin.paused(), "OrderRouterAdmin is paused");

        if (!housePool.seniorSeedInitialized() || !housePool.juniorSeedInitialized()) {
            revert("Cannot activate trading before both seeds exist");
        }

        housePool.activateTrading();
        console.log("Activated trading");
    }

}
