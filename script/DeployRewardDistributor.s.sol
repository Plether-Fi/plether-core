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

    address constant SPLITTER = 0x45c1135fab0A0532cC2945f6b0b31eA12B54A2f9;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PLDXY_BEAR = 0x5503FB45370a03909dFfEB207483a2832A9171aD;
    address constant PLDXY_BULL = 0xf5aeecdF9778a5801C0873088d25E4d7E3Bf07Ab;
    address constant STAKED_BEAR = 0xDC7366b8BB83f9ABa2B4F989194D6c03D0A20DE9;
    address constant STAKED_BULL = 0x8dbcF452799f50D3382105a19FdBfA57B7f29C73;
    address constant CURVE_POOL = 0x95D51D6F312DbE66BACC2ed677aD64790f48aa87;
    address constant ZAP_ROUTER = 0xb0623D89ae73D177cf201bCA09C51d84502A8d80;
    address constant BASKET_ORACLE = 0x4f798422388484F2139717A8cE0115De3B06b1DF;
    address constant PYTH_ADAPTER = 0x5f4859A2aCcf3b6Ca9eeD9799676Cc7a77B7bEb5;

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
            address(0) // InvarCoin — update when deployed
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
