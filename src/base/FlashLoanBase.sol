// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IMorphoFlashLoanCallback} from "../interfaces/IMorpho.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @title FlashLoanBase
/// @notice Abstract base for flash loan borrowers with validation logic.
/// @dev Supports both Morpho flash loans and ERC-3156 flash mints.
abstract contract FlashLoanBase is IERC3156FlashBorrower, IMorphoFlashLoanCallback {

    /// @dev ERC-3156 callback success return value.
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Thrown when flash loan callback called by wrong lender.
    error FlashLoan__InvalidLender();

    /// @notice Thrown when flash loan initiator is not this contract.
    error FlashLoan__InvalidInitiator();

    /// @notice Thrown when callback receives unknown operation type.
    error FlashLoan__InvalidOperation();

    /// @dev Validates ERC-3156 flash loan callback parameters.
    /// @param lender Actual msg.sender.
    /// @param expectedLender Expected flash lender address.
    /// @param initiator Initiator passed to callback (must be this contract).
    function _validateFlashLoan(
        address lender,
        address expectedLender,
        address initiator
    ) internal view {
        if (lender != expectedLender) {
            revert FlashLoan__InvalidLender();
        }
        if (initiator != address(this)) {
            revert FlashLoan__InvalidInitiator();
        }
    }

    /// @dev Validates that msg.sender is the expected lender.
    /// @param lender Actual msg.sender.
    /// @param expectedLender Expected flash lender address.
    function _validateLender(
        address lender,
        address expectedLender
    ) internal pure {
        if (lender != expectedLender) {
            revert FlashLoan__InvalidLender();
        }
    }

}
