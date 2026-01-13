// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SyntheticToken
/// @notice ERC20 token with flash mint and permit capability, controlled by SyntheticSplitter.
/// @dev Used for DXY-BEAR and DXY-BULL tokens. Only the Splitter can mint/burn.
///      Inherits ERC20FlashMint for fee-free flash loans used by routers.
contract SyntheticToken is ERC20, ERC20Permit, ERC20FlashMint {

    /// @notice The SyntheticSplitter contract that controls minting and burning.
    address public immutable SPLITTER;

    /// @notice Thrown when a non-Splitter address attempts to mint or burn.
    error SyntheticToken__Unauthorized();

    /// @notice Thrown when zero address provided for splitter.
    error SyntheticToken__ZeroAddress();

    /// @dev Restricts function access to the Splitter contract only.
    modifier onlySplitter() {
        if (msg.sender != SPLITTER) {
            revert SyntheticToken__Unauthorized();
        }
        _;
    }

    /// @notice Creates a new SyntheticToken.
    /// @param _name Token name (e.g., "Bear DXY").
    /// @param _symbol Token symbol (e.g., "plDXY-BEAR").
    /// @param _splitter Address of the SyntheticSplitter contract.
    constructor(
        string memory _name,
        string memory _symbol,
        address _splitter
    ) ERC20(_name, _symbol) ERC20Permit(_name) {
        if (_splitter == address(0)) revert SyntheticToken__ZeroAddress();
        SPLITTER = _splitter;
    }

    /// @notice Mint tokens to an address. Only callable by Splitter.
    /// @param to Recipient address.
    /// @param amount Amount to mint.
    function mint(
        address to,
        uint256 amount
    ) external onlySplitter {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an address. Only callable by Splitter.
    /// @param from Address to burn from.
    /// @param amount Amount to burn.
    function burn(
        address from,
        uint256 amount
    ) external onlySplitter {
        _burn(from, amount);
    }

}
