// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {MockYieldAdapter} from "../test/utils/MockYieldAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

// Curve Twocrypto-NG Factory interface
interface ITwocryptoFactory {

    function deploy_pool(
        string memory _name,
        string memory _symbol,
        address[2] memory _coins,
        uint256 implementation_id,
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 fee_gamma,
        uint256 allowed_extra_profit,
        uint256 adjustment_step,
        uint256 ma_exp_time,
        uint256 initial_price
    ) external returns (address);

}

// Curve Twocrypto pool interface for adding liquidity
interface ICurveTwocryptoPool {

    function add_liquidity(
        uint256[2] memory amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    function token() external view returns (address);

}

// Mock USDC with 6 decimals and public mint for testnet
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

// Mock AggregatorV3Interface for testing on Sepolia (since fiat feeds may not be available)
contract MockV3Aggregator is AggregatorV3Interface {

    int256 private immutable _price;

    constructor(
        int256 price_
    ) {
        _price = price_;
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

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, block.timestamp, 0);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, block.timestamp, 0);
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

    // Curve Twocrypto-NG Factory on Sepolia
    address constant TWOCRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;

    // Morpho Blue on Sepolia
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    // Protocol Parameters
    uint256 constant CAP = 2 * 10 ** 8; // $2.00 cap (8 decimals)
    uint256 constant LLTV = 0.77e18; // 77% LLTV
    uint256 constant MAX_DEVIATION_BPS = 200; // 2% max deviation
    uint256 constant MORPHO_LIQUIDITY = 100_000 * 1e6; // 100k USDC per market

    // Curve Pool Parameters (optimized for low-volatility DXY pair)
    // Must match test/fork/BaseForkTest.sol for consistent behavior
    // MAX_A for twocrypto-ng = N_COINS^2 * A_MULTIPLIER * 1000 = 4 * 10000 * 1000 = 40M
    uint256 constant CURVE_A = 20_000_000; // High amplification for tight concentration
    uint256 constant CURVE_GAMMA = 1_000_000_000_000_000; // 1e15
    uint256 constant CURVE_MID_FEE = 2_500_000; // 0.025% (1e10 = 100%)
    uint256 constant CURVE_OUT_FEE = 30_000_000; // 0.3% (1e10 = 100%)
    uint256 constant CURVE_FEE_GAMMA = 1_000_000_000_000_000; // 1e15
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2_000_000_000_000; // 2e12
    uint256 constant CURVE_ADJUSTMENT_STEP = 146_000_000_000_000; // 1.46e14
    uint256 constant CURVE_MA_HALF_TIME = 600; // 10 minutes (matches fork test)

    // CAP scaled to 18 decimals for Curve price calculations
    // CAP = 2e8 (8 decimals) -> 2e18 (18 decimals)
    uint256 constant CAP_SCALED = 2e18;

    // ==========================================
    // DEPLOYMENT STATE
    // ==========================================

    struct DeployedContracts {
        MockUSDC usdc;
        address curvePool;
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
        ZapRouter zapRouter;
        LeverageRouter leverageRouter;
        BullLeverageRouter bullLeverageRouter;
    }

