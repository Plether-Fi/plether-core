// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IEntryPoint, IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IEntryPointV08Compatibility, PletherVerifyingPaymaster} from "@plether/perps-aa/PletherVerifyingPaymaster.sol";
import {Test} from "forge-std/Test.sol";

contract MockEntryPoint {

    mapping(address account => uint256 deposit) private _deposits;
    mapping(address account => uint256 stake) public stakes;
    mapping(address account => bool unlocked) public stakeUnlocked;

    receive() external payable {}

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == type(IEntryPointV08Compatibility).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function validatePaymaster(
        IPaymaster paymaster,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        return paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    function callPostOp(
        IPaymaster paymaster
    ) external {
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, bytes(""), 0, 0);
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return _deposits[account];
    }

    function depositTo(
        address account
    ) external payable {
        _deposits[account] += msg.value;
    }

    function withdrawTo(
        address payable recipient,
        uint256 amount
    ) external {
        _deposits[msg.sender] -= amount;
        (bool success,) = recipient.call{value: amount}("");
        require(success, "withdraw failed");
    }

    function addStake(
        uint32
    ) external payable {
        stakes[msg.sender] += msg.value;
        stakeUnlocked[msg.sender] = false;
    }

    function unlockStake() external {
        stakeUnlocked[msg.sender] = true;
    }

    function withdrawStake(
        address payable recipient
    ) external {
        require(stakeUnlocked[msg.sender], "stake locked");
        uint256 amount = stakes[msg.sender];
        stakes[msg.sender] = 0;
        (bool success,) = recipient.call{value: amount}("");
        require(success, "stake withdraw failed");
    }

}

contract MockSmartAccount {}

contract MockSimpleAccountImplementation {}

contract MockSimpleAccountFactory {

    address public accountImplementation;

    constructor(
        address implementation
    ) {
        accountImplementation = implementation;
    }

    function setAccountImplementation(
        address implementation
    ) external {
        accountImplementation = implementation;
    }

}

contract IncompatibleEntryPoint {}

