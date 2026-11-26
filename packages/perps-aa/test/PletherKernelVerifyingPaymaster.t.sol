// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {IEntryPoint, IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    IKernelV4FactoryProfile,
    PletherKernelVerifyingPaymaster
} from "@plether/perps-aa/PletherKernelVerifyingPaymaster.sol";
import {Test} from "forge-std/Test.sol";

contract MockKernelV09EntryPoint {

    mapping(address account => uint256 balance) public deposits;
    uint256 public stakeAmount;
    uint32 public unstakeDelay;
    bool public stakeUnlocked;
    address public lastWithdrawRecipient;
    uint256 public lastWithdrawAmount;

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        // XOR of the seven methods defined directly on the upstream v0.9 interface.
        return interfaceId == 0x283f5489;
    }

    function depositTo(
        address account
    ) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return deposits[account];
    }

    function withdrawTo(
        address payable recipient,
        uint256 amount
    ) external {
        deposits[msg.sender] -= amount;
        lastWithdrawRecipient = recipient;
        lastWithdrawAmount = amount;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function addStake(
        uint32 unstakeDelaySec
    ) external payable {
        stakeAmount += msg.value;
        unstakeDelay = unstakeDelaySec;
        stakeUnlocked = false;
    }

    function unlockStake() external {
        stakeUnlocked = true;
    }

    function withdrawStake(
        address payable recipient
    ) external {
        uint256 amount = stakeAmount;
        stakeAmount = 0;
        lastWithdrawRecipient = recipient;
        lastWithdrawAmount = amount;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "stake withdraw failed");
    }

}

