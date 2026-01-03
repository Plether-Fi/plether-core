// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {MockYieldAdapter} from "../test/utils/MockYieldAdapter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MarketParams} from "../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock AggregatorV3Interface for testing on Sepolia (since fiat feeds may not be available)
contract MockV3Aggregator is AggregatorV3Interface {
    int256 private immutable _price;
    uint256 private immutable _updatedAt;

    constructor(int256 price_) {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, _updatedAt, 0);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, _updatedAt, 0);
    }
}

/**
 * @title DeployToSepolia
 * @notice Deployment script for Plether protocol on Sepolia testnet
 * @dev Deploys all contracts in correct dependency order using mock adapters
 */
contract DeployToSepolia is Script {
    // ==========================================
    // SEPOLIA ADDRESSES
    // ==========================================

    // USDC address on Sepolia
    address constant USDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;

    // Curve Pool address on Sepolia (placeholder - update with actual pool)
    address constant CURVE_POOL = address(0x1); // TODO: Replace with actual Curve pool

    // Morpho Blue on Sepolia (same as mainnet, also provides fee-free flash loans)
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    // Protocol Parameters
    uint256 constant CAP = 2 * 10 ** 8; // $2.00 cap (8 decimals)
    uint256 constant LLTV = 0.77e18; // 77% LLTV
    uint256 constant MAX_DEVIATION_BPS = 200; // 2% max deviation

    // ==========================================
    // DEPLOYMENT STATE
    // ==========================================

    struct DeployedContracts {
        BasketOracle basketOracle;
        MockYieldAdapter adapter;
        SyntheticSplitter splitter;
        SyntheticToken dxyBear;
        SyntheticToken dxyBull;
        MorphoOracle morphoOracleBear;
        MorphoOracle morphoOracleBull;
        StakedToken stakedBear;
        StakedToken stakedBull;
        StakedOracle stakedOracleBear;
        StakedOracle stakedOracleBull;
    }

    function run() external returns (DeployedContracts memory deployed) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(privateKey);

        // Step 1: Deploy BasketOracle with mock feeds
        deployed.basketOracle = _deployBasketOracle();

        // Step 2: Deploy MockAdapter + Splitter
        (deployed.adapter, deployed.splitter) = _deploySplitterWithAdapter(address(deployed.basketOracle), deployer);

        // Get token references
        deployed.dxyBear = deployed.splitter.TOKEN_A();
        deployed.dxyBull = deployed.splitter.TOKEN_B();

        // Step 3: Deploy Morpho Oracles
        (deployed.morphoOracleBear, deployed.morphoOracleBull) = _deployMorphoOracles(address(deployed.basketOracle));

        // Step 4: Deploy Staked Tokens
        (deployed.stakedBear, deployed.stakedBull) =
            _deployStakedTokens(address(deployed.dxyBear), address(deployed.dxyBull));

        // Step 5: Deploy Staked Oracles
        (deployed.stakedOracleBear, deployed.stakedOracleBull) = _deployStakedOracles(
            address(deployed.stakedBear),
            address(deployed.stakedBull),
            address(deployed.morphoOracleBear),
            address(deployed.morphoOracleBull)
        );

        // Step 6: Deploy Routers (only if Curve pool is available)
        _deployRouters(deployed, deployer);

        vm.stopBroadcast();

        // Log deployment
        _logDeployment(deployed);

        return deployed;
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _deployBasketOracle() internal returns (BasketOracle) {
        // Deploy mock Chainlink feeds for DXY components
        address[] memory feeds = new address[](6);
        feeds[0] = address(new MockV3Aggregator(105000000)); // ~1.05 USD per EUR
        feeds[1] = address(new MockV3Aggregator(640000)); // ~0.0064 USD per JPY
        feeds[2] = address(new MockV3Aggregator(125000000)); // ~1.25 USD per GBP
        feeds[3] = address(new MockV3Aggregator(73000000)); // ~0.73 USD per CAD
        feeds[4] = address(new MockV3Aggregator(9300000)); // ~0.093 USD per SEK
        feeds[5] = address(new MockV3Aggregator(113000000)); // ~1.13 USD per CHF

        // DXY weights (scaled to 1e18)
        uint256[] memory quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // EUR: 57.6%
        quantities[1] = 136 * 10 ** 15; // JPY: 13.6%
        quantities[2] = 119 * 10 ** 15; // GBP: 11.9%
        quantities[3] = 91 * 10 ** 15; // CAD: 9.1%
        quantities[4] = 42 * 10 ** 15; // SEK: 4.2%
        quantities[5] = 36 * 10 ** 15; // CHF: 3.6%

        return new BasketOracle(feeds, quantities, CURVE_POOL, MAX_DEVIATION_BPS);
    }

    function _deploySplitterWithAdapter(address oracle, address deployer)
        internal
        returns (MockYieldAdapter adapter, SyntheticSplitter splitter)
    {
        // Predict Splitter address (deployed 1 nonce after adapter)
        uint64 nonce = vm.getNonce(deployer);
        address predictedSplitter = vm.computeCreateAddress(deployer, nonce + 1);

        // Deploy adapter with predicted splitter address
        adapter = new MockYieldAdapter(IERC20(USDC), deployer, predictedSplitter);

        // Deploy splitter (sequencer uptime feed = address(0) for L1)
        splitter = new SyntheticSplitter(oracle, USDC, address(adapter), CAP, deployer, address(0));

        // Verify prediction was correct
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");
    }

    function _deployMorphoOracles(address basketOracle)
        internal
        returns (MorphoOracle oracleBear, MorphoOracle oracleBull)
    {
        oracleBear = new MorphoOracle(basketOracle, CAP, false); // BEAR: NOT inverse
        oracleBull = new MorphoOracle(basketOracle, CAP, true); // BULL: IS inverse
    }

    function _deployStakedTokens(address bearToken, address bullToken)
        internal
        returns (StakedToken stakedBear, StakedToken stakedBull)
    {
        stakedBear = new StakedToken(IERC20(bearToken), "Staked DXY-BEAR", "sDXY-BEAR");
        stakedBull = new StakedToken(IERC20(bullToken), "Staked DXY-BULL", "sDXY-BULL");
    }

    function _deployStakedOracles(
        address stakedBear,
        address stakedBull,
        address morphoOracleBear,
        address morphoOracleBull
    ) internal returns (StakedOracle oracleBear, StakedOracle oracleBull) {
        oracleBear = new StakedOracle(stakedBear, morphoOracleBear);
        oracleBull = new StakedOracle(stakedBull, morphoOracleBull);
    }

    function _deployRouters(DeployedContracts memory d, address deployer) internal {
        if (CURVE_POOL == address(0x1)) {
            console.log("ZapRouter: SKIPPED (no Curve pool)");
            console.log("LeverageRouter: SKIPPED (no Curve pool)");
            console.log("BullLeverageRouter: SKIPPED (no Curve pool)");
            return;
        }

        // Deploy ZapRouter
        ZapRouter zapRouter =
            new ZapRouter(address(d.splitter), address(d.dxyBear), address(d.dxyBull), USDC, CURVE_POOL);
        console.log("ZapRouter:", address(zapRouter));

        // Deploy LeverageRouter (BEAR)
        MarketParams memory bearMarketParams = MarketParams({
            loanToken: USDC,
            collateralToken: address(d.stakedBear),
            oracle: address(d.stakedOracleBear),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        LeverageRouter leverageRouter = new LeverageRouter(
            MORPHO_BLUE, CURVE_POOL, USDC, address(d.dxyBear), address(d.stakedBear), bearMarketParams
        );
        console.log("LeverageRouter:", address(leverageRouter));

        // Deploy BullLeverageRouter
        MarketParams memory bullMarketParams = MarketParams({
            loanToken: USDC,
            collateralToken: address(d.stakedBull),
            oracle: address(d.stakedOracleBull),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        BullLeverageRouter bullLeverageRouter = new BullLeverageRouter(
            MORPHO_BLUE,
            address(d.splitter),
            CURVE_POOL,
            USDC,
            address(d.dxyBear),
            address(d.dxyBull),
            address(d.stakedBull),
            bullMarketParams
        );
        console.log("BullLeverageRouter:", address(bullLeverageRouter));
    }

    function _logDeployment(DeployedContracts memory d) internal pure {
        console.log("========================================");
        console.log("SEPOLIA DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("  BasketOracle:        ", address(d.basketOracle));
        console.log("  MockAdapter:         ", address(d.adapter));
        console.log("  SyntheticSplitter:   ", address(d.splitter));
        console.log("  DXY-BEAR:            ", address(d.dxyBear));
        console.log("  DXY-BULL:            ", address(d.dxyBull));
        console.log("");
        console.log("Morpho Oracles:");
        console.log("  MorphoOracle (BEAR): ", address(d.morphoOracleBear));
        console.log("  MorphoOracle (BULL): ", address(d.morphoOracleBull));
        console.log("");
        console.log("Staking:");
        console.log("  StakedToken (BEAR):  ", address(d.stakedBear));
        console.log("  StakedToken (BULL):  ", address(d.stakedBull));
        console.log("  StakedOracle (BEAR): ", address(d.stakedOracleBear));
        console.log("  StakedOracle (BULL): ", address(d.stakedOracleBull));
        console.log("========================================");
    }
}
