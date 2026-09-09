// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {PletherVerifyingPaymaster} from "@plether/perps-aa/PletherVerifyingPaymaster.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

contract DeployPletherVerifyingPaymaster is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    address internal constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    bytes32 internal constant ENTRY_POINT_V08_CODE_HASH =
        0xe3f30f78ae55058acdefea00952c8e44f2263215cf720fe1b27b6f148add0278;
    address internal constant SIMPLE_ACCOUNT_FACTORY = 0x13E9ed32155810FDbd067D4522C492D6f68E5944;
    bytes32 internal constant SIMPLE_ACCOUNT_FACTORY_CODE_HASH =
        0xa2e635152a61e180383c7afc045620b7461ef6f43ba27d592262513106b991b7;
    address internal constant SIMPLE_ACCOUNT_IMPLEMENTATION = 0x28426d752372D68d34340bd94390950DcE3C9ec3;
    bytes32 internal constant SIMPLE_ACCOUNT_IMPLEMENTATION_CODE_HASH =
        0x689a90eff03926a12aedad2fc6d4fdbcbdd9ffac86e7d0d70ce6355961305c74;
    bytes32 internal constant SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH =
        0x41ee894da413cc99e8dec0a1784470eceb736845ad1591e06ff0ecdf0aca26c9;
    bytes32 internal constant POLICY_ID = 0x8dd77324b94da492342191f762a32cdf99e828a7f24d77c8ed5ace90cf4f5ae3;

    error InitialStakeRequiresOwnerBroadcast(address deployer, address configuredOwner);
    error InvalidProfileCodeHash(address profile, bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error InvalidProxyRuntimeCodeHash(bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error InvalidUnstakeDelay(uint256 unstakeDelaySec);
    error UnsupportedDeploymentChain(uint256 actualChainId, uint256 expectedChainId);

    function run() external returns (PletherVerifyingPaymaster paymaster) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("PAYMASTER_OWNER");
        address sponsorSigner = vm.envAddress("SPONSOR_SIGNER");
        uint256 maxSponsoredCost = vm.envUint("MAX_SPONSORED_COST_WEI");
        bytes32 approvedAccountCodeHash = vm.envBytes32("SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH");
        uint256 initialDeposit = vm.envOr("INITIAL_PAYMASTER_DEPOSIT_WEI", uint256(0));
        uint256 initialStake = vm.envOr("INITIAL_PAYMASTER_STAKE_WEI", uint256(0));
        uint256 unstakeDelay = vm.envOr("PAYMASTER_UNSTAKE_DELAY_SEC", uint256(86_400));
        if (unstakeDelay > type(uint32).max) {
            revert InvalidUnstakeDelay(unstakeDelay);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 unstakeDelaySec = uint32(unstakeDelay);
        address deployer = vm.addr(deployerPrivateKey);
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert UnsupportedDeploymentChain(block.chainid, ARBITRUM_SEPOLIA_CHAIN_ID);
        }
        _requireCodeHash(ENTRY_POINT_V08, ENTRY_POINT_V08_CODE_HASH);
        _requireCodeHash(SIMPLE_ACCOUNT_FACTORY, SIMPLE_ACCOUNT_FACTORY_CODE_HASH);
        _requireCodeHash(SIMPLE_ACCOUNT_IMPLEMENTATION, SIMPLE_ACCOUNT_IMPLEMENTATION_CODE_HASH);
        if (approvedAccountCodeHash != SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH) {
            revert InvalidProxyRuntimeCodeHash(approvedAccountCodeHash, SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH);
        }
        if (initialStake != 0 && owner != deployer) {
            revert InitialStakeRequiresOwnerBroadcast(deployer, owner);
        }

        vm.startBroadcast(deployerPrivateKey);
        paymaster = new PletherVerifyingPaymaster(
            IEntryPoint(ENTRY_POINT_V08),
            owner,
            sponsorSigner,
            maxSponsoredCost,
            POLICY_ID,
            approvedAccountCodeHash,
            SIMPLE_ACCOUNT_FACTORY,
            SIMPLE_ACCOUNT_IMPLEMENTATION
        );
        if (initialDeposit != 0) {
            paymaster.deposit{value: initialDeposit}();
        }
        if (initialStake != 0) {
            paymaster.addStake{value: initialStake}(unstakeDelaySec);
        }
        vm.stopBroadcast();

        console2.log("PletherVerifyingPaymaster", address(paymaster));
        console2.log("EntryPoint", ENTRY_POINT_V08);
        console2.log("Owner", owner);
        console2.log("Initial sponsor signer", sponsorSigner);
        console2.log("Policy id");
        console2.logBytes32(POLICY_ID);
        console2.log("Approved account code hash");
        console2.logBytes32(approvedAccountCodeHash);
        console2.log("SimpleAccount factory", SIMPLE_ACCOUNT_FACTORY);
        console2.log("SimpleAccount implementation", SIMPLE_ACCOUNT_IMPLEMENTATION);
        console2.log("Maximum sponsored cost", maxSponsoredCost);
        console2.log("Paused", paymaster.paused());
        console2.log("Initial EntryPoint deposit", initialDeposit);
        console2.log("Initial EntryPoint stake", initialStake);
    }

    function _requireCodeHash(
        address profile,
        bytes32 expectedCodeHash
    ) internal view {
        bytes32 actualCodeHash = profile.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidProfileCodeHash(profile, actualCodeHash, expectedCodeHash);
        }
    }

}
