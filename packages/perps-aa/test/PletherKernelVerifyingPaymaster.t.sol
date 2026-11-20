// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {
    IKernelStakerProfile,
    IKernelV4FactoryProfile,
    PletherKernelVerifyingPaymaster
} from "@plether/perps-aa/PletherKernelVerifyingPaymaster.sol";
import {Test} from "forge-std/Test.sol";

contract MockKernelV09EntryPoint {

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        // XOR of the seven methods defined directly on the upstream v0.9 interface.
        return interfaceId == 0x283f5489;
    }

}

contract MockKernelV4Factory {

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable UUPS;

    constructor(
        address implementation
    ) {
        UUPS = implementation;
    }

}

contract MockKernelStaker {

    mapping(address factory => bool) public approved;

    constructor(
        address factory
    ) {
        approved[factory] = true;
    }

    function setApproved(
        address factory,
        bool value
    ) external {
        approved[factory] = value;
    }

    function deployWithFactory(
        address factory,
        bytes calldata createData
    ) external payable returns (address) {
        (bool success, bytes memory result) = factory.call{value: msg.value}(createData);
        require(success);
        return abi.decode(result, (address));
    }

}

contract PletherKernelVerifyingPaymasterTest is Test {

    uint256 internal constant SIGNER_KEY = 0xa19;
    uint128 internal constant MAX_COST = 0.001 ether;
    uint48 internal constant VALID_AFTER = 1_800_000_000;
    uint48 internal constant VALID_UNTIL = VALID_AFTER + 120;
    bytes32 internal constant POLICY = keccak256("kernel-sepolia-test-policy");
    bytes8 internal constant ENTRY_POINT_V09_PAYMASTER_SIG_MAGIC = 0x22e325a297439656;
    bytes4 internal constant EXECUTE = 0xe9ae5c53;
    bytes32 internal constant BATCH_MODE = bytes32(uint256(1) << 248);

    address internal entryPoint;
    address internal signer;
    address internal rootValidator;
    address internal factory;
    address internal staker;
    address internal implementation;
    address internal account;
    PletherKernelVerifyingPaymaster internal paymaster;

    function setUp() public {
        vm.chainId(421_614);
        entryPoint = address(new MockKernelV09EntryPoint());
        signer = vm.addr(SIGNER_KEY);
        rootValidator = makeAddr("root validator");
        implementation = makeAddr("Kernel UUPS");
        account = makeAddr("Kernel proxy account");
        vm.etch(rootValidator, hex"60006000f3");
        vm.etch(implementation, hex"60016000f3");
        vm.etch(account, hex"60026000f3");
        factory = address(new MockKernelV4Factory(implementation));
        staker = address(new MockKernelStaker(factory));
        paymaster = _deploy();
        assertTrue(paymaster.paused());
        paymaster.unpause();
    }

    function testAcceptsApprovedSingleAndBatchExecution() public {
        (bytes memory context, uint256 validity) = _validate(_signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL));
        assertEq(context.length, 0);
        (address signatureStatus, uint48 validAfter, uint48 validUntil) = ERC4337Utils.parseValidationData(validity);
        assertEq(signatureStatus, address(0));
        assertEq(validAfter, VALID_AFTER);
        assertEq(validUntil, VALID_UNTIL);

        (, validity) = _validate(_signed(_operation(BATCH_MODE), VALID_AFTER, VALID_UNTIL));
        (signatureStatus,,) = ERC4337Utils.parseValidationData(validity);
        assertEq(signatureStatus, address(0));
    }

    function testAcceptsApprovedCounterfactualFactoryShape() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        op.initCode = _initCode(rootValidator, 0);
        (, uint256 validity) = _validate(_signed(op, VALID_AFTER, VALID_UNTIL));
        (address signatureStatus,,) = ERC4337Utils.parseValidationData(validity);
        assertEq(signatureStatus, address(0));
    }

    function testRejectsUnexpectedFactoryInitializationParameters() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        op.initCode = _initCode(rootValidator, 1);
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);

        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, rootValidator, abi.encodePacked(signer), "");
        op.initCode = abi.encodePacked(
            staker,
            abi.encodeCall(
                IKernelStakerProfile.deployWithFactory,
                (implementation, abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, 0)))
            )
        );
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);

        op.initCode = abi.encodePacked(_initCode(rootValidator, 0), bytes32(0));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);

        op.initCode = _initCode(implementation, 0);
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);
    }

    function testRejectsDirectFactoryAndStakerRuntimeDrift() public {
        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, rootValidator, abi.encodePacked(signer), "");
        PackedUserOperation memory op = _operation(bytes32(0));
        op.initCode = abi.encodePacked(factory, abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, 0)));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidFactoryInInitCode.selector, factory, staker)
        );
        _validate(op);

        op.initCode = _initCode(rootValidator, 0);
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        bytes32 expectedCodeHash = paymaster.accountStakerCodeHash();
        vm.etch(staker, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.AccountStakerCodeHashMismatch.selector,
                staker.codehash,
                expectedCodeHash
            )
        );
        _validate(op);
    }

    function testRejectsOtherValidationLanesAndNonAtomicExecutionMode() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        op.nonce = uint256(1) << 64;
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidAccountNonceKey.selector, op.nonce)
        );
        _validate(op);

        bytes32 nonAtomicMode = bytes32(uint256(1) << 240);
        op = _signed(_operation(nonAtomicMode), VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidExecutionMode.selector, nonAtomicMode)
        );
        _validate(op);
    }

    function testChangingBoundFeeInvalidatesAuthorization() public {
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        op.gasFees = bytes32(uint256(op.gasFees) + 1);
        (, uint256 validity) = _validate(op);
        (address signatureStatus,,) = ERC4337Utils.parseValidationData(validity);
        assertEq(signatureStatus, address(1));
    }

    function testRejectsNonCanonicalPaymasterEnvelope() public {
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        op.paymasterAndData = abi.encodePacked(op.paymasterAndData, uint16(65), ENTRY_POINT_V09_PAYMASTER_SIG_MAGIC);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidPaymasterAndDataLength.selector, 219, 209)
        );
        _validate(op);
    }

    function testRequiresTimestampWindowOnEntryPoint09() public {
        uint48 blockRangeFlag = uint48(1) << 47;
        uint48 untilBlock = blockRangeFlag | 500;
        uint48 afterBlock = blockRangeFlag | 490;
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), afterBlock, untilBlock);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidValidityWindow.selector, afterBlock, untilBlock
            )
        );
        _validate(op);
    }

    function testConstructorRejectsMainnetAndWrongFactoryImplementation() public {
        vm.chainId(42_161);
        vm.expectRevert(abi.encodeWithSelector(PletherKernelVerifyingPaymaster.UnsupportedChain.selector, 42_161));
        _deploy();

        vm.chainId(421_614);
        address otherImplementation = rootValidator;
        factory = address(new MockKernelV4Factory(otherImplementation));
        MockKernelStaker(staker).setApproved(factory, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.AccountFactoryImplementationMismatch.selector,
                otherImplementation,
                implementation
            )
        );
        _deploy();

        factory = address(new MockKernelV4Factory(implementation));
        MockKernelStaker(staker).setApproved(factory, false);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.StakerFactoryNotApproved.selector, staker, factory)
        );
        _deploy();
    }

    function testRequiresPinnedValidatorCodeAndLimitsSponsorshipExposure() public {
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.SignedCostLimitExceeded.selector, MAX_COST + 1, MAX_COST
            )
        );
        paymaster.validatePaymasterUserOp(op, bytes32(0), MAX_COST + 1);

        bytes32 expectedCodeHash = paymaster.rootValidatorCodeHash();
        vm.etch(rootValidator, hex"60036000f3");
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.RootValidatorCodeHashMismatch.selector,
                rootValidator.codehash,
                expectedCodeHash
            )
        );
        _validate(op);
    }

    function _deploy() internal returns (PletherKernelVerifyingPaymaster) {
        return new PletherKernelVerifyingPaymaster(
            IEntryPoint(entryPoint),
            address(this),
            signer,
            MAX_COST,
            POLICY,
            account.codehash,
            staker,
            factory,
            implementation,
            rootValidator
        );
    }

    function _operation(
        bytes32 mode
    ) internal view returns (PackedUserOperation memory op) {
        address target = address(0xbeef);
        bytes memory call = hex"12345678abcdef";
        bytes memory executionData = abi.encodePacked(target, uint256(0), call);
        if (mode == BATCH_MODE) {
            KernelCall[] memory calls = new KernelCall[](1);
            calls[0] = KernelCall(target, 0, call);
            executionData = abi.encode(calls);
        }
        op.sender = account;
        op.callData = abi.encodeWithSelector(EXECUTE, mode, executionData);
        op.accountGasLimits = bytes32((uint256(250_000) << 128) | 80_000);
        op.preVerificationGas = 40_000;
        op.gasFees = bytes32((uint256(50_000_000) << 128) | 100_000_000);
    }

    function _signed(
        PackedUserOperation memory op,
        uint48 validAfter,
        uint48 validUntil
    ) internal view returns (PackedUserOperation memory) {
        bytes memory policyData = abi.encodePacked(
            address(paymaster), uint128(100_000), uint128(0), validUntil, validAfter, MAX_COST, POLICY, account.codehash
        );
        op.paymasterAndData = abi.encodePacked(policyData, new bytes(65));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, paymaster.getSponsorshipHash(op));
        op.paymasterAndData = abi.encodePacked(policyData, r, s, v);
        return op;
    }

    function _validate(
        PackedUserOperation memory op
    ) internal returns (bytes memory, uint256) {
        vm.prank(entryPoint);
        return paymaster.validatePaymasterUserOp(op, bytes32(0), MAX_COST);
    }

    function _initCode(
        address validator,
        uint256 index
    ) internal view returns (bytes memory) {
        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, validator, abi.encodePacked(signer), "");
        return abi.encodePacked(
            staker,
            abi.encodeCall(
                IKernelStakerProfile.deployWithFactory,
                (factory, abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, index)))
            )
        );
    }

    struct KernelCall {
        address target;
        uint256 value;
        bytes data;
    }

}
