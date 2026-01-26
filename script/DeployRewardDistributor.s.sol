// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RewardDistributor} from "../src/RewardDistributor.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

/**
 * @title DeployRewardDistributor
 * @notice Deployment script for RewardDistributor contract
 * @dev Requires existing protocol deployment (Splitter, StakedTokens, ZapRouter, etc.)
 *
 * Usage:
 *   # Dry run (simulation)
 *   (source .env && forge script script/DeployRewardDistributor.s.sol --tc DeployRewardDistributor --rpc-url $SEPOLIA_RPC_URL)
 *
 *   # Actual deployment
 *   (source .env && forge script script/DeployRewardDistributor.s.sol --tc DeployRewardDistributor --rpc-url $SEPOLIA_RPC_URL --broadcast)
 *
 * Required environment variables:
 *   SEPOLIA_PRIVATE_KEY - Deployer private key
 *
 * Required constructor addresses (update before deployment):
 *   SPLITTER, USDC, PLDXY_BEAR, PLDXY_BULL, STAKED_BEAR, STAKED_BULL, CURVE_POOL, ZAP_ROUTER, ORACLE
 */
contract DeployRewardDistributor is Script {

    // ==========================================
    // DEPLOYMENT ADDRESSES (UPDATE BEFORE DEPLOY)
    // ==========================================

    // These should be set to the actual deployed addresses from DeployToSepolia
    address constant SPLITTER = address(0);
    address constant USDC = address(0);
    address constant PLDXY_BEAR = address(0);
    address constant PLDXY_BULL = address(0);
    address constant STAKED_BEAR = address(0);
    address constant STAKED_BULL = address(0);
    address constant CURVE_POOL = address(0);
    address constant ZAP_ROUTER = address(0);
    address constant ORACLE = address(0);

    function run() external returns (RewardDistributor distributor) {
        uint256 privateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        require(SPLITTER != address(0), "SPLITTER address not set");
        require(USDC != address(0), "USDC address not set");
        require(PLDXY_BEAR != address(0), "PLDXY_BEAR address not set");
        require(PLDXY_BULL != address(0), "PLDXY_BULL address not set");
        require(STAKED_BEAR != address(0), "STAKED_BEAR address not set");
        require(STAKED_BULL != address(0), "STAKED_BULL address not set");
        require(CURVE_POOL != address(0), "CURVE_POOL address not set");
        require(ZAP_ROUTER != address(0), "ZAP_ROUTER address not set");
        require(ORACLE != address(0), "ORACLE address not set");

        vm.startBroadcast(privateKey);

        distributor = new RewardDistributor(
            SPLITTER, USDC, PLDXY_BEAR, PLDXY_BULL, STAKED_BEAR, STAKED_BULL, CURVE_POOL, ZAP_ROUTER, ORACLE
        );

        vm.stopBroadcast();

        console.log("========================================");
        console.log("REWARD DISTRIBUTOR DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("RewardDistributor:", address(distributor));
        console.log("");
        console.log("Next steps:");
        console.log("1. Configure SyntheticSplitter to send yield to RewardDistributor:");
        console.log("   splitter.proposeFeeReceivers(treasury, address(distributor))");
        console.log("2. Wait 7 days for timelock");
        console.log("3. splitter.finalizeFeeReceivers()");
        console.log("========================================");

        return distributor;
    }

}
