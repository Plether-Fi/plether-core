// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {MorphoAdapter} from "../src/MorphoAdapter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {MarketParams} from "../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployToMainnet
 * @notice Production deployment script for Plether protocol on Ethereum mainnet
 * @dev Deploys all 12 contracts in correct dependency order:
 *      1. BasketOracle
 *      2. MorphoAdapter (with predicted Splitter address)
 *      3. SyntheticSplitter (creates DXY-BEAR and DXY-BULL)
 *      4. MorphoOracle (BEAR variant)
 *      5. MorphoOracle (BULL variant)
 *      6. StakedToken (BEAR)
 *      7. StakedToken (BULL)
 *      8. StakedOracle (BEAR)
 *      9. StakedOracle (BULL)
 *      10. ZapRouter
 *      11. LeverageRouter (BEAR leverage)
 *      12. BullLeverageRouter (BULL leverage)
 */
contract DeployToMainnet is Script {
    // ==========================================
    // MAINNET ADDRESSES
    // ==========================================

    // Chainlink Price Feeds (Mainnet)
    // Note: These are USD/XXX feeds, we need XXX/USD so we invert in BasketOracle
    address constant CHAINLINK_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    address constant CHAINLINK_JPY_USD = 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3;
    address constant CHAINLINK_GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address constant CHAINLINK_CAD_USD = 0xa34317DB73e77d453b1B8d04550c44D10e981C8e;
    address constant CHAINLINK_SEK_USD = 0x803a123F84E77A13C69459F0C8952d7d5a6f1B8c; // Note: May need verification
    address constant CHAINLINK_CHF_USD = 0x449d117117838fFA61263B61dA6301AA2a88B13A;

    // L2 Sequencer Uptime Feed (address(0) for L1 mainnet)
    address constant SEQUENCER_UPTIME_FEED = address(0);

    // Stablecoins
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Curve Pool (USDC/DXY-BEAR) - To be deployed or use existing
    address constant CURVE_POOL = address(0); // TODO: Set after Curve pool deployment

    // Morpho Blue
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC; // AdaptiveCurveIrm

    // Aave V3 (for flash loans)
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // Protocol Parameters
    uint256 constant CAP = 2 * 10 ** 8; // $2.00 cap (8 decimals)
    uint256 constant LLTV_BEAR = 0.77e18; // 77% LLTV for BEAR market
    uint256 constant LLTV_BULL = 0.77e18; // 77% LLTV for BULL market
    uint256 constant MAX_DEVIATION_BPS = 200; // 2% max deviation for basket oracle

    // ==========================================
    // DEPLOYMENT STATE
    // ==========================================

    struct DeployedContracts {
        BasketOracle basketOracle;
        MorphoAdapter morphoAdapter;
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
        // Validate critical addresses
        require(CURVE_POOL != address(0), "Curve pool address not set");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address treasury = vm.envOr("TREASURY", deployer);

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("");

        vm.startBroadcast(privateKey);

        // ==========================================
        // STEP 1: Deploy BasketOracle
        // ==========================================
        deployed.basketOracle = _deployBasketOracle();

        // ==========================================
        // STEP 2: Deploy MorphoAdapter + SyntheticSplitter
        // ==========================================
        (deployed.morphoAdapter, deployed.splitter) =
            _deploySplitterWithAdapter(address(deployed.basketOracle), treasury, deployer);

        // Get token addresses from Splitter
        deployed.dxyBear = deployed.splitter.TOKEN_A();
        deployed.dxyBull = deployed.splitter.TOKEN_B();

        // ==========================================
        // STEP 3: Deploy Morpho Oracles
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
        // STEP 4: Deploy Staked Tokens
        // ==========================================
        deployed.stakedBear = new StakedToken(IERC20(address(deployed.dxyBear)), "Staked DXY-BEAR", "sDXY-BEAR");

        deployed.stakedBull = new StakedToken(IERC20(address(deployed.dxyBull)), "Staked DXY-BULL", "sDXY-BULL");

        // ==========================================
        // STEP 5: Deploy Staked Oracles
        // ==========================================
        deployed.stakedOracleBear = new StakedOracle(address(deployed.stakedBear), address(deployed.morphoOracleBear));

        deployed.stakedOracleBull = new StakedOracle(address(deployed.stakedBull), address(deployed.morphoOracleBull));

        // ==========================================
        // STEP 6: Deploy ZapRouter
        // ==========================================
        deployed.zapRouter = new ZapRouter(
            address(deployed.splitter), address(deployed.dxyBear), address(deployed.dxyBull), USDC, CURVE_POOL
        );

        // ==========================================
        // STEP 7: Deploy LeverageRouter (BEAR leverage)
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
            CURVE_POOL,
            USDC,
            address(deployed.dxyBear),
            address(deployed.stakedBear),
            AAVE_POOL, // Flash lender
            bearMarketParams
        );

        // ==========================================
        // STEP 8: Deploy BullLeverageRouter
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
            CURVE_POOL,
            USDC,
            address(deployed.dxyBear),
            address(deployed.dxyBull),
            address(deployed.stakedBull),
            AAVE_POOL, // Flash lender
            bullMarketParams
        );

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

    function _deployBasketOracle() internal returns (BasketOracle) {
        address[] memory feeds = new address[](6);
        feeds[0] = CHAINLINK_EUR_USD;
        feeds[1] = CHAINLINK_JPY_USD;
        feeds[2] = CHAINLINK_GBP_USD;
        feeds[3] = CHAINLINK_CAD_USD;
        feeds[4] = CHAINLINK_SEK_USD;
        feeds[5] = CHAINLINK_CHF_USD;

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

    function _deploySplitterWithAdapter(address oracle, address treasury, address deployer)
        internal
        returns (MorphoAdapter adapter, SyntheticSplitter splitter)
    {
        // Predict Splitter address (deployed 1 nonce after adapter)
        uint64 nonce = vm.getNonce(deployer);
        address predictedSplitter = vm.computeCreateAddress(deployer, nonce + 1);

        // Create market params for adapter
        MarketParams memory adapterMarketParams = MarketParams({
            loanToken: USDC,
            collateralToken: USDC, // Same-asset lending for adapter
            oracle: address(0), // No oracle needed for same-asset
            irm: MORPHO_IRM,
            lltv: 0.945e18 // 94.5% for stablecoin market
        });

        // Deploy adapter with predicted splitter address
        adapter = new MorphoAdapter(IERC20(USDC), MORPHO_BLUE, adapterMarketParams, deployer, predictedSplitter);

        // Deploy splitter
        splitter = new SyntheticSplitter(oracle, USDC, address(adapter), CAP, treasury, SEQUENCER_UPTIME_FEED);

        // Verify prediction was correct
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");
    }

    function _logDeployment(DeployedContracts memory d) internal pure {
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("  BasketOracle:        ", address(d.basketOracle));
        console.log("  MorphoAdapter:       ", address(d.morphoAdapter));
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

    function _verifyDeployment(DeployedContracts memory d) internal view {
        console.log("");
        console.log("Verifying deployment...");

        // Check Splitter state
        require(address(d.splitter.TOKEN_A()) == address(d.dxyBear), "BEAR token mismatch");
        require(address(d.splitter.TOKEN_B()) == address(d.dxyBull), "BULL token mismatch");
        require(d.splitter.CAP() == CAP, "CAP mismatch");

        // Check token ownership
        require(d.dxyBear.SPLITTER() == address(d.splitter), "BEAR SPLITTER wrong");
        require(d.dxyBull.SPLITTER() == address(d.splitter), "BULL SPLITTER wrong");

        // Check staked tokens
        require(address(d.stakedBear.asset()) == address(d.dxyBear), "StakedBear asset wrong");
        require(address(d.stakedBull.asset()) == address(d.dxyBull), "StakedBull asset wrong");

        // Check router CAPs match
        require(d.zapRouter.CAP() == CAP, "ZapRouter CAP wrong");

        console.log("All verifications passed!");
    }
}
