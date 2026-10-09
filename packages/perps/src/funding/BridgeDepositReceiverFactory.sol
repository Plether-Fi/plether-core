// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BridgeDepositReceiver, IBridgeDepositClearinghouse} from "@plether/perps/funding/BridgeDepositReceiver.sol";

/// @title BridgeDepositReceiverFactory
/// @notice Deploys deterministic per-beneficiary, per-intent USDC margin receivers.
/// @dev Anyone may deploy the same receiver on the beneficiary's behalf. Its address binds the beneficiary and intent
///      salt together with this factory, its fixed integrations, and the full receiver creation code. Caller identity
///      never grants authority or changes the destination. Verify the factory and integrations on the destination chain
///      before sending funds to a predicted address; a prediction alone is not evidence of a bridge route or deployment.
/// @custom:security-contact contact@plether.com
contract BridgeDepositReceiverFactory {

    error BridgeDepositReceiverFactory__ZeroBeneficiary();
    error BridgeDepositReceiverFactory__InvalidClearinghouse();
    error BridgeDepositReceiverFactory__InvalidToken();
    error BridgeDepositReceiverFactory__SettlementAssetMismatch(address configuredAsset, address suppliedAsset);

    address public immutable clearinghouse;
    address public immutable usdc;

    /// @notice Emitted only on the first deployment for a beneficiary/intent pair.
    event ReceiverCreated(address indexed beneficiary, bytes32 indexed intentSalt, address indexed receiver);

    constructor(
        address clearinghouse_,
        address usdc_
    ) {
        if (clearinghouse_.code.length == 0) {
            revert BridgeDepositReceiverFactory__InvalidClearinghouse();
        }
        if (usdc_.code.length == 0) {
            revert BridgeDepositReceiverFactory__InvalidToken();
        }
        address configuredAsset = IBridgeDepositClearinghouse(clearinghouse_).settlementAsset();
        if (configuredAsset != usdc_) {
            revert BridgeDepositReceiverFactory__SettlementAssetMismatch(configuredAsset, usdc_);
        }
        clearinghouse = clearinghouse_;
        usdc = usdc_;
    }

    /// @notice Creates the fixed receiver, or returns the existing receiver if somebody already deployed it.
    /// @dev Neither the first caller nor a later caller can replace the beneficiary or recover its funds.
    function createReceiver(
        address beneficiary,
        bytes32 intentSalt
    ) external returns (address receiver) {
        receiver = predictReceiver(beneficiary, intentSalt);
        if (receiver.code.length == 0) {
            receiver = address(
                new BridgeDepositReceiver{salt: _deploymentSalt(beneficiary, intentSalt)}(
                    beneficiary, clearinghouse, usdc
                )
            );
            emit ReceiverCreated(beneficiary, intentSalt, receiver);
        }
    }

    /// @notice Returns the destination before deployment so USDC can be transferred there counterfactually.
    /// @dev The zero beneficiary is invalid. A zero intent salt is valid, but reuses the same receiver for that account.
    function predictReceiver(
        address beneficiary,
        bytes32 intentSalt
    ) public view returns (address receiver) {
        if (beneficiary == address(0)) {
            revert BridgeDepositReceiverFactory__ZeroBeneficiary();
        }
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(BridgeDepositReceiver).creationCode, abi.encode(beneficiary, clearinghouse, usdc))
        );
        receiver = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), _deploymentSalt(beneficiary, intentSalt), initCodeHash
                        )
                    )
                )
            )
        );
    }

    function _deploymentSalt(
        address beneficiary,
        bytes32 intentSalt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary, intentSalt));
    }

}
