// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {
    IAggregator,
    IEntryPoint,
    IPaymaster,
    PackedUserOperation
} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @dev ERC-165 identifier for the upstream v0.9 IEntryPoint's own methods, excluding inherited interfaces.
interface IEntryPointV09Compatibility {

    struct UserOpsPerAggregator {
        PackedUserOperation[] userOps;
        IAggregator aggregator;
        bytes signature;
    }

    function handleOps(
        PackedUserOperation[] calldata ops,
        address payable beneficiary
    ) external;

    function handleAggregatedOps(
        UserOpsPerAggregator[] calldata opsPerAggregator,
        address payable beneficiary
    ) external;

    function getUserOpHash(
        PackedUserOperation calldata userOp
    ) external view returns (bytes32);

    function getCurrentUserOpHash() external view returns (bytes32);

    function getSenderAddress(
        bytes calldata initCode
    ) external;

    function delegateAndRevert(
        address target,
        bytes calldata data
    ) external;

    function senderCreator() external view returns (address);

}

interface IKernelV4FactoryProfile {

    struct Install {
        uint256 moduleType;
        address module;
        bytes moduleData;
        bytes internalData;
    }

    function UUPS() external view returns (address implementation);

    function getAddress(
        Install[] calldata packages,
        uint256 index
    ) external view returns (address account);
    function deploy(
        Install[] calldata packages,
        uint256 index
    ) external payable returns (address account);

}

