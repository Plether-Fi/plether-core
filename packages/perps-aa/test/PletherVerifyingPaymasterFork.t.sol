// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {DeployPletherVerifyingPaymaster} from "../script/DeployPletherVerifyingPaymaster.s.sol";
import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IEntryPointV08Compatibility, PletherVerifyingPaymaster} from "@plether/perps-aa/PletherVerifyingPaymaster.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface ISimpleAccountFactoryV08 {

    function createAccount(
        address owner,
        uint256 salt
    ) external returns (address account);

    function getAddress(
        address owner,
        uint256 salt
    ) external view returns (address account);

}

interface ISimpleAccountV08 {

    function owner() external view returns (address);

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external;

}

contract ForkCallTarget {

    uint256 public calls;

    function touch() external {
        calls += 1;
    }

}

/// @notice Opt-in integration test against the deployed Arbitrum Sepolia EntryPoint and SimpleAccount profile.
/// @dev Run with `ARBITRUM_SEPOLIA_RPC_URL=... forge test --root packages/perps-aa --match-contract
///      PletherVerifyingPaymasterForkTest -vv`. The test never broadcasts.
contract PletherVerifyingPaymasterForkTest is Test {

    uint256 private constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    address private constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    bytes32 private constant ENTRY_POINT_V08_CODE_HASH =
        0xe3f30f78ae55058acdefea00952c8e44f2263215cf720fe1b27b6f148add0278;
    address private constant SIMPLE_ACCOUNT_FACTORY = 0x13E9ed32155810FDbd067D4522C492D6f68E5944;
    bytes32 private constant SIMPLE_ACCOUNT_FACTORY_CODE_HASH =
        0xa2e635152a61e180383c7afc045620b7461ef6f43ba27d592262513106b991b7;
    address private constant SIMPLE_ACCOUNT_IMPLEMENTATION = 0x28426d752372D68d34340bd94390950DcE3C9ec3;
    bytes32 private constant SIMPLE_ACCOUNT_IMPLEMENTATION_CODE_HASH =
        0x689a90eff03926a12aedad2fc6d4fdbcbdd9ffac86e7d0d70ce6355961305c74;
    bytes32 private constant SIMPLE_ACCOUNT_PROXY_CODE_HASH =
        0x41ee894da413cc99e8dec0a1784470eceb736845ad1591e06ff0ecdf0aca26c9;
    bytes32 private constant POLICY_ID = 0x8dd77324b94da492342191f762a32cdf99e828a7f24d77c8ed5ace90cf4f5ae3;
    bytes32 private constant USER_OPERATION_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    uint256 private constant OWNER_KEY = 0xA11CE4337;
    uint256 private constant SPONSOR_SIGNER_KEY = 0xB0B7677;
    uint128 private constant ACCOUNT_VERIFICATION_GAS_LIMIT = 450_000;
    uint128 private constant CALL_GAS_LIMIT = 100_000;
    uint128 private constant PAYMASTER_VERIFICATION_GAS_LIMIT = 100_000;
    uint128 private constant MAX_FEE_PER_GAS = 10 gwei;
    uint128 private constant MAX_PRIORITY_FEE_PER_GAS = 1 gwei;
    uint128 private constant MAX_SPONSORED_COST = 0.02 ether;

    function testFork_DeploymentScriptStartsPausedWithoutFunding() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "set ARBITRUM_SEPOLIA_RPC_URL to run the opt-in deployment simulation");
            return;
        }
        vm.createSelectFork(rpcUrl);
        address deployer = vm.addr(OWNER_KEY);
        vm.deal(deployer, 1 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("PAYMASTER_OWNER", vm.toString(address(this)));
        vm.setEnv("SPONSOR_SIGNER", vm.toString(vm.addr(SPONSOR_SIGNER_KEY)));
        vm.setEnv("MAX_SPONSORED_COST_WEI", vm.toString(uint256(MAX_SPONSORED_COST)));
        vm.setEnv("SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH", vm.toString(SIMPLE_ACCOUNT_PROXY_CODE_HASH));
        vm.setEnv("INITIAL_PAYMASTER_DEPOSIT_WEI", "0");
        vm.setEnv("INITIAL_PAYMASTER_STAKE_WEI", "0");
        vm.setEnv("PAYMASTER_UNSTAKE_DELAY_SEC", "86400");
        PletherVerifyingPaymaster deployed = (new DeployPletherVerifyingPaymaster()).run();
        assertTrue(deployed.paused());
        assertEq(deployed.owner(), address(this));
        assertEq(deployed.sponsorSigner(), vm.addr(SPONSOR_SIGNER_KEY));
        assertEq(deployed.policyId(), POLICY_ID);
        assertEq(IEntryPoint(ENTRY_POINT_V08).balanceOf(address(deployed)), 0);
    }

    function testFork_CounterfactualHandleOpsChargesDepositAndEmitsCanonicalEvent() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "set ARBITRUM_SEPOLIA_RPC_URL to run the opt-in fork test");
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, ARBITRUM_SEPOLIA_CHAIN_ID);
        assertEq(ENTRY_POINT_V08.codehash, ENTRY_POINT_V08_CODE_HASH);
        assertEq(SIMPLE_ACCOUNT_FACTORY.codehash, SIMPLE_ACCOUNT_FACTORY_CODE_HASH);
        assertEq(SIMPLE_ACCOUNT_IMPLEMENTATION.codehash, SIMPLE_ACCOUNT_IMPLEMENTATION_CODE_HASH);

        IEntryPoint entryPoint = IEntryPoint(ENTRY_POINT_V08);
        ISimpleAccountFactoryV08 factory = ISimpleAccountFactoryV08(SIMPLE_ACCOUNT_FACTORY);
        address sponsorSigner = vm.addr(SPONSOR_SIGNER_KEY);
        PletherVerifyingPaymaster paymaster = new PletherVerifyingPaymaster(
            entryPoint,
            address(this),
            sponsorSigner,
            MAX_SPONSORED_COST,
            POLICY_ID,
            SIMPLE_ACCOUNT_PROXY_CODE_HASH,
            SIMPLE_ACCOUNT_FACTORY,
            SIMPLE_ACCOUNT_IMPLEMENTATION
        );
        paymaster.unpause();

        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 1 ether}();

        address accountOwner = vm.addr(OWNER_KEY);
        uint256 accountSalt = uint256(
            keccak256(abi.encode("PletherVerifyingPaymasterForkTest", block.chainid, block.number, address(paymaster)))
        );
        address sender = factory.getAddress(accountOwner, accountSalt);
        assertEq(sender.code.length, 0, "counterfactual sender already deployed");

        ForkCallTarget callTarget = new ForkCallTarget();
        uint48 validAfter = uint48(block.timestamp + 30);
        uint48 validUntil = validAfter + 120;
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: abi.encodePacked(
                SIMPLE_ACCOUNT_FACTORY,
                abi.encodeCall(ISimpleAccountFactoryV08.createAccount, (accountOwner, accountSalt))
            ),
            callData: abi.encodeCall(
                ISimpleAccountV08.execute, (address(callTarget), 0, abi.encodeCall(ForkCallTarget.touch, ()))
            ),
            accountGasLimits: bytes32((uint256(ACCOUNT_VERIFICATION_GAS_LIMIT) << 128) | uint256(CALL_GAS_LIMIT)),
            preVerificationGas: 80_000,
            gasFees: bytes32((uint256(MAX_PRIORITY_FEE_PER_GAS) << 128) | uint256(MAX_FEE_PER_GAS)),
            paymasterAndData: _paymasterAndData(paymaster, validUntil, validAfter, new bytes(65)),
            signature: hex""
        });

        bytes32 sponsorshipDigest = paymaster.getSponsorshipHash(userOp);
        (uint8 sponsorV, bytes32 sponsorR, bytes32 sponsorS) = vm.sign(SPONSOR_SIGNER_KEY, sponsorshipDigest);
        userOp.paymasterAndData =
            _paymasterAndData(paymaster, validUntil, validAfter, abi.encodePacked(sponsorR, sponsorS, sponsorV));

        bytes32 userOpHash = IEntryPointV08Compatibility(ENTRY_POINT_V08).getUserOpHash(userOp);
        (uint8 ownerV, bytes32 ownerR, bytes32 ownerS) = vm.sign(OWNER_KEY, userOpHash);
        userOp.signature = abi.encodePacked(ownerR, ownerS, ownerV);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        address payable beneficiary = payable(address(0xBEEF));

        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA32 paymaster expired or not due")
        );
        entryPoint.handleOps(ops, beneficiary);
        assertEq(sender.code.length, 0, "failed validation deployed the account");

        vm.warp(uint256(validAfter) + 1);
        uint256 depositBefore = paymaster.getDeposit();
        uint256 beneficiaryBefore = beneficiary.balance;
        vm.recordLogs();
        entryPoint.handleOps(ops, beneficiary);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(sender.code.length, 0, "counterfactual account was not deployed");
        assertEq(sender.codehash, SIMPLE_ACCOUNT_PROXY_CODE_HASH);
        assertEq(ISimpleAccountV08(sender).owner(), accountOwner);
        assertEq(callTarget.calls(), 1);

        (uint256 actualGasCost, uint256 actualGasUsed) =
            _assertUserOperationEvent(logs, userOpHash, sender, address(paymaster), userOp.nonce);
        uint256 depositAfter = paymaster.getDeposit();
        assertGt(actualGasCost, 0);
        assertGt(actualGasUsed, 0);
        assertEq(depositBefore - depositAfter, actualGasCost);
        assertEq(beneficiary.balance - beneficiaryBefore, actualGasCost);
    }

    function _paymasterAndData(
        PletherVerifyingPaymaster paymaster,
        uint48 validUntil,
        uint48 validAfter,
        bytes memory sponsorSignature
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            PAYMASTER_VERIFICATION_GAS_LIMIT,
            uint128(0),
            validUntil,
            validAfter,
            MAX_SPONSORED_COST,
            POLICY_ID,
            SIMPLE_ACCOUNT_PROXY_CODE_HASH,
            sponsorSignature
        );
    }

    function _assertUserOperationEvent(
        Vm.Log[] memory logs,
        bytes32 expectedHash,
        address expectedSender,
        address expectedPaymaster,
        uint256 expectedNonce
    ) private pure returns (uint256 actualGasCost, uint256 actualGasUsed) {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == ENTRY_POINT_V08 && entry.topics.length == 4 && entry.topics[0] == USER_OPERATION_EVENT
                    && entry.topics[1] == expectedHash && entry.topics[2] == bytes32(uint256(uint160(expectedSender)))
                    && entry.topics[3] == bytes32(uint256(uint160(expectedPaymaster)))
            ) {
                (uint256 nonce, bool success, uint256 gasCost, uint256 gasUsed) =
                    abi.decode(entry.data, (uint256, bool, uint256, uint256));
                assert(nonce == expectedNonce);
                assert(success);
                return (gasCost, gasUsed);
            }
        }
        revert("canonical UserOperationEvent not found");
    }

}