contract PletherVerifyingPaymasterTest is Test {

    uint256 private constant SPONSOR_SIGNER_KEY = 0xA11CE;
    uint256 private constant OTHER_SIGNER_KEY = 0xB0B;
    uint128 private constant PAYMASTER_VERIFICATION_GAS_LIMIT = 100_000;
    uint128 private constant PAYMASTER_POST_OP_GAS_LIMIT = 0;
    uint128 private constant SIGNED_MAX_COST = 0.01 ether;
    uint256 private constant PAYMASTER_MAX_COST = 0.02 ether;
    bytes32 private constant POLICY_ID = keccak256("perps-trader-v1");

    MockEntryPoint private mockEntryPoint;
    PletherVerifyingPaymaster private paymaster;
    MockSmartAccount private smartAccount;
    MockSimpleAccountFactory private accountFactory;
    MockSimpleAccountImplementation private accountImplementation;
    address private sponsorSigner;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_000_000);
        sponsorSigner = vm.addr(SPONSOR_SIGNER_KEY);
        mockEntryPoint = new MockEntryPoint();
        smartAccount = new MockSmartAccount();
        accountImplementation = new MockSimpleAccountImplementation();
        accountFactory = new MockSimpleAccountFactory(address(accountImplementation));
        paymaster = new PletherVerifyingPaymaster(
            IEntryPoint(address(mockEntryPoint)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            address(accountFactory),
            address(accountImplementation)
        );
        assertTrue(paymaster.paused());
        paymaster.unpause();
    }

    function test_ValidSignatureReturnsSignedValidityWindow() public {
        uint48 validAfter = uint48(block.timestamp - 10);
        uint48 validUntil = uint48(block.timestamp + 120);
        PackedUserOperation memory userOp = _signedUserOp(SPONSOR_SIGNER_KEY, validUntil, validAfter, SIGNED_MAX_COST);

        (bytes memory context, uint256 validationData) =
            mockEntryPoint.validatePaymaster(paymaster, userOp, keccak256("entrypoint-user-op-hash"), SIGNED_MAX_COST);

        (address aggregator, uint48 parsedValidAfter, uint48 parsedValidUntil) =
            ERC4337Utils.parseValidationData(validationData);
        assertEq(context.length, 0);
        assertEq(aggregator, address(0));
        assertEq(parsedValidAfter, validAfter);
        assertEq(parsedValidUntil, validUntil);
    }

    function test_SponsorshipTypehashMatchesIndependentFixture() public view {
        assertEq(paymaster.SPONSORSHIP_TYPEHASH(), 0x5835c142c681b663470a1a53c34b0ba256a8283b7b9f9560aadb85711d252918);
        assertEq(uint256(uint32(type(IEntryPointV08Compatibility).interfaceId)), uint256(0x989ccc58));
    }

    function test_SponsorshipHashMatchesIndependentViemFixture() public {
        address fixtureEntryPoint = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
        address fixturePaymaster = 0x1111111111111111111111111111111111111111;
        address fixtureAccount = 0x2222222222222222222222222222222222222222;
        bytes32 fixturePolicyId = 0x998b46b747647acb0e13177c7c5e2531452f3ac9c8b0cce56f2b0fdbfdf37781;

        vm.chainId(421_614);
        vm.etch(fixtureEntryPoint, address(mockEntryPoint).code);
        vm.etch(fixtureAccount, hex"60006000f3");
        PletherVerifyingPaymaster template = new PletherVerifyingPaymaster(
            IEntryPoint(fixtureEntryPoint),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            fixturePolicyId,
            fixtureAccount.codehash,
            address(accountFactory),
            address(accountImplementation)
        );
        vm.etch(fixturePaymaster, address(template).code);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: fixtureAccount,
            nonce: 7,
            initCode: hex"",
            callData: hex"deadbeef",
            accountGasLimits: bytes32((uint256(250_000) << 128) | uint256(500_000)),
            preVerificationGas: 75_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(2 gwei)),
            paymasterAndData: abi.encodePacked(
                fixturePaymaster,
                uint128(100_000),
                uint128(40_000),
                uint48(1_900_000_000),
                uint48(1_800_000_000),
                uint128(1_000_000_000_000_000),
                fixturePolicyId,
                fixtureAccount.codehash,
                new bytes(65)
            ),
            signature: hex""
        });

        bytes32 digest = PletherVerifyingPaymaster(fixturePaymaster).getSponsorshipHash(userOp);
        assertEq(digest, 0xd92042495de3ae32c76391a73aeb6bfaf515af2dd3da45c9a8921b5310cde1ea);
    }

    function test_ClientActionFixturesMatchContractSponsorshipHashes() public {
        string memory fixture =
            vm.readFile(string.concat(vm.projectRoot(), "/../perps-aa-client/test/compatibility/baseline.json"));
        address fixtureEntryPoint = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
        address fixturePaymaster = 0x7777777777777777777777777777777777777777;
        vm.chainId(421_614);
        vm.etch(fixtureEntryPoint, address(mockEntryPoint).code);
        PletherVerifyingPaymaster template = new PletherVerifyingPaymaster(
            IEntryPoint(fixtureEntryPoint),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            vm.parseJsonBytes32(fixture, ".envelope.policyId"),
            vm.parseJsonBytes32(fixture, ".envelope.accountCodeHash"),
            address(accountFactory),
            address(accountImplementation)
        );
        vm.etch(fixturePaymaster, address(template).code);
        for (uint256 i; i < 11; ++i) {
            string memory prefix = string.concat(".actions[", vm.toString(i), "]");
            PackedUserOperation memory userOp = PackedUserOperation({
                sender: 0x2222222222222222222222222222222222222222,
                nonce: 7,
                initCode: hex"",
                callData: vm.parseJsonBytes(fixture, string.concat(prefix, ".accountCallData")),
                accountGasLimits: bytes32((uint256(250_000) << 128) | uint256(500_000)),
                preVerificationGas: 75_000,
                gasFees: bytes32((uint256(1 gwei) << 128) | uint256(2 gwei)),
                paymasterAndData: vm.parseJsonBytes(fixture, ".envelope.paymasterAndData"),
                signature: hex""
            });
            assertEq(
                PletherVerifyingPaymaster(fixturePaymaster).getSponsorshipHash(userOp),
                vm.parseJsonBytes32(fixture, string.concat(prefix, ".sponsorshipHash")),
                prefix
            );
        }
    }

    function test_InvalidSignatureReturnsFailureInsteadOfReverting() public {
        PackedUserOperation memory userOp = _signedUserOp(
            OTHER_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );

        (, uint256 validationData) = mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);

        (address aggregator,,) = ERC4337Utils.parseValidationData(validationData);
        assertEq(aggregator, address(1));
    }

    function test_MutatingCallDataInvalidatesSignature() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );
        userOp.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", address(0xCAFE), 0, hex"1234");

        (, uint256 validationData) = mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);

        (address aggregator,,) = ERC4337Utils.parseValidationData(validationData);
        assertEq(aggregator, address(1));
    }

    function test_AccountSignatureIsExcludedFromSponsorDigest() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        bytes32 beforeAccountSignature = paymaster.getSponsorshipHash(userOp);

        userOp.signature = hex"aabbccdd";

        assertEq(paymaster.getSponsorshipHash(userOp), beforeAccountSignature);
    }

    function test_RevertsWhenRuntimeCostExceedsSignedCost() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.SignedCostLimitExceeded.selector,
                uint256(SIGNED_MAX_COST) + 1,
                SIGNED_MAX_COST
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), uint256(SIGNED_MAX_COST) + 1);
    }

    function test_RevertsWhenRuntimeCostExceedsOnchainCircuitBreaker() public {
        uint128 signedLimit = uint128(PAYMASTER_MAX_COST + 1);
        PackedUserOperation memory userOp =
            _signedUserOp(SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), signedLimit);

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.PaymasterCostLimitExceeded.selector,
                PAYMASTER_MAX_COST + 1,
                PAYMASTER_MAX_COST
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), PAYMASTER_MAX_COST + 1);
    }

    function test_RevertsForMalformedEnvelope() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.paymasterAndData = hex"1234";

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.InvalidPaymasterAndDataLength.selector,
                uint256(2),
                paymaster.PAYMASTER_AND_DATA_LENGTH()
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsForWrongPaymasterAddress() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.paymasterAndData = _overwritePaymaster(userOp.paymasterAndData, address(0xDEAD));

        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidPaymaster.selector, address(0xDEAD)));
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsForUnboundedValidity() public {
        PackedUserOperation memory userOp = _unsignedUserOp(0, 0, SIGNED_MAX_COST);

        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidValidityWindow.selector, uint48(0), uint48(0))
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsForZeroWidthValidityWindow() public {
        uint48 timestamp = uint48(block.timestamp + 120);
        PackedUserOperation memory userOp = _unsignedUserOp(timestamp, timestamp, SIGNED_MAX_COST);

        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidValidityWindow.selector, timestamp, timestamp)
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsWhenValidityWindowExceedsTenMinutes() public {
        uint48 validAfter = uint48(block.timestamp);
        uint48 validUntil = validAfter + paymaster.MAX_VALIDITY_WINDOW() + 1;
        PackedUserOperation memory userOp = _unsignedUserOp(validUntil, validAfter, SIGNED_MAX_COST);

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.ValidityWindowTooLong.selector,
                paymaster.MAX_VALIDITY_WINDOW() + 1,
                paymaster.MAX_VALIDITY_WINDOW()
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsForNonzeroPostOpGas() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            PAYMASTER_VERIFICATION_GAS_LIMIT,
            uint128(1),
            uint48(block.timestamp + 120),
            uint48(block.timestamp - 10),
            SIGNED_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            new bytes(65)
        );

        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidPaymasterPostOpGasLimit.selector, uint128(1))
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_DummyStubSignatureReturnsFailureInsteadOfReverting() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);

        (, uint256 validationData) = mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);

        (address aggregator,,) = ERC4337Utils.parseValidationData(validationData);
        assertEq(aggregator, address(1));
    }

    function test_RevertsForUnapprovedPolicyOrEnvelopeCodeHash() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        bytes32 otherPolicy = keccak256("other-policy");
        userOp.paymasterAndData = _paymasterAndDataForProfile(
            uint48(block.timestamp + 120),
            uint48(block.timestamp - 10),
            SIGNED_MAX_COST,
            otherPolicy,
            address(smartAccount).codehash,
            new bytes(65)
        );

        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidPolicyId.selector, otherPolicy, POLICY_ID)
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);

        bytes32 otherCodeHash = keccak256("other-runtime");
        userOp.paymasterAndData = _paymasterAndDataForProfile(
            uint48(block.timestamp + 120),
            uint48(block.timestamp - 10),
            SIGNED_MAX_COST,
            POLICY_ID,
            otherCodeHash,
            new bytes(65)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountCodeHashMismatch.selector,
                otherCodeHash,
                address(smartAccount).codehash
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsWhenFactoryImplementationDrifts() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );
        MockSimpleAccountImplementation replacement = new MockSimpleAccountImplementation();
        accountFactory.setAccountImplementation(address(replacement));

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountFactoryImplementationMismatch.selector,
                address(replacement),
                address(accountImplementation)
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsWhenFactoryRuntimeDrifts() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );
        bytes32 expectedFactoryCodeHash = address(accountFactory).codehash;
        vm.etch(address(accountFactory), hex"00");
        bytes32 actualFactoryCodeHash = address(accountFactory).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountFactoryCodeHashMismatch.selector,
                actualFactoryCodeHash,
                expectedFactoryCodeHash
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsWhenImplementationRuntimeDrifts() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );
        bytes32 expectedImplementationCodeHash = address(accountImplementation).codehash;
        vm.etch(address(accountImplementation), hex"00");
        bytes32 actualImplementationCodeHash = address(accountImplementation).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountImplementationCodeHashMismatch.selector,
                actualImplementationCodeHash,
                expectedImplementationCodeHash
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsForWrongCounterfactualFactory() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.initCode = abi.encodePacked(address(0xDEAD), hex"1234");
        bytes32 digest = paymaster.getSponsorshipHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SPONSOR_SIGNER_KEY, digest);
        userOp.paymasterAndData = _paymasterAndData(
            uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST, abi.encodePacked(r, s, v)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.InvalidFactoryInInitCode.selector, address(0xDEAD), address(accountFactory)
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_CounterfactualDigestCanBeComputedBeforeSenderDeployment() public view {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.sender = address(0xABCD);
        userOp.initCode = abi.encodePacked(address(accountFactory), hex"1234");

        assertEq(userOp.sender.code.length, 0);
        assertNotEq(paymaster.getSponsorshipHash(userOp), bytes32(0));
    }

    function test_RevertsForNonzeroNonceKeyOrUnknownOuterSelector() public {
        PackedUserOperation memory userOp =
            _unsignedUserOp(uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST);
        userOp.nonce = (uint256(1) << 64) | 7;

        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidAccountNonceKey.selector, userOp.nonce));
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);

        userOp.nonce = 7;
        userOp.callData = hex"deadbeef";
        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidAccountCallSelector.selector, bytes4(0xdeadbeef))
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_RevertsWhenAccountRuntimeChangesAfterSponsorship() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );
        bytes32 signedCodeHash = address(smartAccount).codehash;
        vm.etch(address(smartAccount), hex"00");
        bytes32 actualCodeHash = address(smartAccount).codehash;

        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountCodeHashMismatch.selector, actualCodeHash, signedCodeHash
            )
        );
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), SIGNED_MAX_COST);
    }

    function test_OnlyEntryPointCanValidateOrPostOp() public {
        PackedUserOperation memory userOp = _signedUserOp(
            SPONSOR_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), SIGNED_MAX_COST
        );

        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.CallerNotEntryPoint.selector, address(this)));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), SIGNED_MAX_COST);

        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.CallerNotEntryPoint.selector, address(this)));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, bytes(""), 0, 0);

        mockEntryPoint.callPostOp(paymaster);
    }

    function test_PauseStopsValidationAndOwnerCanRotateSignerAndLimit() public {
        address otherSigner = vm.addr(OTHER_SIGNER_KEY);
        paymaster.setMaxSponsoredCost(123);
        assertEq(paymaster.sponsorSigner(), sponsorSigner);
        assertEq(paymaster.maxSponsoredCost(), 123);

        paymaster.pause();
        paymaster.setSponsorSigner(otherSigner);
        assertEq(paymaster.sponsorSigner(), otherSigner);
        PackedUserOperation memory userOp =
            _signedUserOp(OTHER_SIGNER_KEY, uint48(block.timestamp + 120), uint48(block.timestamp - 10), 123);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), 123);

        paymaster.unpause();
        (, uint256 validationData) = mockEntryPoint.validatePaymaster(paymaster, userOp, bytes32(0), 123);
        (address aggregator,,) = ERC4337Utils.parseValidationData(validationData);
        assertEq(aggregator, address(0));
    }

    function test_SignerRotationRequiresPauseAndRejectsZeroSigner() public {
        address otherSigner = vm.addr(OTHER_SIGNER_KEY);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        paymaster.setSponsorSigner(otherSigner);

        paymaster.pause();
        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidSponsorSigner.selector, address(0)));
        paymaster.setSponsorSigner(address(0));
    }

    function test_DepositWithdrawAndStakeLifecycle() public {
        vm.deal(address(this), 3 ether);

        paymaster.deposit{value: 1 ether}();
        assertEq(paymaster.getDeposit(), 1 ether);

        address payable recipient = payable(address(0xBEEF));
        paymaster.withdrawTo(recipient, 0.4 ether);
        assertEq(recipient.balance, 0.4 ether);
        assertEq(paymaster.getDeposit(), 0.6 ether);

        paymaster.addStake{value: 1 ether}(86_400);
        assertEq(mockEntryPoint.stakes(address(paymaster)), 1 ether);
        paymaster.unlockStake();
        paymaster.withdrawStake(recipient);
        assertEq(recipient.balance, 1.4 ether);
        assertEq(mockEntryPoint.stakes(address(paymaster)), 0);
    }

    function test_ConstructorRejectsNonContractEntryPointAndZeroSigner() public {
        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidEntryPoint.selector, address(0x1234)));
        new PletherVerifyingPaymaster(
            IEntryPoint(address(0x1234)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            address(accountFactory),
            address(accountImplementation)
        );

        IncompatibleEntryPoint incompatibleEntryPoint = new IncompatibleEntryPoint();
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.InvalidEntryPoint.selector, address(incompatibleEntryPoint)
            )
        );
        new PletherVerifyingPaymaster(
            IEntryPoint(address(incompatibleEntryPoint)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            address(accountFactory),
            address(accountImplementation)
        );

        MockEntryPoint anotherEntryPoint = new MockEntryPoint();
        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidSponsorSigner.selector, address(0)));
        new PletherVerifyingPaymaster(
            IEntryPoint(address(anotherEntryPoint)),
            address(this),
            address(0),
            PAYMASTER_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            address(accountFactory),
            address(accountImplementation)
        );
    }

    function test_ConstructorRejectsInvalidPinnedAccountProfile() public {
        MockEntryPoint anotherEntryPoint = new MockEntryPoint();

        vm.expectRevert(
            abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidPolicyId.selector, bytes32(0), bytes32(0))
        );
        new PletherVerifyingPaymaster(
            IEntryPoint(address(anotherEntryPoint)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            bytes32(0),
            address(smartAccount).codehash,
            address(accountFactory),
            address(accountImplementation)
        );

        vm.expectRevert(abi.encodeWithSelector(PletherVerifyingPaymaster.InvalidAccountCodeHash.selector, bytes32(0)));
        new PletherVerifyingPaymaster(
            IEntryPoint(address(anotherEntryPoint)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            POLICY_ID,
            bytes32(0),
            address(accountFactory),
            address(accountImplementation)
        );

        MockSimpleAccountImplementation replacement = new MockSimpleAccountImplementation();
        vm.expectRevert(
            abi.encodeWithSelector(
                PletherVerifyingPaymaster.AccountFactoryImplementationMismatch.selector,
                address(accountImplementation),
                address(replacement)
            )
        );
        new PletherVerifyingPaymaster(
            IEntryPoint(address(anotherEntryPoint)),
            address(this),
            sponsorSigner,
            PAYMASTER_MAX_COST,
            POLICY_ID,
            address(smartAccount).codehash,
            address(accountFactory),
            address(replacement)
        );
    }

    function _signedUserOp(
        uint256 signerKey,
        uint48 validUntil,
        uint48 validAfter,
        uint128 signedMaxCost
    ) private view returns (PackedUserOperation memory userOp) {
        userOp = _unsignedUserOp(validUntil, validAfter, signedMaxCost);
        bytes32 digest = paymaster.getSponsorshipHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        userOp.paymasterAndData = _paymasterAndData(validUntil, validAfter, signedMaxCost, abi.encodePacked(r, s, v));
    }

    function _unsignedUserOp(
        uint48 validUntil,
        uint48 validAfter,
        uint128 signedMaxCost
    ) private view returns (PackedUserOperation memory userOp) {
        userOp = PackedUserOperation({
            sender: address(smartAccount),
            nonce: 7,
            initCode: hex"",
            callData: abi.encodeWithSignature("execute(address,uint256,bytes)", address(0xCAFE), 0, hex"deadbeef"),
            accountGasLimits: bytes32((uint256(250_000) << 128) | uint256(500_000)),
            preVerificationGas: 75_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(2 gwei)),
            paymasterAndData: _paymasterAndData(validUntil, validAfter, signedMaxCost, new bytes(65)),
            signature: hex""
        });
    }

    function _paymasterAndData(
        uint48 validUntil,
        uint48 validAfter,
        uint128 signedMaxCost,
        bytes memory signature
    ) private view returns (bytes memory) {
        return _paymasterAndDataForProfile(
            validUntil, validAfter, signedMaxCost, POLICY_ID, address(smartAccount).codehash, signature
        );
    }

    function _paymasterAndDataForProfile(
        uint48 validUntil,
        uint48 validAfter,
        uint128 signedMaxCost,
        bytes32 envelopePolicyId,
        bytes32 accountCodeHash,
        bytes memory signature
    ) private view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            PAYMASTER_VERIFICATION_GAS_LIMIT,
            PAYMASTER_POST_OP_GAS_LIMIT,
            validUntil,
            validAfter,
            signedMaxCost,
            envelopePolicyId,
            accountCodeHash,
            signature
        );
    }

    function _overwritePaymaster(
        bytes memory envelope,
        address replacement
    ) private pure returns (bytes memory) {
        assembly ("memory-safe") {
            let firstWord := mload(add(envelope, 0x20))
            let gasPrefix := and(firstWord, 0xffffffffffffffffffffffff)
            mstore(add(envelope, 0x20), or(shl(96, replacement), gasPrefix))
        }
        return envelope;
    }

}
