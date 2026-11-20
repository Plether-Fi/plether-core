// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {
    IKernelV4FactoryProfile,
    PletherKernelVerifyingPaymaster
} from "@plether/perps-aa/PletherKernelVerifyingPaymaster.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IKernelECDSARoot {

    function ecdsaValidatorStorage(
        address account
    ) external view returns (address owner);

}

/// @notice Deploys a paused paymaster using the reviewed Kernel profile evidence for Arbitrum Sepolia.
/// @dev The sample Kernel must be deployed through its real factory and verified by the qualification run first.
contract DeployPletherKernelVerifyingPaymaster is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 internal constant KERNEL_VALIDATION_STORAGE_SLOT =
        0xded5d420c407eac3c615e6abe13ab4a0bd7173e5045ea543765b46f0df6e260c;

    struct Profile {
        address factory;
        address implementation;
        address rootValidator;
        bytes32 proxyCodeHash;
    }

    error UnsupportedDeploymentChain(uint256 actual);
    error InvalidProfileCodeHash(address account, bytes32 actual, bytes32 expected);
    error InvalidSampleAccount(address account);

    function run() external returns (PletherKernelVerifyingPaymaster paymaster) {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert UnsupportedDeploymentChain(block.chainid);
        }
        Profile memory profile = _readProfile();
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("PAYMASTER_OWNER");
        address sponsorSigner = vm.envAddress("SPONSOR_SIGNER");
        uint256 maxSponsoredCost = vm.envUint("MAX_SPONSORED_COST_WEI");
        bytes32 policyId = vm.envBytes32("KERNEL_PAYMASTER_POLICY_ID");

        vm.startBroadcast(deployerPrivateKey);
        paymaster = new PletherKernelVerifyingPaymaster(
            IEntryPoint(ENTRY_POINT_V09),
            owner,
            sponsorSigner,
            maxSponsoredCost,
            policyId,
            profile.proxyCodeHash,
            profile.factory,
            profile.implementation,
            profile.rootValidator
        );
        vm.stopBroadcast();

        console2.log("PletherKernelVerifyingPaymaster", address(paymaster));
        console2.log("EntryPoint", ENTRY_POINT_V09);
        console2.log("Kernel factory", profile.factory);
        console2.log("Kernel implementation", profile.implementation);
        console2.log("Kernel root validator", profile.rootValidator);
        console2.log("Paymaster owner", owner);
        console2.log("Initial sponsor signer", sponsorSigner);
        console2.log("Paused", paymaster.paused());
    }

    function _readProfile() internal view returns (Profile memory profile) {
        profile.factory = vm.envAddress("KERNEL_FACTORY");
        profile.implementation = vm.envAddress("KERNEL_IMPLEMENTATION");
        profile.rootValidator = vm.envAddress("KERNEL_ROOT_VALIDATOR");
        profile.proxyCodeHash = vm.envBytes32("KERNEL_PROXY_RUNTIME_CODE_HASH");

        _requireCodeHash(ENTRY_POINT_V09, vm.envBytes32("KERNEL_ENTRY_POINT_CODE_HASH"));
        _requireCodeHash(profile.factory, vm.envBytes32("KERNEL_FACTORY_CODE_HASH"));
        _requireCodeHash(profile.implementation, vm.envBytes32("KERNEL_IMPLEMENTATION_CODE_HASH"));
        _requireCodeHash(profile.rootValidator, vm.envBytes32("KERNEL_ROOT_VALIDATOR_CODE_HASH"));

        address sampleOwner = vm.envAddress("KERNEL_SAMPLE_OWNER");
        require(sampleOwner != address(0), "invalid sample owner");
        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, profile.rootValidator, abi.encodePacked(sampleOwner), "");
        address sampleAccount = IKernelV4FactoryProfile(profile.factory).getAddress(packages, 0);
        _requireCodeHash(sampleAccount, profile.proxyCodeHash);
        // Kernel v4 stores its ECDSA validator ID as 0x01 || validator in the low 21 bytes.
        bytes32 expectedRoot = bytes32((uint256(1) << 160) | uint160(profile.rootValidator));
        if (
            vm.load(sampleAccount, IMPLEMENTATION_SLOT) != bytes32(uint256(uint160(profile.implementation)))
                || vm.load(sampleAccount, BEACON_SLOT) != bytes32(0)
                || vm.load(sampleAccount, KERNEL_VALIDATION_STORAGE_SLOT) != expectedRoot
                || IKernelECDSARoot(profile.rootValidator).ecdsaValidatorStorage(sampleAccount) != sampleOwner
        ) {
            revert InvalidSampleAccount(sampleAccount);
        }
    }

    function _requireCodeHash(
        address account,
        bytes32 expected
    ) internal view {
        bytes32 actual = account.codehash;
        if (account.code.length == 0 || actual != expected) {
            revert InvalidProfileCodeHash(account, actual, expected);
        }
    }

}
