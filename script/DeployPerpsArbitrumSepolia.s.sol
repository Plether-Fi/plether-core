// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";
import {SettlementMonitorLensSidecar} from "@plether/perps/SettlementMonitorLensSidecar.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import "forge-std/Script.sol";

/// @dev Minimal deployment-time compatibility surface. Keeping this local makes the deploy script fail closed when
///      one vault comes from the legacy synchronous generation.
interface IAsyncTrancheVaultDeploymentView {

    function POOL() external view returns (address);
    function IS_SENIOR() external view returns (bool);
    function LP_REQUEST_CUTOFF_DURATION() external view returns (uint256);
    function asset() external view returns (address);
    function share() external view returns (address);
    function getRequestEpochWindow() external view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);
    function vault(
        address asset_
    ) external view returns (address);
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);

}

/// @dev Minimal immutable-binding surface for the Router-deployed position-protection book.
interface IPositionProtectionBookDeploymentView {

    function ROUTER() external view returns (address);
    function ENGINE() external view returns (address);

}

contract DeployPerpsArbitrumSepolia is Script {

    address internal constant PYTH = 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF;
    uint32 internal constant CAP_PRICE = 2e8;
    uint256 internal constant FROZEN_CLOSE_SPREAD_BPS = 50;

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 internal constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 internal constant ERC7575_SHARE_INTERFACE_ID = 0xf815c03d;
    bytes4 internal constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    bytes4 internal constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    bytes32 internal constant PYTH_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 internal constant PYTH_USD_JPY = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant PYTH_GBP_USD = 0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1;
    bytes32 internal constant PYTH_USD_CAD = 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;
    bytes32 internal constant PYTH_USD_SEK = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;
    bytes32 internal constant PYTH_USD_CHF = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;

    uint256 internal constant WEIGHT_EUR = 576 * 10 ** 15;
    uint256 internal constant WEIGHT_JPY = 136 * 10 ** 15;
    uint256 internal constant WEIGHT_GBP = 119 * 10 ** 15;
    uint256 internal constant WEIGHT_CAD = 91 * 10 ** 15;
    uint256 internal constant WEIGHT_SEK = 42 * 10 ** 15;
    uint256 internal constant WEIGHT_CHF = 36 * 10 ** 15;

    uint256 internal constant BASE_EUR_USD = 117_500_000;
    uint256 internal constant BASE_JPY_USD = 638_000;
    uint256 internal constant BASE_GBP_USD = 134_480_000;
    uint256 internal constant BASE_CAD_USD = 72_880_000;
    uint256 internal constant BASE_SEK_USD = 10_860_000;
    uint256 internal constant BASE_CHF_USD = 126_100_000;

    struct DeployedContracts {
        MockUSDC usdc;
        MarginClearinghouse clearinghouse;
        CfdEngine engine;
        TerminalNavBookV2 terminalNavBook;
        CfdEnginePlanner planner;
        CfdEngineSettlementSidecar settlementSidecar;
        CfdEngineAdmin engineAdmin;
        HousePool housePool;
        TrancheVault seniorVault;
        TrancheVault juniorVault;
        CfdEngineAccountLens accountLens;
        CfdEngineLens engineLens;
        OrderRouter router;
        OrderRouterLiquidationBatchSidecar liquidationBatchSidecar;
        address positionProtectionBook;
        address pletherOracle;
        address routerAdmin;
        PerpsPublicLens publicLens;
        SettlementMonitorLens settlementMonitorLens;
        SettlementMonitorLensSidecar settlementMonitorLensSidecar;
        EmergencyPauseCoordinator emergencyPauseCoordinator;
    }

    function run() external returns (DeployedContracts memory deployed) {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deploying Plether perps to Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("Pyth:", PYTH);
        require(PYTH.code.length > 0, "Pyth has no code");

        vm.startBroadcast(privateKey);

        deployed.usdc = new MockUSDC();
        deployed.clearinghouse = new MarginClearinghouse(address(deployed.usdc));
        deployed.engine = new CfdEngine(
            address(deployed.usdc), address(deployed.clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        deployed.terminalNavBook = new TerminalNavBookV2(address(deployed.engine), CAP_PRICE);
        deployed.engine.setTerminalNavBook(address(deployed.terminalNavBook));

        deployed.planner = new CfdEnginePlanner();
        deployed.settlementSidecar = new CfdEngineSettlementSidecar(address(deployed.engine));
        deployed.engineAdmin = new CfdEngineAdmin(address(deployed.engine), deployer);
        deployed.engine
            .setDependencies(
                address(deployed.planner), address(deployed.settlementSidecar), address(deployed.engineAdmin)
            );

        deployed.housePool = new HousePool(address(deployed.usdc), address(deployed.engine));
        deployed.seniorVault = new TrancheVault(
            IERC20(address(deployed.usdc)), address(deployed.housePool), true, "Plether Senior LP", "psLP"
        );
        deployed.juniorVault = new TrancheVault(
            IERC20(address(deployed.usdc)), address(deployed.housePool), false, "Plether Junior LP", "pjLP"
        );

        deployed.housePool.setSeniorVault(address(deployed.seniorVault));
        deployed.housePool.setJuniorVault(address(deployed.juniorVault));
        _verifyAsyncVaultPair(deployed.housePool, deployed.seniorVault, deployed.juniorVault, deployed.usdc);
        deployed.engine.setPool(address(deployed.housePool));

        deployed.accountLens = new CfdEngineAccountLens(address(deployed.engine));
        deployed.engineLens = new CfdEngineLens(address(deployed.engine));
        deployed.pletherOracle = address(
            new PletherOracle(
                address(deployed.engine),
                address(deployed.housePool),
                PYTH,
                _pythFeedIds(),
                _quantities(),
                _basePrices(),
                _inversions()
            )
        );
        uint64 sidecarNonce = vm.getNonce(deployer);
        address expectedRouter = vm.computeCreateAddress(deployer, uint256(sidecarNonce) + 1);
        deployed.liquidationBatchSidecar = new OrderRouterLiquidationBatchSidecar(expectedRouter);
        deployed.router = new OrderRouter(
            address(deployed.engine),
            address(deployed.engineLens),
            address(deployed.housePool),
            deployed.pletherOracle,
            address(deployed.liquidationBatchSidecar)
        );
        require(address(deployed.router) == expectedRouter, "OrderRouter CREATE address mismatch");
        deployed.positionProtectionBook = _verifyPositionProtectionBook(deployed.router, deployed.engine);
        deployed.routerAdmin = deployed.router.admin();

        deployed.engine.setOrderRouter(address(deployed.router));
        deployed.clearinghouse.setEngine(address(deployed.engine));
        require(deployed.engine.orderRouter() == address(deployed.router), "Engine OrderRouter mismatch");
        require(
            address(PletherOracle(deployed.pletherOracle).engine()) == address(deployed.engine),
            "PletherOracle Engine mismatch"
        );
        require(
            address(PletherOracle(deployed.pletherOracle).housePool()) == address(deployed.housePool),
            "PletherOracle HousePool mismatch"
        );

        deployed.publicLens = new PerpsPublicLens(
            address(deployed.accountLens),
            address(deployed.engine),
            address(deployed.router),
            address(deployed.housePool)
        );
        deployed.settlementMonitorLens = new SettlementMonitorLens(address(deployed.router));
        deployed.settlementMonitorLensSidecar = deployed.settlementMonitorLens.SIDECAR();
        require(
            address(deployed.settlementMonitorLensSidecar).code.length > 0, "SettlementMonitorLens Sidecar has no code"
        );
        require(
            address(deployed.settlementMonitorLens.ROUTER()) == address(deployed.router),
            "SettlementMonitorLens Router mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.ENGINE()) == address(deployed.engine),
            "SettlementMonitorLens Engine mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.HOUSE_POOL()) == address(deployed.housePool),
            "SettlementMonitorLens HousePool mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.ENGINE_PROTOCOL_LENS())
                == address(deployed.housePool.ENGINE_PROTOCOL_LENS()),
            "SettlementMonitorLens ProtocolLens mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.CLEARINGHOUSE()) == address(deployed.clearinghouse),
            "SettlementMonitorLens Clearinghouse mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.TERMINAL_NAV_BOOK()) == address(deployed.terminalNavBook),
            "SettlementMonitorLens TerminalNavBook mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.SENIOR_VAULT()) == address(deployed.seniorVault),
            "SettlementMonitorLens SeniorVault mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.JUNIOR_VAULT()) == address(deployed.juniorVault),
            "SettlementMonitorLens JuniorVault mismatch"
        );
        require(
            address(deployed.settlementMonitorLens.USDC()) == address(deployed.usdc),
            "SettlementMonitorLens USDC mismatch"
        );
        require(
            deployed.settlementMonitorLensSidecar.MONITOR() == address(deployed.settlementMonitorLens),
            "SettlementMonitorLens Sidecar monitor mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.ROUTER()) == address(deployed.router),
            "SettlementMonitorLens Sidecar Router mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.ENGINE()) == address(deployed.engine),
            "SettlementMonitorLens Sidecar Engine mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.HOUSE_POOL()) == address(deployed.housePool),
            "SettlementMonitorLens Sidecar HousePool mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.ENGINE_PROTOCOL_LENS())
                == address(deployed.housePool.ENGINE_PROTOCOL_LENS()),
            "SettlementMonitorLens Sidecar ProtocolLens mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.CLEARINGHOUSE()) == address(deployed.clearinghouse),
            "SettlementMonitorLens Sidecar Clearinghouse mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.TERMINAL_NAV_BOOK()) == address(deployed.terminalNavBook),
            "SettlementMonitorLens Sidecar TerminalNavBook mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.SENIOR_VAULT()) == address(deployed.seniorVault),
            "SettlementMonitorLens Sidecar SeniorVault mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.JUNIOR_VAULT()) == address(deployed.juniorVault),
            "SettlementMonitorLens Sidecar JuniorVault mismatch"
        );
        require(
            address(deployed.settlementMonitorLensSidecar.USDC()) == address(deployed.usdc),
            "SettlementMonitorLens Sidecar USDC mismatch"
        );

        deployed.emergencyPauseCoordinator =
            new EmergencyPauseCoordinator(deployed.routerAdmin, address(deployed.housePool), deployer);
        require(address(deployed.emergencyPauseCoordinator).code.length > 0, "Emergency coordinator has no code");
        require(
            address(deployed.emergencyPauseCoordinator.ROUTER_ADMIN()) == deployed.routerAdmin,
            "Emergency coordinator RouterAdmin mismatch"
        );
        require(
            address(deployed.emergencyPauseCoordinator.HOUSE_POOL()) == address(deployed.housePool),
            "Emergency coordinator HousePool mismatch"
        );
        require(deployed.emergencyPauseCoordinator.owner() == deployer, "Emergency coordinator owner mismatch");
        require(deployed.emergencyPauseCoordinator.guardian() == address(0), "Emergency guardian must start disabled");
        require(
            deployed.emergencyPauseCoordinator.ROUTER_ADMIN().riskOffOrderCutoff() == 0,
            "Unexpected initial risk-off cutoff"
        );
        require(!deployed.emergencyPauseCoordinator.ROUTER_ADMIN().paused(), "OrderRouterAdmin unexpectedly paused");
        require(!deployed.emergencyPauseCoordinator.HOUSE_POOL().paused(), "HousePool unexpectedly paused");

        deployed.housePool.setPauser(address(deployed.emergencyPauseCoordinator));
        deployed.emergencyPauseCoordinator.ROUTER_ADMIN().setPauser(address(deployed.emergencyPauseCoordinator));
        require(
            deployed.housePool.pauser() == address(deployed.emergencyPauseCoordinator),
            "HousePool emergency coordinator mismatch"
        );
        require(
            deployed.emergencyPauseCoordinator.ROUTER_ADMIN().pauser() == address(deployed.emergencyPauseCoordinator),
            "OrderRouterAdmin emergency coordinator mismatch"
        );

        vm.stopBroadcast();

        _logDeployment(deployed);
        console.log("Trading remains inactive until finite senior limits complete their HousePool timelock,");
        console.log("junior and senior seed positions are initialized, and HousePool.activateTrading() is called.");
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 30,
            initMarginBps: 45,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _pythFeedIds() internal pure returns (bytes32[] memory feedIds) {
        feedIds = new bytes32[](6);
        feedIds[0] = PYTH_EUR_USD;
        feedIds[1] = PYTH_USD_JPY;
        feedIds[2] = PYTH_GBP_USD;
        feedIds[3] = PYTH_USD_CAD;
        feedIds[4] = PYTH_USD_SEK;
        feedIds[5] = PYTH_USD_CHF;
    }

    function _quantities() internal pure returns (uint256[] memory quantities) {
        quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;
    }

    function _basePrices() internal pure returns (uint256[] memory basePrices) {
        basePrices = new uint256[](6);
        basePrices[0] = BASE_EUR_USD;
        basePrices[1] = BASE_JPY_USD;
        basePrices[2] = BASE_GBP_USD;
        basePrices[3] = BASE_CAD_USD;
        basePrices[4] = BASE_SEK_USD;
        basePrices[5] = BASE_CHF_USD;
    }

    function _inversions() internal pure returns (bool[] memory inversions) {
        inversions = new bool[](6);
        inversions[1] = true;
        inversions[3] = true;
        inversions[4] = true;
        inversions[5] = true;
    }

    /// @dev Rejects missing, misbound, aliased, or mixed-generation Router helper contracts before set-once wiring
    ///      completes.
    function _verifyPositionProtectionBook(
        OrderRouter router,
        CfdEngine engine
    ) internal view returns (address book) {
        book = address(router.positionProtectionBook());
        require(book != address(0), "PositionProtectionBook is not wired");
        require(book.code.length > 0, "PositionProtectionBook has no code");
        address sidecar = router.liquidationBatchSidecar();
        require(sidecar != address(0), "OrderRouter sidecar is not wired");
        require(sidecar.code.length > 0, "OrderRouter sidecar has no code");
        require(sidecar != book, "OrderRouter sidecar aliases PositionProtectionBook");
        require(
            OrderRouterLiquidationBatchSidecar(sidecar).ROUTER() == address(router),
            "OrderRouter sidecar router mismatch"
        );
        IPositionProtectionBookDeploymentView candidate = IPositionProtectionBookDeploymentView(book);
        require(candidate.ROUTER() == address(router), "PositionProtectionBook router mismatch");
        require(candidate.ENGINE() == address(engine), "PositionProtectionBook engine mismatch");
    }

    /// @dev Rejects partial or mixed-generation LP stacks before any engine/router wiring is completed.
    function _verifyAsyncVaultPair(
        HousePool housePool,
        TrancheVault seniorVault,
        TrancheVault juniorVault,
        MockUSDC usdc
    ) internal view {
        require(address(seniorVault) != address(juniorVault), "HousePool vault pair is duplicated");
        require(housePool.seniorVault() == address(seniorVault), "HousePool senior vault mismatch");
        require(housePool.juniorVault() == address(juniorVault), "HousePool junior vault mismatch");
        require(address(housePool.USDC()) == address(usdc), "HousePool asset mismatch");
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

        (uint256 seniorNextRequestEpoch, uint256 seniorNextRequestCutoffTime) =
            _verifyAsyncVault(address(seniorVault), address(housePool), address(usdc), true);
        (uint256 juniorNextRequestEpoch, uint256 juniorNextRequestCutoffTime) =
            _verifyAsyncVault(address(juniorVault), address(housePool), address(usdc), false);
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
        bool isSenior
    ) internal view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime) {
        IAsyncTrancheVaultDeploymentView candidate = IAsyncTrancheVaultDeploymentView(vault);
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
        require(!candidate.supportsInterface(0xffffffff), "TrancheVault accepts invalid ERC165 id");
        require(candidate.vault(usdc) == vault, "TrancheVault share lookup mismatch");
        (nextRequestEpoch, nextRequestCutoffTime) = candidate.getRequestEpochWindow();
    }

    function _logDeployment(
        DeployedContracts memory deployed
    ) internal view {
        console.log("");
        console.log("MockUSDC:", address(deployed.usdc));
        console.log("MarginClearinghouse:", address(deployed.clearinghouse));
        console.log("CfdEngine:", address(deployed.engine));
        console.log("TerminalNavBookV2:", address(deployed.terminalNavBook));
        console.log("PositionSizeQuantum:", deployed.terminalNavBook.SIZE_QUANTUM());
        console.log("FrozenCloseSpreadBps:", deployed.engine.frozenCloseSpreadBps());
        console.log("FadRunwaySeconds:", deployed.engine.fadRunwaySeconds());
        console.log("CfdEnginePlanner:", address(deployed.planner));
        console.log("CfdEngineSettlementSidecar:", address(deployed.settlementSidecar));
        console.log("CfdEngineAdmin:", address(deployed.engineAdmin));
        console.log("HousePool:", address(deployed.housePool));
        console.log("LpEpochDuration:", deployed.housePool.LP_EPOCH_DURATION());
        console.log("MaxLpEpochsPerPhase:", deployed.housePool.MAX_LP_EPOCHS_PER_PHASE());
        console.log("CurrentLpEpoch:", deployed.housePool.currentLpEpoch());
        console.log("SeniorVault:", address(deployed.seniorVault));
        console.log("JuniorVault:", address(deployed.juniorVault));
        console.log("CfdEngineAccountLens:", address(deployed.accountLens));
        console.log("CfdEngineLens:", address(deployed.engineLens));
        console.log("OrderRouter:", address(deployed.router));
        console.log("OrderRouterLiquidationBatchSidecar:", address(deployed.liquidationBatchSidecar));
        console.log("PositionProtectionBook:", deployed.positionProtectionBook);
        console.log("PositionProtectionCommitsEnabled:", deployed.router.positionProtectionCommitsEnabled());
        console.log("PositionProtectionTriggerBountyUsdc:", deployed.router.positionProtectionTriggerBountyUsdc());
        console.log("PletherOracle:", deployed.pletherOracle);
        console.log("BasketMaxConfidenceRatioBps:", PletherOracle(deployed.pletherOracle).basketMaxConfidenceRatioBps());
        console.log("OrderRouterAdmin:", deployed.routerAdmin);
        console.log("PerpsPublicLens:", address(deployed.publicLens));
        console.log("SettlementMonitorLens:", address(deployed.settlementMonitorLens));
        console.log("SettlementMonitorLensSidecar:", address(deployed.settlementMonitorLensSidecar));
        console.log("EmergencyPauseCoordinator:", address(deployed.emergencyPauseCoordinator));
        console.log("Emergency guardian:", deployed.emergencyPauseCoordinator.guardian());
        console.log("Risk-off order cutoff:", deployed.emergencyPauseCoordinator.ROUTER_ADMIN().riskOffOrderCutoff());
        console.log("Owner:", deployed.engineAdmin.owner());
    }

}

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}
