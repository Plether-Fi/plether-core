// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {CfdEngine} from "../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "../src/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "../src/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementModule} from "../src/perps/CfdEngineSettlementModule.sol";
import {CfdTypes} from "../src/perps/CfdTypes.sol";
import {HousePool} from "../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../src/perps/OrderRouter.sol";
import {PerpsPublicLens} from "../src/perps/PerpsPublicLens.sol";
import {TrancheVault} from "../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

contract DeployPerpsArbitrumSepolia is Script {

    address internal constant PYTH = 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF;
    uint256 internal constant CAP_PRICE = 2e8;

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
        CfdEnginePlanner planner;
        CfdEngineSettlementModule settlementModule;
        CfdEngineAdmin engineAdmin;
        HousePool housePool;
        TrancheVault seniorVault;
        TrancheVault juniorVault;
        CfdEngineAccountLens accountLens;
        CfdEngineLens engineLens;
        OrderRouter router;
        address pletherOracle;
        address routerAdmin;
        PerpsPublicLens publicLens;
    }

    function run() external returns (DeployedContracts memory deployed) {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deploying Plether perps to Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("Pyth:", PYTH);

        vm.startBroadcast(privateKey);

        deployed.usdc = new MockUSDC();
        deployed.clearinghouse = new MarginClearinghouse(address(deployed.usdc));
        deployed.engine = new CfdEngine(address(deployed.usdc), address(deployed.clearinghouse), CAP_PRICE, _riskParams());

        deployed.planner = new CfdEnginePlanner();
        deployed.settlementModule = new CfdEngineSettlementModule(address(deployed.engine));
        deployed.engineAdmin = new CfdEngineAdmin(address(deployed.engine), deployer);
        deployed.engine.setDependencies(
            address(deployed.planner), address(deployed.settlementModule), address(deployed.engineAdmin)
        );

        deployed.housePool = new HousePool(address(deployed.usdc), address(deployed.engine));
        deployed.seniorVault =
            new TrancheVault(IERC20(address(deployed.usdc)), address(deployed.housePool), true, "Plether Senior LP", "psLP");
        deployed.juniorVault =
            new TrancheVault(IERC20(address(deployed.usdc)), address(deployed.housePool), false, "Plether Junior LP", "pjLP");

        deployed.housePool.setSeniorVault(address(deployed.seniorVault));
        deployed.housePool.setJuniorVault(address(deployed.juniorVault));
        deployed.engine.setVault(address(deployed.housePool));

        deployed.accountLens = new CfdEngineAccountLens(address(deployed.engine));
        deployed.engineLens = new CfdEngineLens(address(deployed.engine));
        deployed.router = new OrderRouter(
            address(deployed.engine),
            address(deployed.engineLens),
            address(deployed.housePool),
            PYTH,
            _pythFeedIds(),
            _quantities(),
            _basePrices(),
            _inversions()
        );
        deployed.pletherOracle = address(deployed.router.pletherOracle());
        deployed.routerAdmin = deployed.router.admin();

        deployed.engine.setOrderRouter(address(deployed.router));
        deployed.housePool.setOrderRouter(address(deployed.router));
        deployed.clearinghouse.setEngine(address(deployed.engine));

        deployed.publicLens = new PerpsPublicLens(
            address(deployed.accountLens), address(deployed.engine), address(deployed.router), address(deployed.housePool)
        );

        vm.stopBroadcast();

        _logDeployment(deployed);
        console.log("Trading remains inactive until seed positions are initialized and HousePool.activateTrading() is called.");
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
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

    function _logDeployment(
        DeployedContracts memory deployed
    ) internal view {
        console.log("");
        console.log("MockUSDC:", address(deployed.usdc));
        console.log("MarginClearinghouse:", address(deployed.clearinghouse));
        console.log("CfdEngine:", address(deployed.engine));
        console.log("CfdEnginePlanner:", address(deployed.planner));
        console.log("CfdEngineSettlementModule:", address(deployed.settlementModule));
        console.log("CfdEngineAdmin:", address(deployed.engineAdmin));
        console.log("HousePool:", address(deployed.housePool));
        console.log("SeniorVault:", address(deployed.seniorVault));
        console.log("JuniorVault:", address(deployed.juniorVault));
        console.log("CfdEngineAccountLens:", address(deployed.accountLens));
        console.log("CfdEngineLens:", address(deployed.engineLens));
        console.log("OrderRouter:", address(deployed.router));
        console.log("PletherOracle:", deployed.pletherOracle);
        console.log("OrderRouterAdmin:", deployed.routerAdmin);
        console.log("PerpsPublicLens:", address(deployed.publicLens));
        console.log("Owner:", deployed.engineAdmin.owner());
    }

}

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

}
