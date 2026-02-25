// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RewardDistributor} from "../src/RewardDistributor.sol";
import "forge-std/Script.sol";

/**
 * @title DeployRewardDistributor
 * @notice Deploys RewardDistributor with mainnet addresses.
 * @dev Run (dry):
 *        source .env && forge script script/DeployRewardDistributor.s.sol --tc DeployRewardDistributor \
 *          --rpc-url $MAINNET_RPC_URL
 *
 *      Run (broadcast):
 *        source .env && forge script script/DeployRewardDistributor.s.sol --tc DeployRewardDistributor \
 *          --rpc-url $MAINNET_RPC_URL --broadcast
 */
contract DeployRewardDistributor is Script {

    address constant SPLITTER = 0x3A8dAF1f0ccf9675eDE5fE312Ec2E13311e0BBc4;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PLDXY_BEAR = 0xea1c5882863a2D7686dCd4a9ac4E493674f18265;
    address constant PLDXY_BULL = 0xA7760821fdFA93779C6C296403d25Be21F957Cb8;
    address constant STAKED_BEAR = 0x603a694eaB6E684d56531e32d0B2EE12578b026F;
    address constant STAKED_BULL = 0x2e00857D69A0e6E5ae8463099e17DC3E83E2061C;
    address constant CURVE_POOL = 0x1270e2E6e39132D614a09ef167bc949D5E223151;
    address constant ZAP_ROUTER = 0x66e3980e0fB77f45d58572c9BaFEF15777097602;
    address constant BASKET_ORACLE = 0x797BE08864F04b5240D9FbA742bb3f5D888246Ee;
    address constant PYTH_ADAPTER = 0xB440cEA2964234303a1b610682c6850393F87caa;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(privateKey);

        RewardDistributor distributor = new RewardDistributor(
            SPLITTER,
            USDC,
            PLDXY_BEAR,
            PLDXY_BULL,
            STAKED_BEAR,
            STAKED_BULL,
            CURVE_POOL,
            ZAP_ROUTER,
            BASKET_ORACLE,
            PYTH_ADAPTER,
            0x91D242d9ef6C50109F1A59884dABbac1606961A0 // InvarCoin
        );

        console.log("RewardDistributor:", address(distributor));

        vm.stopBroadcast();

        require(address(distributor.SPLITTER()) == SPLITTER, "SPLITTER mismatch");
        require(address(distributor.ZAP_ROUTER()) == ZAP_ROUTER, "ZAP_ROUTER mismatch");
        require(distributor.CAP() == 2e8, "CAP mismatch");

        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("  RewardDistributor:", address(distributor));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Verify on Etherscan");
        console.log("  2. Call splitter.proposeFees(treasury, rewardDistributor) to start 7-day timelock");
        console.log("  3. After timelock: call splitter.acceptFees()");
        console.log("========================================");
    }

}
