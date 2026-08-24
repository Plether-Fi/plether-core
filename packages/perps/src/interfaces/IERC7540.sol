// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC7575} from "@plether/perps/interfaces/IERC7575.sol";

/// @notice ERC-7540 operator authorization shared by asynchronous deposit and redemption flows.
/// @dev Implementations must report support for canonical interface id `0xe3bc4e65` through ERC-165.
interface IERC7540Operator {

    /// @notice Emitted when `controller` grants or revokes an operator.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Returns whether `operator` may manage requests and claims for `controller`.
    function isOperator(
        address controller,
        address operator
    ) external view returns (bool status);

    /// @notice Grants or revokes `operator` permission over the caller's requests and claims.
    /// @return success Always true after the status is set successfully.
    function setOperator(
        address operator,
        bool approved
    ) external returns (bool success);

}

/// @notice ERC-7540 asynchronous deposit request and claim interface.
/// @dev Implementations must report support for canonical interface id `0xce3bbe50` through ERC-165.
interface IERC7540Deposit is IERC7540Operator {

    /// @notice Emitted after `owner` supplies assets for a request controlled by `controller`.
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Transfers `assets` from `owner` and submits an asynchronous deposit request for `controller`.
    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    /// @notice Returns pending requested assets identified by `requestId` and `controller`.
    function pendingDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    /// @notice Returns claimable requested assets identified by `requestId` and `controller`.
    function claimableDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    /// @notice Claims up to `assets` from `controller`'s claimable deposit balance for `receiver`.
    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    /// @notice Claims enough of `controller`'s deposit balance to assign `shares` to `receiver`.
    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets);

}

/// @notice ERC-7540 asynchronous redemption request and claim interface.
/// @dev Implementations must report support for canonical interface id `0x620ee8e4` through ERC-165.
interface IERC7540Redeem is IERC7540Operator {

    /// @notice Emitted after `owner` supplies shares for a request controlled by `controller`.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Takes custody of `shares` from `owner` and submits an asynchronous redemption for `controller`.
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    /// @notice Returns pending requested shares identified by `requestId` and `controller`.
    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    /// @notice Returns claimable requested shares identified by `requestId` and `controller`.
    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

}

/// @notice Complete ERC-7540 request surface for a vault supporting both asynchronous flows.
/// @dev ERC-7540 advertises the operator, deposit, and redemption fragment ids separately; there is no aggregate
///      ERC-165 id for this convenience interface.
interface IERC7540 is IERC7540Deposit, IERC7540Redeem, IERC7575 {}
