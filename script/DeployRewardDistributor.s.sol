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

    address constant SPLITTER = 0x81D7f6eE951f5272043de05E6EE25c58a440c2DF;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PLDXY_BEAR = 0xEDE56A22771c7fDA8b80Cc1A1fa2B54420cD4A5d;
    address constant PLDXY_BULL = 0xF20D4E93ee2F3948E4aE998F7C3A5Ec9E0aBD4c4;
    address constant STAKED_BEAR = 0x4f7310E8bDa646A7DA4b8F1bBE83073380C5Dc53;
    address constant STAKED_BULL = 0x3B859C74d628dAe76C95fA3b2A9d1A50aB153E2D;
    address constant CURVE_POOL = 0x2354579380cAd0518C6518e5Ee2A66d30d0149bE;
    address constant ZAP_ROUTER = 0x96bEEF7872c9bFD746359aD51bE35f1A8e3C99dE;
    address constant BASKET_ORACLE = 0xfFc35FD33C2acF241F6e46625C7571D64f8AddbD;
    address constant PYTH_ADAPTER = 0xEf0e44465a18f848165Bf1A007BE51f628a6FC06;

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
            0x125B1F77Ef927eFf08EDd362c00BF059FFD9d3E6 // InvarCoin
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
