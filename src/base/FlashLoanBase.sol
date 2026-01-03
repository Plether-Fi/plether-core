// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @title FlashLoanBase
/// @notice Abstract base contract for flash loan borrowers with common validation logic.
/// @dev Provides shared constants, errors, and validation helpers for routers.
abstract contract FlashLoanBase is IERC3156FlashBorrower {
    // ERC-3156 callback success value
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Errors
    error FlashLoan__InvalidLender();
    error FlashLoan__InvalidInitiator();
    error FlashLoan__InvalidOperation();

    /// @notice Validate flash loan callback parameters.
    /// @param lender The actual msg.sender (should be the expected lender).
    /// @param expectedLender The expected flash lender address.
    /// @param initiator The initiator passed to the callback (should be this contract).
    function _validateFlashLoan(address lender, address expectedLender, address initiator) internal view {
        if (lender != expectedLender) revert FlashLoan__InvalidLender();
        if (initiator != address(this)) revert FlashLoan__InvalidInitiator();
    }

    /// @notice Validate only the initiator (for contracts with multiple possible lenders).
    /// @param initiator The initiator passed to the callback (should be this contract).
    function _validateInitiator(address initiator) internal view {
        if (initiator != address(this)) revert FlashLoan__InvalidInitiator();
    }

    /// @notice Validate only the lender.
    /// @param lender The actual msg.sender.
    /// @param expectedLender The expected flash lender address.
    function _validateLender(address lender, address expectedLender) internal pure {
        if (lender != expectedLender) revert FlashLoan__InvalidLender();
    }
}