contract MockKernelV4Factory {

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable UUPS;
    address public immutable EXPECTED_OWNER;
    address public immutable EXPECTED_ACCOUNT;

    constructor(
        address implementation,
        address expectedOwner,
        address expectedAccount
    ) {
        UUPS = implementation;
        EXPECTED_OWNER = expectedOwner;
        EXPECTED_ACCOUNT = expectedAccount;
    }

    function getAddress(
        IKernelV4FactoryProfile.Install[] calldata packages,
        uint256 index
    ) external view returns (address) {
        if (
            index == 0 && packages.length == 1 && packages[0].moduleData.length == 20
                && address(bytes20(packages[0].moduleData)) == EXPECTED_OWNER
        ) {
            return EXPECTED_ACCOUNT;
        }
        return address(uint160(uint256(keccak256(abi.encode(packages, index)))));
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
        factory = address(new MockKernelV4Factory(implementation, signer, account));
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

        op.initCode = abi.encodePacked(_initCode(rootValidator, 0), bytes32(0));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);

        op.initCode = _initCode(implementation, 0);
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);
    }

    function testRejectsNoncanonicalFactoryPaddingAndUnexpectedInitializer() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        op.initCode = _initCode(rootValidator, 0);
        // The last byte in the twenty-byte owner address's word must be zero padding.
        op.initCode[op.initCode.length - 33] = bytes1(uint8(1));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);

        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, rootValidator, abi.encodePacked(address(0)), "");
        op.initCode = abi.encodePacked(factory, abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, 0)));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);
    }

    function testRejectsFormerStakerWrapper() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        address oldStaker = makeAddr("former Staker");
        op.initCode = abi.encodePacked(
            oldStaker,
            abi.encodeWithSignature("deployWithFactory(address,bytes)", factory, _factoryCall(rootValidator, 0))
        );
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidFactoryInInitCode.selector, oldStaker, factory
            )
        );
        _validate(op);
    }

    function testRejectsNonzeroPostOpGasLimit() public {
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        op.paymasterAndData[51] = bytes1(uint8(1));
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidPaymasterPostOpGasLimit.selector, uint128(1))
        );
        _validate(op);
    }

    function testRejectsUnexpectedFactoryAndFactoryRuntimeDrift() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        bytes memory direct = _initCode(rootValidator, 0);
        assertEq(direct.length, 376);
        op.initCode = bytes.concat(bytes20(implementation), _factoryCall(rootValidator, 0));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidFactoryInInitCode.selector, implementation, factory
            )
        );
        _validate(op);

        op.initCode = direct;
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        bytes32 expectedCodeHash = paymaster.accountFactoryCodeHash();
        vm.etch(factory, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.AccountFactoryCodeHashMismatch.selector,
                factory.codehash,
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
        factory = address(new MockKernelV4Factory(otherImplementation, signer, account));
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.AccountFactoryImplementationMismatch.selector,
                otherImplementation,
                implementation
            )
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

    function testRejectsCounterfactualFactoryAddressMismatch() public {
        PackedUserOperation memory op = _operation(bytes32(0));
        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, rootValidator, abi.encodePacked(makeAddr("other owner")), "");
        op.initCode = abi.encodePacked(factory, abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, 0)));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(PletherKernelVerifyingPaymaster.InvalidFactoryCall.selector);
        _validate(op);
    }

    function testDisablesRenounceOwnershipAndGuardsZeroRecipientsAndPostOp() public {
        vm.expectRevert(PletherKernelVerifyingPaymaster.OwnershipRenunciationDisabled.selector);
        paymaster.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidRecipient.selector, address(0)));
        paymaster.withdrawTo(payable(address(0)), 1);

        vm.expectRevert(abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidRecipient.selector, address(0)));
        paymaster.withdrawStake(payable(address(0)));

        vm.prank(entryPoint);
        vm.expectRevert(PletherKernelVerifyingPaymaster.PostOpNotSupported.selector);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }

    function testEnforcesAccessControlPauseOwnable2StepAndEntryPointWrappers() public {
        address outsider = makeAddr("outsider");
        address nextOwner = makeAddr("next owner");
        address recipient = makeAddr("recipient");
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PletherKernelVerifyingPaymaster.CallerNotEntryPoint.selector, outsider));
        paymaster.validatePaymasterUserOp(op, bytes32(0), MAX_COST);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PletherKernelVerifyingPaymaster.CallerNotEntryPoint.selector, outsider));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        paymaster.pause();

        paymaster.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _validate(op);

        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidSponsorSigner.selector, address(0))
        );
        paymaster.setSponsorSigner(address(0));
        address rotatedSigner = makeAddr("rotated signer");
        paymaster.setSponsorSigner(rotatedSigner);
        assertEq(paymaster.sponsorSigner(), rotatedSigner);

        paymaster.unpause();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        paymaster.setSponsorSigner(signer);

        vm.deal(address(this), 2 ether);
        paymaster.deposit{value: 0.5 ether}();
        assertEq(paymaster.getDeposit(), 0.5 ether);
        paymaster.withdrawTo(payable(recipient), 0.2 ether);
        assertEq(recipient.balance, 0.2 ether);
        assertEq(paymaster.getDeposit(), 0.3 ether);

        paymaster.addStake{value: 1 ether}(86_400);
        paymaster.unlockStake();
        paymaster.withdrawStake(payable(recipient));
        assertEq(recipient.balance, 1.2 ether);

        paymaster.transferOwnership(nextOwner);
        assertEq(paymaster.pendingOwner(), nextOwner);
        vm.prank(nextOwner);
        paymaster.acceptOwnership();
        assertEq(paymaster.owner(), nextOwner);
    }

    function testRejectsEnvelopePolicyCostAndProfileViolations() public {
        PackedUserOperation memory op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_AFTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidValidityWindow.selector, VALID_AFTER, VALID_AFTER
            )
        );
        _validate(op);

        uint48 tooLongUntil = VALID_AFTER + 601;
        op = _signed(_operation(bytes32(0)), VALID_AFTER, tooLongUntil);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.ValidityWindowTooLong.selector, uint48(601), uint48(600)
            )
        );
        _validate(op);

        // Paymaster cost cap lower than signed maxCost
        paymaster.setMaxSponsoredCost(MAX_COST - 1);
        op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.PaymasterCostLimitExceeded.selector, MAX_COST, MAX_COST - 1
            )
        );
        _validate(op);
        paymaster.setMaxSponsoredCost(MAX_COST);

        // Wrong paymaster address in paymasterAndData header
        op = _signed(_operation(bytes32(0)), VALID_AFTER, VALID_UNTIL);
        bytes memory wrongHeader = op.paymasterAndData;
        bytes20 otherPaymaster = bytes20(makeAddr("other paymaster"));
        for (uint256 i = 0; i < 20; ++i) {
            wrongHeader[i] = otherPaymaster[i];
        }
        op.paymasterAndData = wrongHeader;
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidPaymaster.selector, makeAddr("other paymaster")
            )
        );
        _validate(op);

        // DELEGATECALL mode (0xff << 248) rejected
        bytes32 delegateCallMode = bytes32(uint256(0xff) << 248);
        op = _signed(_operation(delegateCallMode), VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(PletherKernelVerifyingPaymaster.InvalidExecutionMode.selector, delegateCallMode)
        );
        _validate(op);

        // Wrong call selector rejected
        op = _operation(bytes32(0));
        op.callData = abi.encodeWithSelector(bytes4(0xdeadbeef), bytes32(0), new bytes(64));
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.InvalidAccountCallSelector.selector, bytes4(0xdeadbeef)
            )
        );
        _validate(op);

        // High-s malleable ECDSA signature returns SIG_VALIDATION_FAILED
        op = _operation(bytes32(0));
        bytes memory policyData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            VALID_UNTIL,
            VALID_AFTER,
            MAX_COST,
            POLICY,
            account.codehash
        );
        op.paymasterAndData = abi.encodePacked(policyData, new bytes(65));
        (uint8 origV, bytes32 origR, bytes32 origS) = vm.sign(SIGNER_KEY, paymaster.getSponsorshipHash(op));
        uint256 secp256k1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(secp256k1N - uint256(origS));
        uint8 flippedV = origV == 27 ? 28 : 27;
        op.paymasterAndData = abi.encodePacked(policyData, origR, highS, flippedV);
        (, uint256 validity) = _validate(op);
        (address signatureStatus,,) = ERC4337Utils.parseValidationData(validity);
        assertEq(signatureStatus, address(1));

        // EIP-7702 delegated EOA sender codehash rejected
        address delegatedSender = makeAddr("delegated eoa");
        vm.etch(delegatedSender, abi.encodePacked(bytes3(0xef0100), makeAddr("delegate")));
        op = _operation(bytes32(0));
        op.sender = delegatedSender;
        op = _signed(op, VALID_AFTER, VALID_UNTIL);
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherKernelVerifyingPaymaster.AccountCodeHashMismatch.selector,
                delegatedSender.codehash,
                account.codehash
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
        return abi.encodePacked(factory, _factoryCall(validator, index));
    }

    function _factoryCall(
        address validator,
        uint256 index
    ) internal view returns (bytes memory) {
        IKernelV4FactoryProfile.Install[] memory packages = new IKernelV4FactoryProfile.Install[](1);
        packages[0] = IKernelV4FactoryProfile.Install(1, validator, abi.encodePacked(signer), "");
        return abi.encodeCall(IKernelV4FactoryProfile.deploy, (packages, index));
    }

    struct KernelCall {
        address target;
        uint256 value;
        bytes data;
    }

}
