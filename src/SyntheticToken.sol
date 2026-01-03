// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";

/// @title SyntheticToken
/// @notice ERC20 token with flash mint capability, controlled by SyntheticSplitter.
/// @dev Used for DXY-BEAR and DXY-BULL tokens. Only the Splitter can mint/burn.
contract SyntheticToken is ERC20, ERC20FlashMint {
    // The address of the Splitter contract that controls supply
    address public immutable SPLITTER;

    error SyntheticToken__Unauthorized();

    modifier onlySplitter() {
        if (msg.sender != SPLITTER) {
            revert SyntheticToken__Unauthorized();
        }
        _;
    }

    constructor(string memory _name, string memory _symbol, address _splitter) ERC20(_name, _symbol) {
        require(_splitter != address(0), "Invalid splitter address");
        SPLITTER = _splitter;
    }

    /// @notice Mint tokens to an address. Only callable by Splitter.
    /// @param to Recipient address.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external onlySplitter {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an address. Only callable by Splitter.
    /// @param from Address to burn from.
    /// @param amount Amount to burn.
    function burn(address from, uint256 amount) external onlySplitter {
        _burn(from, amount);
    }
}
