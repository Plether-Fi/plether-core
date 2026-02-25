// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {VaultAdapter} from "../src/VaultAdapter.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {MarketParams} from "../src/interfaces/IMorpho.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {PythAdapter} from "../src/oracles/PythAdapter.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
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

}

/**
 * @title DeployToMainnet
 * @notice Production deployment script for Plether protocol on Ethereum mainnet
 * @dev Deploys all contracts in correct dependency order:
 *      0. PythAdapter (SEK/USD)
 *      1. BasketOracle
 *      2. MorphoAdapter + SyntheticSplitter
 *      3. Push Pyth price update (SEK/USD is pull-based)
 *      4. Query oracle for BEAR price
 *      5. Curve pool (initialized at live oracle price)
 *      6. Configure BasketOracle with Curve pool
 *      7-12. MorphoOracles, StakedTokens, StakedOracles, Routers
 */
contract DeployToMainnet is Script {

    // ==========================================
    // MAINNET ADDRESSES
    // ==========================================

    // Chainlink Price Feeds (Mainnet)
    address constant CHAINLINK_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    address constant CHAINLINK_JPY_USD = 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3;
    address constant CHAINLINK_GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address constant CHAINLINK_CAD_USD = 0xa34317DB73e77d453b1B8d04550c44D10e981C8e;
    // SEK/USD: No Chainlink feed on mainnet - use PythAdapter
    address constant CHAINLINK_CHF_USD = 0x449d117117838fFA61263B61dA6301AA2a88B13A;

    // Pyth Configuration (Ethereum Mainnet)
    address constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    // USD/SEK price ID (inverted to get SEK/USD)
    bytes32 constant USD_SEK_PRICE_ID = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;
    uint256 constant PYTH_MAX_STALENESS = 72 hours;

    // L2 Sequencer Uptime Feed (address(0) for L1 mainnet)
    address constant SEQUENCER_UPTIME_FEED = address(0);

    // Stablecoins
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Curve Twocrypto-NG Factory on Mainnet
    address constant TWOCRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;

    // Morpho Blue (also provides fee-free flash loans)
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC; // AdaptiveCurveIrm

    // MetaMorpho Vault (Gauntlet USDC Frontier)
    address constant METAMORPHO_VAULT = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e;

    // Protocol Parameters
    uint256 constant CAP = 2 * 10 ** 8; // $2.00 cap (8 decimals)
    uint256 constant LLTV_BEAR = 0.915e18; // 91.5% LLTV for BEAR market (allows up to ~11.7x leverage)
    uint256 constant LLTV_BULL = 0.915e18; // 91.5% LLTV for BULL market (allows up to ~11.7x leverage)
    uint256 constant MAX_DEVIATION_BPS = 200; // 2% max deviation for basket oracle

    // Curve Pool Parameters (optimized for low slippage)
    uint256 constant CURVE_A = 320_000;
    uint256 constant CURVE_GAMMA = 2_000_000_000_000_000; // 2e15 (0.002)
    uint256 constant CURVE_MID_FEE = 4_000_000; // 0.04%
    uint256 constant CURVE_OUT_FEE = 20_000_000; // 0.2%
    uint256 constant CURVE_FEE_GAMMA = 1_000_000_000_000_000; // 1e15
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2_000_000_000_000;
    uint256 constant CURVE_ADJUSTMENT_STEP = 146_000_000_000_000;
    uint256 constant CURVE_MA_EXP_TIME = 600;

    // ==========================================
    // DEPLOYMENT STATE
    // ==========================================

    struct DeployedContracts {
        PythAdapter sekPythAdapter;
        BasketOracle basketOracle;
        VaultAdapter vaultAdapter;
        SyntheticSplitter splitter;
        SyntheticToken plDxyBear;
        SyntheticToken plDxyBull;
        address curvePool;
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
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address treasury = vm.envAddress("TREASURY");

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("");

        vm.startBroadcast(privateKey);

        // ==========================================
        // STEP 0: Deploy PythAdapter for SEK/USD (inverts USD/SEK from Pyth)
        // ==========================================
        deployed.sekPythAdapter = new PythAdapter(PYTH, USD_SEK_PRICE_ID, PYTH_MAX_STALENESS, "SEK / USD", true, 500);
        console.log("PythAdapter (SEK/USD) deployed:", address(deployed.sekPythAdapter));

        // ==========================================
        // STEP 1: Deploy BasketOracle (without Curve pool)
        // ==========================================
        deployed.basketOracle = _deployBasketOracle(deployer, address(deployed.sekPythAdapter));
        console.log("BasketOracle deployed:", address(deployed.basketOracle));

        // ==========================================
        // STEP 2: Deploy VaultAdapter + SyntheticSplitter
        // ==========================================
        (deployed.vaultAdapter, deployed.splitter) =
            _deploySplitterWithAdapter(address(deployed.basketOracle), treasury, deployer);

        // Get token addresses from Splitter
        deployed.plDxyBear = deployed.splitter.BEAR();
        deployed.plDxyBull = deployed.splitter.BULL();
        console.log("plDXY-BEAR deployed:", address(deployed.plDxyBear));
        console.log("plDXY-BULL deployed:", address(deployed.plDxyBull));

        // ==========================================
        // STEP 3: Push fresh Pyth price (SEK/USD feed is pull-based)
        // ==========================================
        // Advance timestamp so Pyth's publishTime < block.timestamp in simulation.
        // No-op in real broadcast — vm.warp is a foundry cheat code only.
        vm.stopBroadcast();
        vm.warp(block.timestamp + 600);
        vm.startBroadcast(privateKey);
        bytes memory rawUpdateData = vm.envBytes("PYTH_UPDATE_DATA");
        bytes[] memory updateData = abi.decode(rawUpdateData, (bytes[]));
        uint256 pythFee = IPyth(PYTH).getUpdateFee(updateData);
        IPyth(PYTH).updatePriceFeeds{value: pythFee}(updateData);
        console.log("Pyth prices updated (fee: %s wei)", pythFee);

        // ==========================================
        // STEP 4: Get basket price from oracle for Curve initial price
        // ==========================================
        (, int256 answer,,,) = deployed.basketOracle.latestRoundData();
        uint256 bearPrice = uint256(answer) * 1e10;
        console.log("BEAR price (18 decimals):", bearPrice);

        // ==========================================
        // STEP 5: Deploy Curve pool via factory
        // ==========================================
        deployed.curvePool = _deployCurvePool(address(deployed.plDxyBear), bearPrice);
        console.log("Curve Pool deployed:", deployed.curvePool);

        // ==========================================
        // STEP 6: Configure BasketOracle with Curve pool
        // ==========================================
        deployed.basketOracle.setCurvePool(deployed.curvePool);
        console.log("BasketOracle configured with Curve pool");

        // ==========================================
        // STEP 7: Deploy Morpho Oracles
        // ==========================================
        deployed.morphoOracleBear = new MorphoOracle(
            address(deployed.basketOracle),
            CAP,
            false // BEAR: NOT inverse
        );

        deployed.morphoOracleBull = new MorphoOracle(
            address(deployed.basketOracle),
            CAP,
            true // BULL: IS inverse
        );

        // ==========================================
        // STEP 8: Deploy Staked Tokens
        // ==========================================
        deployed.stakedBear = new StakedToken(IERC20(address(deployed.plDxyBear)), "Staked plDXY-BEAR", "splDXY-BEAR");
        deployed.stakedBull = new StakedToken(IERC20(address(deployed.plDxyBull)), "Staked plDXY-BULL", "splDXY-BULL");

        // ==========================================
        // STEP 9: Deploy Staked Oracles
        // ==========================================
        deployed.stakedOracleBear = new StakedOracle(address(deployed.stakedBear), address(deployed.morphoOracleBear));
        deployed.stakedOracleBull = new StakedOracle(address(deployed.stakedBull), address(deployed.morphoOracleBull));

        // ==========================================
        // STEP 10: Deploy ZapRouter
        // ==========================================
        deployed.zapRouter = new ZapRouter(
            address(deployed.splitter),
            address(deployed.plDxyBear),
            address(deployed.plDxyBull),
            USDC,
            deployed.curvePool
        );

        // ==========================================
        // STEP 11: Deploy LeverageRouter (BEAR leverage)
        // ==========================================
        MarketParams memory bearMarketParams = MarketParams({
            loanToken: USDC,
            collateralToken: address(deployed.stakedBear),
            oracle: address(deployed.stakedOracleBear),
            irm: MORPHO_IRM,
            lltv: LLTV_BEAR
        });

        deployed.leverageRouter = new LeverageRouter(
            MORPHO_BLUE,
            deployed.curvePool,
            USDC,
            address(deployed.plDxyBear),
            address(deployed.stakedBear),
            bearMarketParams
        );

        // ==========================================
        // STEP 12: Deploy BullLeverageRouter
        // ==========================================
        MarketParams memory bullMarketParams = MarketParams({
            loanToken: USDC,
            collateralToken: address(deployed.stakedBull),
            oracle: address(deployed.stakedOracleBull),
            irm: MORPHO_IRM,
            lltv: LLTV_BULL
        });

        deployed.bullLeverageRouter = new BullLeverageRouter(
            MORPHO_BLUE,
            address(deployed.splitter),
            deployed.curvePool,
            USDC,
            address(deployed.plDxyBear),
            address(deployed.plDxyBull),
            address(deployed.stakedBull),
            bullMarketParams,
            SEQUENCER_UPTIME_FEED
        );

        // Log market IDs for deployments JSON
        console.log("Morpho BEAR market ID:");
        console.logBytes32(keccak256(abi.encode(bearMarketParams)));
        console.log("Morpho BULL market ID:");
        console.logBytes32(keccak256(abi.encode(bullMarketParams)));

        vm.stopBroadcast();

        // ==========================================
        // LOG DEPLOYED ADDRESSES
        // ==========================================
        _logDeployment(deployed);

        // ==========================================
        // VERIFY DEPLOYMENT
        // ==========================================
        _verifyDeployment(deployed);

        return deployed;
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _deployBasketOracle(
        address owner,
        address sekPythAdapter
    ) internal returns (BasketOracle) {
        address[] memory feeds = new address[](6);
        feeds[0] = CHAINLINK_EUR_USD;
        feeds[1] = CHAINLINK_JPY_USD;
        feeds[2] = CHAINLINK_GBP_USD;
        feeds[3] = CHAINLINK_CAD_USD;
        feeds[4] = sekPythAdapter; // PythAdapter for SEK/USD
        feeds[5] = CHAINLINK_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // EUR: 57.6%
        quantities[1] = 136 * 10 ** 15; // JPY: 13.6%
        quantities[2] = 119 * 10 ** 15; // GBP: 11.9%
        quantities[3] = 91 * 10 ** 15; // CAD: 9.1%
        quantities[4] = 42 * 10 ** 15; // SEK: 4.2%
        quantities[5] = 36 * 10 ** 15; // CHF: 3.6%

        // Base prices for normalization (8 decimals, January 1, 2026 reference)
        uint256[] memory basePrices = new uint256[](6);
        basePrices[0] = 117_500_000; // EUR: $1.1750
        basePrices[1] = 638_000; // JPY: $0.00638
        basePrices[2] = 134_480_000; // GBP: $1.3448
        basePrices[3] = 72_880_000; // CAD: $0.7288
        basePrices[4] = 10_860_000; // SEK: $0.1086
        basePrices[5] = 126_100_000; // CHF: $1.2610

        return new BasketOracle(feeds, quantities, basePrices, MAX_DEVIATION_BPS, CAP, owner);
    }

    function _deployCurvePool(
        address plDxyBear,
        uint256 initialPrice
    ) internal returns (address) {
        return ITwocryptoFactory(TWOCRYPTO_FACTORY)
            .deploy_pool(
                "Curve.fi USDC/plDXY-BEAR",
                "crvUSDCplDXYBEAR",
                [USDC, plDxyBear],
                0,
                CURVE_A,
                CURVE_GAMMA,
                CURVE_MID_FEE,
                CURVE_OUT_FEE,
                CURVE_FEE_GAMMA,
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_EXP_TIME,
                initialPrice
            );
    }

    function _deploySplitterWithAdapter(
        address oracle,
        address treasury,
        address deployer
    ) internal returns (VaultAdapter adapter, SyntheticSplitter splitter) {
        // Predict Splitter address (deployed 1 nonce after adapter)
        uint64 nonce = vm.getNonce(deployer);
        address predictedSplitter = vm.computeCreateAddress(deployer, nonce + 1);

        // Deploy adapter with predicted splitter address
        adapter = new VaultAdapter(IERC20(USDC), METAMORPHO_VAULT, deployer, predictedSplitter);

        // Deploy splitter
        splitter = new SyntheticSplitter(oracle, USDC, address(adapter), CAP, treasury, SEQUENCER_UPTIME_FEED);

        // Verify prediction was correct
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");
    }

    function _logDeployment(
        DeployedContracts memory d
    ) internal pure {
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("  PythAdapter (SEK):   ", address(d.sekPythAdapter));
        console.log("  BasketOracle:        ", address(d.basketOracle));
        console.log("  VaultAdapter:        ", address(d.vaultAdapter));
        console.log("  SyntheticSplitter:   ", address(d.splitter));
        console.log("  plDXY-BEAR:          ", address(d.plDxyBear));
        console.log("  plDXY-BULL:          ", address(d.plDxyBull));
        console.log("  Curve Pool:          ", d.curvePool);
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

    function _verifyDeployment(
        DeployedContracts memory d
    ) internal view {
        console.log("");
        console.log("Verifying deployment...");

        // Check Splitter state
        require(address(d.splitter.BEAR()) == address(d.plDxyBear), "BEAR token mismatch");
        require(address(d.splitter.BULL()) == address(d.plDxyBull), "BULL token mismatch");
        require(d.splitter.CAP() == CAP, "CAP mismatch");

        // Check token ownership
        require(d.plDxyBear.SPLITTER() == address(d.splitter), "BEAR SPLITTER wrong");
        require(d.plDxyBull.SPLITTER() == address(d.splitter), "BULL SPLITTER wrong");

        // Check staked tokens
        require(address(d.stakedBear.asset()) == address(d.plDxyBear), "StakedBear asset wrong");
        require(address(d.stakedBull.asset()) == address(d.plDxyBull), "StakedBull asset wrong");

        // Check router CAPs match
        require(d.zapRouter.CAP() == CAP, "ZapRouter CAP wrong");

        console.log("All verifications passed!");
    }

}
