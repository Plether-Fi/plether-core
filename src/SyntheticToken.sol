// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";

contract SyntheticToken is ERC20, ERC20FlashMint {
    // The address of the Splitter contract that controls supply
    address public immutable splitter;

    error SyntheticToken__Unauthorized();

    modifier onlySplitter() {
        if (msg.sender != splitter) {
            revert SyntheticToken__Unauthorized();
        }
        _;
    }

    constructor(string memory _name, string memory _symbol, address _splitter) ERC20(_name, _symbol) {
        require(_splitter != address(0), "Invalid splitter address");
        splitter = _splitter;
    }

    function mint(address to, uint256 amount) external onlySplitter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlySplitter {
        _burn(from, amount);
    }
}
