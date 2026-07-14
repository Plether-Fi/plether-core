// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakedToken} from "@plether/spot/staking/StakedToken.sol";
import "forge-std/Script.sol";

/// @title DeploySpotStakingArbitrumSepolia
/// @notice Continuation script for deploying spot staking wrappers after a partial spot deployment.
contract DeploySpotStakingArbitrumSepolia is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    struct DeployedContracts {
        StakedToken stakedBear;
        StakedToken stakedBull;
    }

    function run() external returns (DeployedContracts memory deployed) {
        require(block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "wrong chain");

        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address bear = vm.envAddress("SPOT_BEAR");
        address bull = vm.envAddress("SPOT_BULL");

        require(bear.code.length > 0, "BEAR has no code");
        require(bull.code.length > 0, "BULL has no code");

        console.log("Deploying Plether spot staking wrappers to Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("plDXY-BEAR:", bear);
        console.log("plDXY-BULL:", bull);
        console.log("");

        vm.startBroadcast(privateKey);

        deployed.stakedBear = new StakedToken(IERC20(bear), "Staked plDXY-BEAR", "splDXY-BEAR");
        deployed.stakedBull = new StakedToken(IERC20(bull), "Staked plDXY-BULL", "splDXY-BULL");

        vm.stopBroadcast();

        console.log("========================================");
        console.log("SPOT STAKING DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("StakedToken BEAR:", address(deployed.stakedBear));
        console.log("StakedToken BULL:", address(deployed.stakedBull));
        console.log("========================================");

        return deployed;
    }

}
