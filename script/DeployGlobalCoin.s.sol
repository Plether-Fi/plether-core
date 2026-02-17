// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

/// @title DeployInvarCoin
/// @notice Deploys InvarCoin (INVAR) and StakedInvarCoin (sINVAR) with mainnet addresses.
/// @dev Run (dry):
///        source .env && forge script script/DeployGlobalCoin.s.sol --tc DeployInvarCoin \
///          --rpc-url $MAINNET_RPC_URL
///
///      Run (broadcast):
///        source .env && forge script script/DeployGlobalCoin.s.sol --tc DeployInvarCoin \
///          --rpc-url $MAINNET_RPC_URL --broadcast
contract DeployInvarCoin is Script {

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PLDXY_BEAR = 0x5503FB45370a03909dFfEB207483a2832A9171aD;
    address constant CURVE_LP_TOKEN = address(0); // TODO: Set twocrypto-ng LP token address
    address constant CURVE_POOL = 0x95D51D6F312DbE66BACC2ed677aD64790f48aa87;
    address constant BASKET_ORACLE = 0x4f798422388484F2139717A8cE0115De3B06b1DF;
    address constant SEQUENCER_UPTIME_FEED = address(0); // L1: no sequencer feed

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        require(CURVE_LP_TOKEN != address(0), "Set CURVE_LP_TOKEN address before deploying");

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(privateKey);

        InvarCoin ic = new InvarCoin(USDC, PLDXY_BEAR, CURVE_LP_TOKEN, CURVE_POOL, BASKET_ORACLE, SEQUENCER_UPTIME_FEED);

        StakedToken sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");

        vm.stopBroadcast();

        require(address(ic.USDC()) == USDC, "USDC mismatch");
        require(address(ic.CURVE_POOL()) == CURVE_POOL, "CURVE_POOL mismatch");
        require(sInvar.asset() == address(ic), "sINVAR asset mismatch");

        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("  InvarCoin (INVAR):", address(ic));
        console.log("  StakedInvarCoin (sINVAR):", address(sInvar));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Verify both contracts on Etherscan");
        console.log("  2. Call ic.setIntegrations(rewardDistributor, sINVAR)");
        console.log("  3. Transfer ownership if needed");
        console.log("  4. Test deposit/deploy/harvest cycle");
        console.log("========================================");
    }

}
