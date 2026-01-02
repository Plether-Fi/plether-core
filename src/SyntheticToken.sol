// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";

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

    function mint(address to, uint256 amount) external onlySplitter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlySplitter {
        _burn(from, amount);
    }
}
