// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import "forge-std/Script.sol";

/**
 * @title RedeployOraclesAndRouters
 * @notice Redeploys StakedOracles (bug fix: 1e18→1e21 divisor) + Morpho markets + Leverage routers.
 * @dev Existing contracts that stay unchanged:
 *      - SyntheticSplitter, BEAR/BULL tokens, StakedBear/Bull, BasketOracle, MorphoOracles
 *      - ZapRouter, VaultAdapter, CurvePool
 *
 *      Run (dry):
 *        source .env && forge script script/RedeployOraclesAndRouters.s.sol --tc RedeployOraclesAndRouters \
 *          --rpc-url $MAINNET_RPC_URL
 *
 *      Run (broadcast):
 *        source .env && forge script script/RedeployOraclesAndRouters.s.sol --tc RedeployOraclesAndRouters \
 *          --rpc-url $MAINNET_RPC_URL --broadcast
 */
contract RedeployOraclesAndRouters is Script {

    // ==========================================
    // EXISTING MAINNET ADDRESSES (unchanged)
    // ==========================================
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant SEQUENCER_UPTIME_FEED = address(0); // L1 mainnet

    address constant SPLITTER = 0x45c1135fab0A0532cC2945f6b0b31eA12B54A2f9;
    address constant PLDXY_BEAR = 0x5503FB45370a03909dFfEB207483a2832A9171aD;
    address constant PLDXY_BULL = 0xf5aeecdF9778a5801C0873088d25E4d7E3Bf07Ab;
    address constant STAKED_BEAR = 0xDC7366b8BB83f9ABa2B4F989194D6c03D0A20DE9;
    address constant STAKED_BULL = 0x8dbcF452799f50D3382105a19FdBfA57B7f29C73;
    address constant MORPHO_ORACLE_BEAR = 0x7c5fa969E5583C39C1D40d537E57917d88Ef5884;
    address constant MORPHO_ORACLE_BULL = 0x3Bc9C811089444ee82336678da04c38A1a9A61EC;
    address constant CURVE_POOL = 0x95D51D6F312DbE66BACC2ed677aD64790f48aa87;

    uint256 constant LLTV = 0.915e18; // 91.5%

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(privateKey);

        // ==========================================
        // STEP 1: Deploy fixed StakedOracles
        // ==========================================
        StakedOracle stakedOracleBear = new StakedOracle(STAKED_BEAR, MORPHO_ORACLE_BEAR);
        StakedOracle stakedOracleBull = new StakedOracle(STAKED_BULL, MORPHO_ORACLE_BULL);

        console.log("StakedOracleBear:", address(stakedOracleBear));
        console.log("StakedOracleBull:", address(stakedOracleBull));

        // Verify fix: SHARE_DECIMALS should be 1e21 (not 1e18)
        require(stakedOracleBear.SHARE_DECIMALS() == 1e21, "BEAR oracle decimals wrong");
        require(stakedOracleBull.SHARE_DECIMALS() == 1e21, "BULL oracle decimals wrong");

        // ==========================================
        // STEP 2: Create new Morpho markets
        // ==========================================
        MarketParams memory bearMarket = MarketParams({
            loanToken: USDC,
            collateralToken: STAKED_BEAR,
            oracle: address(stakedOracleBear),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        MarketParams memory bullMarket = MarketParams({
            loanToken: USDC,
            collateralToken: STAKED_BULL,
            oracle: address(stakedOracleBull),
            irm: MORPHO_IRM,
            lltv: LLTV
        });

        IMorpho(MORPHO_BLUE).createMarket(bearMarket);
        IMorpho(MORPHO_BLUE).createMarket(bullMarket);

        bytes32 bearMarketId = keccak256(abi.encode(bearMarket));
        bytes32 bullMarketId = keccak256(abi.encode(bullMarket));

        console.log("Morpho BEAR market ID:");
        console.logBytes32(bearMarketId);
        console.log("Morpho BULL market ID:");
        console.logBytes32(bullMarketId);

        // ==========================================
        // STEP 3: Deploy LeverageRouter (BEAR)
        // ==========================================
        LeverageRouter leverageRouter =
            new LeverageRouter(MORPHO_BLUE, CURVE_POOL, USDC, PLDXY_BEAR, STAKED_BEAR, bearMarket);

        console.log("LeverageRouter:", address(leverageRouter));

        // ==========================================
        // STEP 4: Deploy BullLeverageRouter
        // ==========================================
        BullLeverageRouter bullLeverageRouter = new BullLeverageRouter(
            MORPHO_BLUE,
            SPLITTER,
            CURVE_POOL,
            USDC,
            PLDXY_BEAR,
            PLDXY_BULL,
            STAKED_BULL,
            bullMarket,
            SEQUENCER_UPTIME_FEED
        );

        console.log("BullLeverageRouter:", address(bullLeverageRouter));

        vm.stopBroadcast();

        // ==========================================
        // VERIFICATION
        // ==========================================
        console.log("");
        console.log("========================================");
        console.log("REDEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("New contracts:");
        console.log("  StakedOracleBear:    ", address(stakedOracleBear));
        console.log("  StakedOracleBull:    ", address(stakedOracleBull));
        console.log("  LeverageRouter:      ", address(leverageRouter));
        console.log("  BullLeverageRouter:  ", address(bullLeverageRouter));
        console.log("");
        console.log("Update deployments/mainnet.json with:");
        console.log("  - StakedOracleBear, StakedOracleBull addresses");
        console.log("  - MorphoMarketBear, MorphoMarketBull IDs (above)");
        console.log("  - LeverageRouter, BullLeverageRouter addresses");
        console.log("========================================");

        // Sanity: oracle prices should be reasonable (not 1000x off)
        uint256 bearPrice = stakedOracleBear.price();
        uint256 bullPrice = stakedOracleBull.price();
        console.log("StakedOracleBear price:", bearPrice);
        console.log("StakedOracleBull price:", bullPrice);
        require(bearPrice > 0 && bearPrice < 2e36, "BEAR price out of range");
        require(bullPrice > 0 && bullPrice < 2e36, "BULL price out of range");
    }

}
