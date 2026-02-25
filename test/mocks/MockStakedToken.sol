// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockToken} from "./MockToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockStakedToken is ERC20 {

    MockToken public underlying;

    constructor(
        address _underlying
    ) ERC20("Staked Token", "sTKN") {
        underlying = MockToken(_underlying);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assets = shares;
        underlying.transfer(receiver, assets);
    }

    function previewRedeem(
        uint256 shares
    ) external pure returns (uint256) {
        return shares;
    }

    function previewDeposit(
        uint256 assets
    ) external pure returns (uint256) {
        return assets;
    }

}