/// @title PletherKernelVerifyingPaymaster
/// @notice ERC-4337 v0.9 gas sponsorship for the Kernel v4 ECDSA-root UUPS profile on Arbitrum Sepolia.
/// @dev The policy service verifies the live account implementation, root and owner, decodes the inner calls, and
///      reserves the gas budget before signing. The proxy runtime hash alone cannot prove its current implementation.
///      The upgradeable account profile is for bounded testnet use. This contract preserves the Plether v1 sponsorship
///      envelope. The sponsor signature is part of paymasterData and is included in the owner's UserOperation hash.
contract PletherKernelVerifyingPaymaster is IPaymaster, Ownable2Step, Pausable, EIP712 {

    uint256 public constant PAYMASTER_HEADER_LENGTH = 52;
    uint256 public constant VALID_UNTIL_LENGTH = 6;
    uint256 public constant VALID_AFTER_LENGTH = 6;
    uint256 public constant MAX_COST_LENGTH = 16;
    uint256 public constant POLICY_ID_LENGTH = 32;
    uint256 public constant ACCOUNT_CODE_HASH_LENGTH = 32;
    uint256 public constant SIGNATURE_LENGTH = 65;
    uint256 public constant PAYMASTER_DATA_LENGTH = VALID_UNTIL_LENGTH + VALID_AFTER_LENGTH + MAX_COST_LENGTH
        + POLICY_ID_LENGTH + ACCOUNT_CODE_HASH_LENGTH + SIGNATURE_LENGTH;
    uint256 public constant PAYMASTER_AND_DATA_LENGTH = PAYMASTER_HEADER_LENGTH + PAYMASTER_DATA_LENGTH;
    uint48 public constant MAX_VALIDITY_WINDOW = 10 minutes;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant VALIDATOR_MODULE_TYPE = 1;
    uint256 internal constant FACTORY_CALL_LENGTH = 376;
    uint48 internal constant ENTRY_POINT_BLOCK_RANGE_FLAG = 1 << 47;
    bytes4 public constant EXECUTE_SELECTOR = bytes4(keccak256("execute(bytes32,bytes)"));
    bytes32 internal constant SINGLE_ATOMIC_MODE = bytes32(0);
    bytes32 internal constant BATCH_ATOMIC_MODE = bytes32(uint256(1) << 248);
    bytes32 public constant EMPTY_CODE_HASH = keccak256("");

    bytes32 public constant SPONSORSHIP_TYPEHASH = keccak256(
        "Sponsorship(address sender,uint256 nonce,bytes32 initCodeHash,bytes32 callDataHash,bytes32 accountGasLimits,"
        "uint256 preVerificationGas,bytes32 gasFees,uint128 paymasterVerificationGasLimit,"
        "uint128 paymasterPostOpGasLimit,uint48 validUntil,uint48 validAfter,uint128 maxCost,bytes32 policyId,"
        "bytes32 accountCodeHash,address entryPoint)"
    );

    IEntryPoint public immutable entryPoint;
    bytes32 public immutable entryPointCodeHash;
    bytes32 public immutable policyId;
    bytes32 public immutable approvedAccountCodeHash;
    address public immutable accountFactory;
    bytes32 public immutable accountFactoryCodeHash;
    address public immutable accountImplementation;
    bytes32 public immutable accountImplementationCodeHash;
    address public immutable rootValidator;
    bytes32 public immutable rootValidatorCodeHash;

    address public sponsorSigner;
    uint256 public maxSponsoredCost;

    error UnsupportedChain(uint256 chainId);
    error CallerNotEntryPoint(address caller);
    error InvalidEntryPoint(address entryPoint);
    error InvalidSponsorSigner(address signer);
    error InvalidPaymaster(address paymaster);
    error InvalidPaymasterAndDataLength(uint256 actual, uint256 expected);
    error InvalidPolicyId(bytes32 actual, bytes32 expected);
    error InvalidAccountCodeHash(bytes32 accountCodeHash);
    error AccountCodeHashMismatch(bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error InvalidAccountFactory(address factory);
    error InvalidAccountImplementation(address implementation);
    error InvalidRootValidator(address validator);
    error AccountFactoryCodeHashMismatch(bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error AccountImplementationCodeHashMismatch(bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error RootValidatorCodeHashMismatch(bytes32 actualCodeHash, bytes32 expectedCodeHash);
    error AccountFactoryImplementationMismatch(address actualImplementation, address expectedImplementation);
    error InvalidFactoryInInitCode(address actualFactory, address expectedFactory);
    error InvalidFactoryCall();
    error InvalidAccountNonceKey(uint256 nonce);
    error InvalidAccountCallSelector(bytes4 selector);
    error InvalidExecutionMode(bytes32 mode);
    error InvalidPaymasterPostOpGasLimit(uint128 actualGasLimit);
    error InvalidValidityWindow(uint48 validAfter, uint48 validUntil);
    error ValidityWindowTooLong(uint48 actualWindow, uint48 maximumWindow);
    error SignedCostLimitExceeded(uint256 actualMaxCost, uint128 signedMaxCost);
    error PaymasterCostLimitExceeded(uint256 actualMaxCost, uint256 paymasterMaxCost);

    event SponsorSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event MaxSponsoredCostUpdated(uint256 previousMaxSponsoredCost, uint256 newMaxSponsoredCost);

    struct SponsorshipData {
        uint48 validUntil;
        uint48 validAfter;
        uint128 maxCost;
        bytes32 policyId;
        bytes32 accountCodeHash;
        bytes signature;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) {
            revert CallerNotEntryPoint(msg.sender);
        }
        _;
    }

    constructor(
        IEntryPoint entryPoint_,
        address owner_,
        address initialSponsorSigner_,
        uint256 maxSponsoredCost_,
        bytes32 policyId_,
        bytes32 approvedAccountCodeHash_,
        address accountFactory_,
        address accountImplementation_,
        address rootValidator_
    ) Ownable(owner_) EIP712("PletherVerifyingPaymaster", "1") {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }
        if (!_supportsEntryPointV09(entryPoint_)) {
            revert InvalidEntryPoint(address(entryPoint_));
        }
        if (initialSponsorSigner_ == address(0)) {
            revert InvalidSponsorSigner(address(0));
        }
        if (policyId_ == bytes32(0)) {
            revert InvalidPolicyId(bytes32(0), bytes32(0));
        }
        if (approvedAccountCodeHash_ == bytes32(0) || approvedAccountCodeHash_ == EMPTY_CODE_HASH) {
            revert InvalidAccountCodeHash(approvedAccountCodeHash_);
        }
        if (accountFactory_ == address(0) || accountFactory_.code.length == 0) {
            revert InvalidAccountFactory(accountFactory_);
        }
        if (accountImplementation_ == address(0) || accountImplementation_.code.length == 0) {
            revert InvalidAccountImplementation(accountImplementation_);
        }

        if (rootValidator_.code.length == 0) {
            revert InvalidRootValidator(rootValidator_);
        }

        address factoryImplementation = _readFactoryImplementation(accountFactory_);
        if (factoryImplementation != accountImplementation_) {
            revert AccountFactoryImplementationMismatch(factoryImplementation, accountImplementation_);
        }

        entryPoint = entryPoint_;
        entryPointCodeHash = address(entryPoint_).codehash;
        policyId = policyId_;
        approvedAccountCodeHash = approvedAccountCodeHash_;
        accountFactory = accountFactory_;
        accountFactoryCodeHash = accountFactory_.codehash;
        accountImplementation = accountImplementation_;
        accountImplementationCodeHash = accountImplementation_.codehash;
        rootValidator = rootValidator_;
        rootValidatorCodeHash = rootValidator_.codehash;
        sponsorSigner = initialSponsorSigner_;
        maxSponsoredCost = maxSponsoredCost_;

        emit SponsorSignerUpdated(address(0), initialSponsorSigner_);
        emit MaxSponsoredCostUpdated(0, maxSponsoredCost_);
        _pause();
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 actualMaxCost
    ) external view override onlyEntryPoint whenNotPaused returns (bytes memory context, uint256 validationData) {
        SponsorshipData memory sponsorship = _decodeEnvelope(userOp);
        _validateEnvelopePolicy(userOp, sponsorship);
        _validateAccountProfile(userOp);

        if (actualMaxCost > sponsorship.maxCost) {
            revert SignedCostLimitExceeded(actualMaxCost, sponsorship.maxCost);
        }
        if (actualMaxCost > maxSponsoredCost) {
            revert PaymasterCostLimitExceeded(actualMaxCost, maxSponsoredCost);
        }

        bytes32 digest = _getSponsorshipHash(userOp, sponsorship);
        (address recovered, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(digest, sponsorship.signature);
        bool signatureValid = recoverError == ECDSA.RecoverError.NoError && recovered == sponsorSigner;

        return
            (bytes(""), ERC4337Utils.packValidationData(signatureValid, sponsorship.validAfter, sponsorship.validUntil));
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode,
        bytes calldata,
        uint256,
        uint256
    ) external view override onlyEntryPoint {}

    /// @notice Returns the exact EIP-712 digest the policy service must sign.
    /// @dev This remains callable before a counterfactual sender is deployed. EntryPoint creates the sender before
    ///      validatePaymasterUserOp, where the pinned runtime code hash is enforced.
    function getSponsorshipHash(
        PackedUserOperation calldata userOp
    ) external view returns (bytes32) {
        SponsorshipData memory sponsorship = _decodeEnvelope(userOp);
        return _getSponsorshipHash(userOp, sponsorship);
    }

    /// @notice Replaces the sole policy signer after old authorizations have drained.
    /// @dev Rotation is deliberately possible only while validation is paused.
    function setSponsorSigner(
        address newSponsorSigner
    ) external onlyOwner whenPaused {
        if (newSponsorSigner == address(0)) {
            revert InvalidSponsorSigner(address(0));
        }
        address previousSigner = sponsorSigner;
        sponsorSigner = newSponsorSigner;
        emit SponsorSignerUpdated(previousSigner, newSponsorSigner);
    }

    function setMaxSponsoredCost(
        uint256 newMaxSponsoredCost
    ) external onlyOwner {
        uint256 previousMaxSponsoredCost = maxSponsoredCost;
        maxSponsoredCost = newMaxSponsoredCost;
        emit MaxSponsoredCostUpdated(previousMaxSponsoredCost, newMaxSponsoredCost);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    function withdrawTo(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        entryPoint.withdrawTo(recipient, amount);
    }

    function addStake(
        uint32 unstakeDelaySec
    ) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(
        address payable recipient
    ) external onlyOwner {
        entryPoint.withdrawStake(recipient);
    }

    function _decodeEnvelope(
        PackedUserOperation calldata userOp
    ) internal view returns (SponsorshipData memory sponsorship) {
        if (userOp.paymasterAndData.length != PAYMASTER_AND_DATA_LENGTH) {
            revert InvalidPaymasterAndDataLength(userOp.paymasterAndData.length, PAYMASTER_AND_DATA_LENGTH);
        }

        address encodedPaymaster = address(bytes20(userOp.paymasterAndData[0:20]));
        if (encodedPaymaster != address(this)) {
            revert InvalidPaymaster(encodedPaymaster);
        }

        bytes calldata data = userOp.paymasterAndData[PAYMASTER_HEADER_LENGTH:];
        sponsorship.validUntil = uint48(bytes6(data[0:6]));
        sponsorship.validAfter = uint48(bytes6(data[6:12]));
        sponsorship.maxCost = uint128(bytes16(data[12:28]));
        sponsorship.policyId = bytes32(data[28:60]);
        sponsorship.accountCodeHash = bytes32(data[60:92]);
        sponsorship.signature = data[92:157];
    }

    function _validateEnvelopePolicy(
        PackedUserOperation calldata userOp,
        SponsorshipData memory sponsorship
    ) internal view {
        if (
            sponsorship.validUntil <= sponsorship.validAfter
                || sponsorship.validUntil & ENTRY_POINT_BLOCK_RANGE_FLAG != 0
        ) {
            revert InvalidValidityWindow(sponsorship.validAfter, sponsorship.validUntil);
        }
        uint48 validityWindow = sponsorship.validUntil - sponsorship.validAfter;
        if (validityWindow > MAX_VALIDITY_WINDOW) {
            revert ValidityWindowTooLong(validityWindow, MAX_VALIDITY_WINDOW);
        }
        if (sponsorship.policyId != policyId) {
            revert InvalidPolicyId(sponsorship.policyId, policyId);
        }
        if (sponsorship.accountCodeHash != approvedAccountCodeHash) {
            revert AccountCodeHashMismatch(sponsorship.accountCodeHash, approvedAccountCodeHash);
        }
        uint128 postOpGasLimit = uint128(ERC4337Utils.paymasterPostOpGasLimit(userOp));
        if (postOpGasLimit != 0) {
            revert InvalidPaymasterPostOpGasLimit(postOpGasLimit);
        }
    }

    function _validateAccountProfile(
        PackedUserOperation calldata userOp
    ) internal view {
        bytes32 actualAccountCodeHash = userOp.sender.codehash;
        if (actualAccountCodeHash != approvedAccountCodeHash) {
            revert AccountCodeHashMismatch(actualAccountCodeHash, approvedAccountCodeHash);
        }

        bytes32 actualFactoryCodeHash = accountFactory.codehash;
        if (actualFactoryCodeHash != accountFactoryCodeHash) {
            revert AccountFactoryCodeHashMismatch(actualFactoryCodeHash, accountFactoryCodeHash);
        }

        bytes32 actualImplementationCodeHash = accountImplementation.codehash;
        if (actualImplementationCodeHash != accountImplementationCodeHash) {
            revert AccountImplementationCodeHashMismatch(actualImplementationCodeHash, accountImplementationCodeHash);
        }

        address currentFactoryImplementation = _readFactoryImplementation(accountFactory);
        if (currentFactoryImplementation != accountImplementation) {
            revert AccountFactoryImplementationMismatch(currentFactoryImplementation, accountImplementation);
        }

        bytes32 actualRootValidatorCodeHash = rootValidator.codehash;
        if (actualRootValidatorCodeHash != rootValidatorCodeHash) {
            revert RootValidatorCodeHashMismatch(actualRootValidatorCodeHash, rootValidatorCodeHash);
        }
        if (userOp.initCode.length != 0) {
            _validateFactoryCall(userOp.initCode);
        }

        // Kernel v4 uses the top 192 bits to select validation mode, validator, and nonce key.
        if (userOp.nonce >> 64 != 0) {
            revert InvalidAccountNonceKey(userOp.nonce);
        }

        bytes4 selector = userOp.callData.length < 4 ? bytes4(0) : bytes4(userOp.callData[0:4]);
        if (selector != EXECUTE_SELECTOR || userOp.callData.length < 100) {
            revert InvalidAccountCallSelector(selector);
        }
        bytes32 mode = bytes32(userOp.callData[4:36]);
        if (mode != SINGLE_ATOMIC_MODE && mode != BATCH_ATOMIC_MODE) {
            revert InvalidExecutionMode(mode);
        }
    }

    function _validateFactoryCall(
        bytes calldata initCode
    ) internal view {
        address initCodeFactory = initCode.length < 20 ? address(0) : address(bytes20(initCode[0:20]));
        if (initCodeFactory != accountFactory) {
            revert InvalidFactoryInInitCode(initCodeFactory, accountFactory);
        }
        if (
            initCode.length != FACTORY_CALL_LENGTH || bytes4(initCode[20:24]) != IKernelV4FactoryProfile.deploy.selector
        ) {
            revert InvalidFactoryCall();
        }
        bytes calldata factoryData = initCode[24:];
        // A single static address (left-packed into 20 dynamic bytes), no internal data, and index zero.
        (IKernelV4FactoryProfile.Install[] memory packages, uint256 index) =
            abi.decode(factoryData, (IKernelV4FactoryProfile.Install[], uint256));
        if (packages.length != 1 || index != 0) {
            revert InvalidFactoryCall();
        }
        IKernelV4FactoryProfile.Install memory pkg = packages[0];
        if (
            pkg.moduleType != VALIDATOR_MODULE_TYPE || pkg.module != rootValidator || pkg.moduleData.length != 20
                || address(bytes20(pkg.moduleData)) == address(0) || pkg.internalData.length != 0
                || keccak256(factoryData) != keccak256(abi.encode(packages, index))
        ) {
            revert InvalidFactoryCall();
        }
    }

    function _getSponsorshipHash(
        PackedUserOperation calldata userOp,
        SponsorshipData memory sponsorship
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SPONSORSHIP_TYPEHASH,
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                uint128(ERC4337Utils.paymasterVerificationGasLimit(userOp)),
                uint128(ERC4337Utils.paymasterPostOpGasLimit(userOp)),
                sponsorship.validUntil,
                sponsorship.validAfter,
                sponsorship.maxCost,
                sponsorship.policyId,
                sponsorship.accountCodeHash,
                address(entryPoint)
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _readFactoryImplementation(
        address factory
    ) internal view returns (address implementation) {
        (bool success, bytes memory result) = factory.staticcall(abi.encodeCall(IKernelV4FactoryProfile.UUPS, ()));
        if (!success || result.length != 32) {
            revert InvalidAccountFactory(factory);
        }
        implementation = abi.decode(result, (address));
    }

    function _supportsEntryPointV09(
        IEntryPoint candidate
    ) internal view returns (bool) {
        if (address(candidate) == address(0) || address(candidate).code.length == 0) {
            return false;
        }

        try IERC165(address(candidate)).supportsInterface(type(IEntryPointV09Compatibility).interfaceId) returns (
            bool supported
        ) {
            return supported;
        } catch {
            return false;
        }
    }

}
