// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFlashToken is ERC20, IERC3156FlashLender {

    uint256 public feeBps;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function setFeeBps(
        uint256 _feeBps
    ) external {
        feeBps = _feeBps;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    function maxFlashLoan(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(
        address,
        uint256 amount
    ) public view override returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        uint256 fee = flashFee(token, amount);
        _mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        _burn(address(receiver), amount + fee);
        return true;
    }

}