    function run() external returns (DeployedContracts memory deployed) {
        uint256 privateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(privateKey);

        // Step 1: Deploy MockUSDC
        deployed.usdc = new MockUSDC();
        console.log("MockUSDC deployed:", address(deployed.usdc));

        // Step 2: Deploy mock Chainlink feeds
        (address[] memory feeds, uint256[] memory quantities) = _deployMockFeeds();

        // Step 3: Deploy BasketOracle (without Curve pool - will be set later)
        deployed.basketOracle = new BasketOracle(feeds, quantities, MAX_DEVIATION_BPS, CAP, deployer);
        console.log("BasketOracle deployed:", address(deployed.basketOracle));

        // Step 4: Deploy Adapter + Splitter (creates DXY-BEAR/BULL)
        (deployed.adapter, deployed.splitter) =
            _deploySplitterWithAdapter(address(deployed.basketOracle), address(deployed.usdc), deployer);
        deployed.dxyBear = deployed.splitter.TOKEN_A();
        deployed.dxyBull = deployed.splitter.TOKEN_B();
        console.log("DXY-BEAR deployed:", address(deployed.dxyBear));
        console.log("DXY-BULL deployed:", address(deployed.dxyBull));

        // Step 5: Calculate bearPrice from oracle (CAP - DXY)
        (, int256 answer,,,) = deployed.basketOracle.latestRoundData();
        uint256 dxyPrice = uint256(answer) * 1e10;
        uint256 bearPrice = CAP_SCALED - dxyPrice;
        console.log("DXY price (18 decimals):", dxyPrice);
        console.log("BEAR price (18 decimals):", bearPrice);

        // Step 6: Deploy Curve pool with real DXY-BEAR address and calculated price
        deployed.curvePool = _deployCurvePool(address(deployed.usdc), address(deployed.dxyBear), bearPrice);
        console.log("Curve Pool deployed:", deployed.curvePool);

        // Step 7: Configure BasketOracle with Curve pool
        deployed.basketOracle.setCurvePool(deployed.curvePool);
        console.log("BasketOracle configured with Curve pool");

        // Step 8: Seed Curve pool with initial liquidity
        _seedCurvePool(deployed, deployer, bearPrice);

        // Step 9: Deploy Morpho Oracles
        (deployed.morphoOracleBear, deployed.morphoOracleBull) = _deployMorphoOracles(address(deployed.basketOracle));

        // Step 10: Deploy Staked Tokens
        (deployed.stakedBear, deployed.stakedBull) =
            _deployStakedTokens(address(deployed.dxyBear), address(deployed.dxyBull));

        // Step 11: Deploy Staked Oracles
        (deployed.stakedOracleBear, deployed.stakedOracleBull) = _deployStakedOracles(
            address(deployed.stakedBear),
            address(deployed.stakedBull),
            address(deployed.morphoOracleBear),
            address(deployed.morphoOracleBull)
        );

        // Step 12: Deploy Routers
        _deployRouters(deployed);

        // Step 13: Mint USDC to deployer for testing
        deployed.usdc.mint(deployer, 100_000 * 1e6);
        console.log("Minted 100,000 USDC to deployer");

        vm.stopBroadcast();

        // Log deployment
        _logDeployment(deployed);

        return deployed;
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _deployMockFeeds() internal returns (address[] memory feeds, uint256[] memory quantities) {
        feeds = new address[](6);
        feeds[0] = address(new MockV3Aggregator(105_000_000)); // ~1.05 USD per EUR
        feeds[1] = address(new MockV3Aggregator(640_000)); // ~0.0064 USD per JPY
        feeds[2] = address(new MockV3Aggregator(125_000_000)); // ~1.25 USD per GBP
        feeds[3] = address(new MockV3Aggregator(73_000_000)); // ~0.73 USD per CAD
        feeds[4] = address(new MockV3Aggregator(9_300_000)); // ~0.093 USD per SEK
        feeds[5] = address(new MockV3Aggregator(113_000_000)); // ~1.13 USD per CHF

        quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // EUR: 57.6%
        quantities[1] = 136 * 10 ** 15; // JPY: 13.6%
        quantities[2] = 119 * 10 ** 15; // GBP: 11.9%
        quantities[3] = 91 * 10 ** 15; // CAD: 9.1%
        quantities[4] = 42 * 10 ** 15; // SEK: 4.2%
        quantities[5] = 36 * 10 ** 15; // CHF: 3.6%
    }

    function _deployCurvePool(
        address usdc,
        address dxyBear,
        uint256 initialPrice
    ) internal returns (address pool) {
        pool = ITwocryptoFactory(TWOCRYPTO_FACTORY)
            .deploy_pool(
                "Curve.fi USDC/DXY-BEAR",
                "crvUSDCDXYBEAR",
                [usdc, dxyBear],
                0, // implementation_id (use default)
                CURVE_A,
                CURVE_GAMMA,
                CURVE_MID_FEE,
                CURVE_OUT_FEE,
                CURVE_FEE_GAMMA,
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_HALF_TIME,
                initialPrice
            );
    }

    function _deploySplitterWithAdapter(
        address oracle,
        address usdc,
        address deployer
    ) internal returns (MockYieldAdapter adapter, SyntheticSplitter splitter) {
        uint64 nonce = vm.getNonce(deployer);
        address predictedSplitter = vm.computeCreateAddress(deployer, nonce + 1);

        adapter = new MockYieldAdapter(IERC20(usdc), deployer, predictedSplitter);
        splitter = new SyntheticSplitter(oracle, usdc, address(adapter), CAP, deployer, address(0));

        require(address(splitter) == predictedSplitter, "Splitter address mismatch in helper");
    }

    function _seedCurvePool(
        DeployedContracts memory d,
        address deployer,
        uint256 bearPrice
    ) internal {
        uint256 bearLiquidity = 800_000e18;
        uint256 usdcAmount = (bearLiquidity * bearPrice) / 1e18 / 1e12;

        d.usdc.mint(deployer, usdcAmount);

        (uint256 mintCost,,) = d.splitter.previewMint(bearLiquidity);
        d.usdc.mint(deployer, mintCost);
        d.usdc.approve(address(d.splitter), mintCost);
        d.splitter.mint(bearLiquidity);

        d.usdc.approve(d.curvePool, usdcAmount);
        IERC20(address(d.dxyBear)).approve(d.curvePool, bearLiquidity);

        ICurveTwocryptoPool(d.curvePool).add_liquidity([usdcAmount, bearLiquidity], 0);
        console.log("Curve pool seeded: %s USDC + %s DXY-BEAR", usdcAmount / 1e6, bearLiquidity / 1e18);
    }

    function _deployMorphoOracles(
        address basketOracle
    ) internal returns (MorphoOracle oracleBear, MorphoOracle oracleBull) {
        oracleBear = new MorphoOracle(basketOracle, CAP, false);
        oracleBull = new MorphoOracle(basketOracle, CAP, true);
    }

    function _deployStakedTokens(
        address bearToken,
        address bullToken
    ) internal returns (StakedToken stakedBear, StakedToken stakedBull) {
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

    function _deployRouters(
        DeployedContracts memory d
    ) internal {
        MarketParams memory bearMarketParams;
        MarketParams memory bullMarketParams;
        // Deploy ZapRouter
        d.zapRouter =
            new ZapRouter(address(d.splitter), address(d.dxyBear), address(d.dxyBull), address(d.usdc), d.curvePool);
        console.log("ZapRouter:", address(d.zapRouter));

        // Deploy LeverageRouter (BEAR)
        bearMarketParams = MarketParams({
            loanToken: address(d.usdc),
            collateralToken: address(d.stakedBear),
            oracle: address(d.stakedOracleBear),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        d.leverageRouter = new LeverageRouter(
            MORPHO_BLUE, d.curvePool, address(d.usdc), address(d.dxyBear), address(d.stakedBear), bearMarketParams
        );
        console.log("LeverageRouter:", address(d.leverageRouter));

        // Deploy BullLeverageRouter
        bullMarketParams = MarketParams({
            loanToken: address(d.usdc),
            collateralToken: address(d.stakedBull),
            oracle: address(d.stakedOracleBull),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        d.bullLeverageRouter = new BullLeverageRouter(
            MORPHO_BLUE,
            address(d.splitter),
            d.curvePool,
            address(d.usdc),
            address(d.dxyBear),
            address(d.dxyBull),
            address(d.stakedBull),
            bullMarketParams
        );
        console.log("BullLeverageRouter:", address(d.bullLeverageRouter));
    }

    function _createMorphoMarkets(
        MarketParams memory bearMarketParams,
        MarketParams memory bullMarketParams
    ) internal {
        IMorpho morpho = IMorpho(MORPHO_BLUE);

        // Create BEAR market (sDXY-BEAR as collateral, USDC as loan token)
        morpho.createMarket(bearMarketParams);
        console.log("Morpho BEAR market created");

        // Create BULL market (sDXY-BULL as collateral, USDC as loan token)
        morpho.createMarket(bullMarketParams);
        console.log("Morpho BULL market created");
    }

    function _seedMorphoMarkets(
        DeployedContracts memory d,
        address deployer,
        MarketParams memory bearMarketParams,
        MarketParams memory bullMarketParams
    ) internal {
        IMorpho morpho = IMorpho(MORPHO_BLUE);

        // Mint USDC for Morpho liquidity (100k per market = 200k total)
        uint256 totalLiquidity = MORPHO_LIQUIDITY * 2;
        d.usdc.mint(deployer, totalLiquidity);
        d.usdc.approve(MORPHO_BLUE, totalLiquidity);

        // Supply to BEAR market
        morpho.supply(bearMarketParams, MORPHO_LIQUIDITY, 0, deployer, "");
        console.log("Morpho BEAR market seeded with 100k USDC");

        // Supply to BULL market
        morpho.supply(bullMarketParams, MORPHO_LIQUIDITY, 0, deployer, "");
        console.log("Morpho BULL market seeded with 100k USDC");
    }

    function _logDeployment(
        DeployedContracts memory d
    ) internal pure {
        console.log("========================================");
        console.log("SEPOLIA DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("Infrastructure:");
        console.log("  MockUSDC:            ", address(d.usdc));
        console.log("  Curve Pool:          ", d.curvePool);
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
        console.log("");
        console.log("Routers:");
        console.log("  ZapRouter:           ", address(d.zapRouter));
        console.log("  LeverageRouter:      ", address(d.leverageRouter));
        console.log("  BullLeverageRouter:  ", address(d.bullLeverageRouter));
        console.log("========================================");
    }

}
