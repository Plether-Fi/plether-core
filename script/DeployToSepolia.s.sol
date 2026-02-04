// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {DeployToTest} from "./DeployToTest.s.sol";
import "forge-std/console.sol";

/**
 * @title ZeroRateIrm
 * @notice Simple zero-rate IRM for Sepolia (AdaptiveCurveIrm not deployed there)
 * @dev Returns 0% APY regardless of utilization - suitable for testnet only
 */
contract ZeroRateIrm {

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function borrowRateView(
        MarketParams memory,
        Market memory
    ) external pure returns (uint256) {
        return 0;
    }

    function borrowRate(
        MarketParams memory,
        Market memory
    ) external pure returns (uint256) {
        return 0;
    }

}

/// @notice Minimal interface for Morpho owner functions
interface IMorphoOwner {

    function enableIrm(
        address irm
    ) external;
    function enableLltv(
        uint256 lltv
    ) external;

}

/**
 * @title DeployToSepolia
 * @notice Deployment script for Plether protocol on Sepolia testnet
 * @dev Deploys own Morpho instance + IRM since the public Morpho on Sepolia has no enabled IRMs/LLTVs
 */
contract DeployToSepolia is DeployToTest {

    address public deployedMorpho;
    ZeroRateIrm public deployedIrm;

    function _getMorphoAddress() internal override returns (address) {
        if (deployedMorpho == address(0)) {
            // Get deployer address from private key
            uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
            address deployer = vm.addr(privateKey);

            // Load Morpho bytecode from file (extracted from mainnet deployment)
            bytes memory morphoInitCode = vm.readFileBinary("script/bytecode/Morpho.bin");
            // Append constructor argument (owner = deployer)
            bytes memory morphoCreationCode = abi.encodePacked(morphoInitCode, abi.encode(deployer));

            address morpho;
            assembly {
                morpho := create(0, add(morphoCreationCode, 0x20), mload(morphoCreationCode))
            }
            require(morpho != address(0), "Morpho deployment failed");
            deployedMorpho = morpho;
            console.log("Morpho deployed:", morpho);

            // Deploy and enable IRM
            deployedIrm = new ZeroRateIrm();
            console.log("ZeroRateIrm deployed:", address(deployedIrm));
            IMorphoOwner(morpho).enableIrm(address(deployedIrm));
            console.log("ZeroRateIrm enabled in Morpho");

            // Enable LLTV (91.5%)
            IMorphoOwner(morpho).enableLltv(LLTV);
            console.log("LLTV 91.5% enabled in Morpho");
        }
        return deployedMorpho;
    }

    function _getIrmAddress() internal override returns (address) {
        // Ensure Morpho is deployed first (which also deploys IRM)
        _getMorphoAddress();
        return address(deployedIrm);
    }

    function _getNonceOffset() internal pure override returns (uint64) {
        // Base offset (37) + Morpho(1) + ZeroRateIrm(1) + enableIrm(1) + enableLltv(1) = 41
        return 41;
    }

}
